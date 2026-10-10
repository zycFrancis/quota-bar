import Foundation

/// GLM Coding Plan 凭证解析。零弹窗原则：只读环境变量与本地配置文件，
/// 不触碰 macOS 钥匙串，避免每次刷新都要求授权。
enum GlmCredentialStore {
    private static let memo = CredentialMemo()

    private final class CredentialMemo: @unchecked Sendable {
        private let lock = NSLock()
        /// Outer nil = 未查询，inner nil = 无凭证。
        private var value: String??

        func cached() -> String?? {
            lock.withLock { value }
        }

        func store(_ newValue: String?) {
            lock.withLock { value = newValue }
        }

        func clear() {
            lock.withLock { value = nil }
        }
    }

    static func load() -> String? {
        if let cached = memo.cached() { return cached }
        let key = resolve()
        memo.store(key)
        return key
    }

    static func hasCredential() -> Bool {
        load() != nil
    }

    private static func resolve() -> String? {
        // 1. 环境变量（Z.AI 官方变量名优先，兼容 GLM_API_KEY 旧名）
        let env = ProcessInfo.processInfo.environment
        for name in ["ZAI_CODING_CN_API_KEY", "GLM_API_KEY", "ZAI_API_KEY"] {
            if
                let key = env[name],
                !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return normalized(key)
            }
        }
        // 2. DeepSeek Harness 凭据库 ~/.dsh/.credentials.yaml 的 refs 段
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appending(path: ".dsh/.credentials.yaml"),
            home.appending(path: ".dsh/credentials.yaml"),
            home.appending(path: ".dsh/.credentials.yml")
        ]
        for url in candidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let key = extractFromYaml(content) {
                return normalized(key)
            }
        }
        // 3. Z.AI CLI 本地配置
        let zaiCandidates = [
            home.appending(path: ".zai/credentials.json"),
            home.appending(path: ".config/zai/credentials.json")
        ]
        for url in zaiCandidates {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { continue }
            if let key = extractFromJSON(content) {
                return normalized(key)
            }
        }
        return nil
    }

    /// 行级 YAML 解析：在 refs: 段下找 ZAI_CODING_CN_API_KEY / GLM_API_KEY 键。
    /// 不引入 YAML 依赖，凭据库的平面结构用逐行扫描足够可靠。
    private static func extractFromYaml(_ content: String) -> String? {
        let wantedKeys: Set<String> = ["zai_coding_cn_api_key", "glm_api_key", "zai_api_key"]
        var inRefs = false
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indent = rawLine.prefix(while: { $0 == " " }).count
            if !line.hasPrefix("-"), indent == 0 {
                inRefs = line.hasPrefix("refs:")
                continue
            }
            guard inRefs, let sep = line.firstIndex(of: ":") else { continue }
            let keyPart = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
            guard wantedKeys.contains(keyPart) else { continue }
            let value = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
            let cleaned = normalized(value)
            if !cleaned.isEmpty && cleaned != "null" && cleaned != "~" {
                return cleaned
            }
        }
        return nil
    }

    private static func extractFromJSON(_ content: String) -> String? {
        guard let data = content.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        for key in ["ZAI_CODING_CN_API_KEY", "GLM_API_KEY", "ZAI_API_KEY", "api_key"] {
            if let key = obj[key] as? String {
                let cleaned = normalized(key)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private static func normalized(_ value: String) -> String {
        var key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.lowercased().hasPrefix("bearer ") {
            key = String(key.dropFirst(7))
        }
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            key.count >= 2,
            let first = key.first,
            let last = key.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            key.removeFirst()
            key.removeLast()
        }
        return key.components(separatedBy: .whitespacesAndNewlines).joined()
    }
}

/// GLM Coding Plan 剩余额度客户端。
/// 端点：GET {base}/api/monitor/usage/quota/limit，国内版 base = open.bigmodel.cn。
/// 响应 data.limits 中 TOKENS_LIMIT number==5 为 5 小时窗口，
/// TOKENS_LIMIT number!=5 为每周窗口，TIME_LIMIT 为 MCP 月度额度。
actor GlmUsageClient {
    struct UsageResult: Sendable {
        let limits: [LimitWindow]
        let plan: String
        let fetchedAt: Date
    }

    enum ClientError: LocalizedError {
        case missingCredential
        case invalidCredential
        case invalidResponse(String)
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingCredential:
                "GLM API Key 未配置（ZAI_CODING_CN_API_KEY 或 ~/.dsh/.credentials.yaml）"
            case .invalidCredential:
                "GLM API Key 无效。"
            case .invalidResponse(let message):
                "GLM 额度服务返回无法解析的数据：\(message)"
            case .http(let status):
                "GLM 额度服务返回 HTTP \(status)。"
            }
        }
    }

    private let quotaURL = URL(string: "https://open.bigmodel.cn/api/monitor/usage/quota/limit")!
    private let messagesURL = URL(string: "https://open.bigmodel.cn/api/anthropic/v1/messages")!
    private var lastResult: UsageResult?

    /// 窗口点火：发一个最小 /v1/messages 请求，在 5 小时窗口重置后立刻
    /// 开启新窗口。订阅套餐按 token 计费，16 个 token 的消耗可忽略；
    /// 若窗口本就活跃，该请求只是正常并入，不会扰动窗口。
    func arm(model: String) async throws {
        guard let key = GlmCredentialStore.load() else {
            throw ClientError.missingCredential
        }
        var request = URLRequest(url: messagesURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        // 实测该端点 Authorization 直接放裸 key（Bearer 前缀也会被剥掉）。
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.isEmpty ? "glm-4.5-air" : model,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ClientError.invalidCredential }
        guard (200..<300).contains(status) else { throw ClientError.http(status) }
        _ = data
    }

    func fetchIfNeeded(force: Bool) async throws -> UsageResult {
        if
            !force,
            let lastResult,
            Date().timeIntervalSince(lastResult.fetchedAt) < 300
        {
            return lastResult
        }
        guard let key = GlmCredentialStore.load() else {
            throw ClientError.missingCredential
        }
        return try await fetch(apiKey: key)
    }

    private func fetch(apiKey key: String) async throws -> UsageResult {
        var request = URLRequest(url: quotaURL)
        request.timeoutInterval = 10
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(AppVersion.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw ClientError.invalidCredential }
        guard (200..<300).contains(status) else { throw ClientError.http(status) }

        let result = try Self.parseResponse(data, fetchedAt: Date())
        lastResult = result
        return result
    }

    static func parseResponse(
        _ data: Data,
        fetchedAt: Date = Date()
    ) throws -> UsageResult {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse("not JSON")
        }
        guard object["success"] as? Bool == true else {
            let message = (object["msg"] ?? object["error"]) as? String ?? "query failed"
            throw ClientError.invalidResponse(message)
        }
        let payload = object["data"] as? [String: Any] ?? [:]
        let rawLimits = payload["limits"] as? [[String: Any]] ?? []
        let plan = payload["level"] as? String ?? "GLM Coding Plan"

        var limits: [LimitWindow] = []
        let tokens = rawLimits.filter { $0["type"] as? String == "TOKENS_LIMIT" }
        let fiveHour = tokens.first { number($0["number"]) == 5 }
        if let window = Self.window(from: fiveHour, id: "glm-5h", label: "5h", minutes: 300) {
            limits.append(window)
        }
        let weekly = tokens.first { number($0["number"]) != 5 }
        if let window = Self.window(from: weekly, id: "glm-weekly", label: "weekly", minutes: 10_080) {
            limits.append(window)
        }
        let monthly = rawLimits.first { $0["type"] as? String == "TIME_LIMIT" }
        if let window = Self.window(from: monthly, id: "glm-mcp-monthly", label: "MCP monthly", minutes: 43_200) {
            limits.append(window)
        }
        guard !limits.isEmpty else {
            throw ClientError.invalidResponse("no limits")
        }
        return UsageResult(limits: limits, plan: plan, fetchedAt: fetchedAt)
    }

    private static func window(
        from item: [String: Any]?,
        id: String,
        label: String,
        minutes: Int
    ) -> LimitWindow? {
        guard let item else { return nil }
        // GLM 的 percentage 是已用百分比，剩余 = 100 - 已用。
        guard let usedPercent = number(item["percentage"]) else { return nil }
        let remaining = min(max(100 - usedPercent, 0), 100)
        let resetAt = Self.resetDate(item["nextResetTime"])
        return LimitWindow(
            id: id,
            label: label,
            remainingPercent: remaining,
            resetAt: resetAt,
            windowMinutes: minutes
        )
    }

    /// 线上形态是 Unix 毫秒时间戳（如 1791547256894）；
    /// 兼容历史/国际端的 ISO 8601 字符串。
    private static func resetDate(_ value: Any?) -> Date? {
        if let timestamp = number(value), timestamp > 0 {
            // 大于 1e12 视为毫秒，否则按秒。
            let seconds = timestamp > 1e12 ? timestamp / 1_000 : timestamp
            return Date(timeIntervalSince1970: seconds)
        }
        if let iso = value as? String, !iso.isEmpty {
            return date(iso)
        }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let int = value as? Int { return Double(int) }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func date(_ iso: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: iso) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)
    }
}
