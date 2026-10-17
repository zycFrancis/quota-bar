import Foundation

/// Devin（Windsurf 自助版）账号额度客户端。
/// 数据源是 Connect RPC 端点 GetUserStatus：认证只放 body 的 metadata.apiKey，
/// 该端点不读 Authorization 头，缺 metadata 时服务端直接回 400 而非 401。
actor DevinUsageClient {
    struct UsageResult: Sendable {
        let limits: [LimitWindow]
        let balances: [AccountBalance]
        let plan: String
        let fetchedAt: Date

        init(
            limits: [LimitWindow],
            balances: [AccountBalance] = [],
            plan: String = "",
            fetchedAt: Date
        ) {
            self.limits = limits
            self.balances = balances
            self.plan = plan
            self.fetchedAt = fetchedAt
        }
    }

    enum UsageError: LocalizedError, Equatable {
        case credentialsMissing
        case credentialRejected
        case http(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .credentialsMissing:
                "未找到 Devin 登录凭据，请先运行 devin auth login。"
            case .credentialRejected:
                "Devin 登录凭据已失效，请重新运行 devin auth login。"
            case .http(let status):
                "Devin 额度服务返回 HTTP \(status)。"
            case .invalidResponse:
                "Devin 额度服务返回无法解析的数据。"
            }
        }
    }

    private let statusURL = URL(
        string: "https://server.self-serve.windsurf.com/exa.seat_management_pb.SeatManagementService/GetUserStatus"
    )!
    private var lastResult: UsageResult?
    private var lastResponse: Data?

    func fetchIfNeeded(force: Bool, language: AppLanguage) async throws -> UsageResult {
        if
            !force,
            let lastResult,
            Date().timeIntervalSince(lastResult.fetchedAt) < 300
        {
            // 命中缓存也按当前语言重放解析，语言切换后标签不至于滞留旧语言最长 5 分钟。
            if let lastResponse {
                return try Self.parseResponse(
                    lastResponse,
                    fetchedAt: lastResult.fetchedAt,
                    language: language
                )
            }
            return lastResult
        }

        guard let apiKey = Self.loadAPIKey() else {
            throw UsageError.credentialsMissing
        }

        var request = URLRequest(url: statusURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        // 认证只走 body 的 metadata.apiKey，刻意不加 Authorization 头（见类注释）。
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "metadata": [
                "apiKey": apiKey,
                "ideName": "devin",
                "ideVersion": AppVersion.short,
                "extensionName": "devin",
                "extensionVersion": AppVersion.short,
                "locale": "en"
            ]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw UsageError.credentialRejected }
        guard (200..<300).contains(status) else { throw UsageError.http(status) }

        let result = try Self.parseResponse(data, fetchedAt: Date(), language: language)
        lastResult = result
        lastResponse = data
        return result
    }

    /// 纯解析、不碰网络，便于单测。
    static func parseResponse(
        _ data: Data,
        fetchedAt: Date,
        language: AppLanguage
    ) throws -> UsageResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageError.invalidResponse
        }
        // Connect RPC 出错时 HTTP 仍可能是 200，凭据问题藏在 body 的 code 字段里。
        if
            let code = object["code"] as? String,
            code.lowercased().contains("unauthenticated")
        {
            throw UsageError.credentialRejected
        }
        guard
            let userStatus = object["userStatus"] as? [String: Any],
            let planStatus = userStatus["planStatus"] as? [String: Any]
        else {
            throw UsageError.invalidResponse
        }

        // 字段未公开且随套餐漂移，一律走 as?/number() 防御式解析；
        // 日窗与周窗都在时，日窗在前、周窗在后。
        var limits: [LimitWindow] = []
        if let daily = window(
            from: planStatus,
            percentKey: "dailyQuotaRemainingPercent",
            resetKey: "dailyQuotaResetAtUnix",
            id: "devin-daily",
            label: language.text("日额度", "Daily"),
            minutes: 1_440
        ) {
            limits.append(daily)
        }
        if let weekly = window(
            from: planStatus,
            percentKey: "weeklyQuotaRemainingPercent",
            resetKey: "weeklyQuotaResetAtUnix",
            id: "devin-weekly",
            label: language.text("周额度", "Weekly"),
            minutes: 10_080
        ) {
            limits.append(weekly)
        }
        guard !limits.isEmpty else {
            throw UsageError.invalidResponse
        }

        let plan = (planStatus["planInfo"] as? [String: Any])?["planName"] as? String ?? ""

        var balances: [AccountBalance] = []
        if
            let micros = LocalCollectors.number(planStatus["overageBalanceMicros"]),
            micros != 0
        {
            // 微美元记账且可为负（超支欠费）；口径照 Kimi booster 钱包，全额记入充值余额。
            let total = Decimal(micros) / 1_000_000
            balances.append(AccountBalance(currency: "USD", total: total, granted: 0, toppedUp: total))
        }

        return UsageResult(limits: limits, balances: balances, plan: plan, fetchedAt: fetchedAt)
    }

    // MARK: - 凭据

    /// devin auth login 落盘的是平面 key = "value" 结构，
    /// 逐行扫描足够可靠，不值得为它引入 TOML 依赖。
    private static func loadAPIKey() -> String? {
        let credentialURL = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".local/share/devin/credentials.toml")
        guard
            let content = try? String(contentsOf: credentialURL, encoding: .utf8),
            let key = extractAPIKey(from: content)
        else {
            return nil
        }
        return key
    }

    /// 取 windsurf_api_key = "<token>" 等号右侧、去引号去空白；
    /// 找不到或值为空返回 nil。token 只进请求 body，绝不打印、不记录、不落盘。
    private static func extractAPIKey(from content: String) -> String? {
        for rawLine in content.components(separatedBy: .newlines) {
            guard let separator = rawLine.firstIndex(of: "=") else { continue }
            let key = rawLine[..<separator].trimmingCharacters(in: .whitespaces)
            guard key == "windsurf_api_key" else { continue }
            var value = rawLine[rawLine.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if
                value.count >= 2,
                let first = value.first,
                let last = value.last,
                (first == "\"" && last == "\"") || (first == "'" && last == "'")
            {
                value.removeFirst()
                value.removeLast()
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: - 字段映射

    private static func window(
        from status: [String: Any],
        percentKey: String,
        resetKey: String,
        id: String,
        label: String,
        minutes: Int
    ) -> LimitWindow? {
        // 服务端给的就是「剩余」百分比，直接使用，勿取反。
        guard let remaining = LocalCollectors.number(status[percentKey]) else { return nil }
        return LimitWindow(
            id: id,
            label: label,
            remainingPercent: min(max(remaining, 0), 100),
            resetAt: resetDate(status[resetKey]),
            windowMinutes: minutes
        )
    }

    /// 线上是 Unix 秒（字符串形态）；若量级达到毫秒则按毫秒折算，
    /// 避免类型漂移时重置时间飞到千年之后。
    private static func resetDate(_ value: Any?) -> Date? {
        guard let epoch = LocalCollectors.number(value), epoch > 0 else { return nil }
        let seconds = epoch > 1e12 ? epoch / 1_000 : epoch
        return Date(timeIntervalSince1970: seconds)
    }
}
