import Darwin
import Foundation

actor KimiUsageClient {
    struct UsageResult: Sendable {
        let limits: [LimitWindow]
        let balances: [AccountBalance]
        let plan: String
        let fetchedAt: Date

        init(limits: [LimitWindow], balances: [AccountBalance] = [], plan: String = "", fetchedAt: Date) {
            self.limits = limits
            self.balances = balances
            self.plan = plan
            self.fetchedAt = fetchedAt
        }
    }

    private let fm = FileManager.default
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let clientID = "17e5f671-d194-4dfb-9706-5516cb48c098"
    private let authURL = URL(string: "https://auth.kimi.com/api/oauth/token")!
    private let usageURL = URL(string: "https://api.kimi.com/coding/v1/usages")!
    private let armURL = URL(string: "https://api.kimi.com/coding/v1/messages")!
    private var lastRemoteFetch: Date?
    private var lastResult: UsageResult?

    /// 窗口点火：发一个最小 /coding/v1/messages 请求，在 5 小时窗口重置后
    /// 立刻开启新窗口。该端点接受 kimi-code 凭据（Bearer），订阅内 16 个
    /// token 消耗可忽略；窗口活跃时请求只是正常并入。
    func arm(model: String) async throws {
        let credentialURL = home.appending(path: ".kimi-code/credentials/kimi-code.json")
        guard
            let credentialData = try? Data(contentsOf: credentialURL),
            var credential = try? JSONSerialization.jsonObject(
                with: credentialData
            ) as? [String: Any]
        else {
            throw CollectorError.invalidCredential
        }
        do {
            try await sendArmRequest(
                token: credential["access_token"] as? String ?? "",
                model: model
            )
        } catch CollectorError.http(401) {
            // 401 时尝试刷新一次（凭据文件里有 refresh_token 才可能成功）。
            guard
                let fresh = try? await refreshCredential(
                    credential,
                    saveTo: credentialURL
                )
            else { throw CollectorError.invalidCredential }
            credential = fresh
            try await sendArmRequest(
                token: credential["access_token"] as? String ?? "",
                model: model
            )
        }
    }

    private func sendArmRequest(token: String, model: String) async throws {
        guard !token.isEmpty else { throw CollectorError.invalidCredential }
        var request = URLRequest(url: armURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyKimiHeaders(to: &request)
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": model.isEmpty ? "kimi-k2-turbo-preview" : model,
            "max_tokens": 16,
            "messages": [["role": "user", "content": "hi"]]
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw CollectorError.http(401) }
        guard (200..<300).contains(status) else { throw CollectorError.http(status) }
        _ = data
    }

    private var webCredentialURL: URL {
        home.appending(path: ".kimi-code/credentials/kimi-web.json")
    }

    func fetchIfNeeded(
        force: Bool,
        allowRemote: Bool,
        kimiIsWorking: Bool
    ) async throws -> UsageResult {
        if
            !force,
            let lastRemoteFetch,
            let lastResult,
            Date().timeIntervalSince(lastRemoteFetch) < 300
        {
            return lastResult
        }

        if !force, !allowRemote {
            if let lastResult { return lastResult }
            if let cached = loadCachedUsage() { return cached }
            throw CollectorError.invalidCredential
        }

        // 1. Attempt fetching Kimi Code official CLI usage
        var codeObject: [String: Any]?
        var planName: String?
        let credentialURL = home.appending(path: ".kimi-code/credentials/kimi-code.json")
        if let credentialData = try? Data(contentsOf: credentialURL),
           var credential = try? JSONSerialization.jsonObject(with: credentialData) as? [String: Any] {
            var accessToken = credential["access_token"] as? String ?? ""
            let expiresAt = LocalCollectors.number(credential["expires_at"]) ?? 0
            if accessToken.isEmpty || expiresAt < Date().timeIntervalSince1970 + 90 {
                if !kimiIsWorking {
                    if let fresh = try? await refreshCredential(credential, saveTo: credentialURL) {
                        credential = fresh
                        accessToken = credential["access_token"] as? String ?? ""
                    }
                }
            }

            if !accessToken.isEmpty {
                var request = URLRequest(url: usageURL)
                request.timeoutInterval = 10
                request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                applyKimiHeaders(to: &request)

                if let (data, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                   let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    codeObject = parsed
                }

                planName = await fetchUserPlan(accessToken: accessToken)
            }
        }

        // 2. Attempt fetching web membership subscription stats (for monthly quota & web limits)
        let webStats = await fetchWebSubscriptionStats()

        // 3. Merge or fallback
        var mergedObject = codeObject ?? [:]
        if let webStats {
            mergedObject = Self.enrichWithWebStats(mergedObject, webStats: webStats)
        }
        if let planName, !planName.isEmpty {
            mergedObject["_quotabar_plan"] = planName
        }

        guard !mergedObject.isEmpty else {
            if let cached = loadCachedUsage() { return cached }
            throw CollectorError.invalidCredential
        }

        let plan = (mergedObject["_quotabar_plan"] as? String) ?? ""
        let result = UsageResult(
            limits: Self.parseUsage(mergedObject),
            balances: Self.parseBoosterBalance(mergedObject),
            plan: plan,
            fetchedAt: Date()
        )
        lastRemoteFetch = Date()
        lastResult = result
        try? saveUsageCache(mergedObject, at: result.fetchedAt)
        return result
    }

    private func refreshCredential(
        _ old: [String: Any],
        saveTo url: URL
    ) async throws -> [String: Any] {
        guard let refreshToken = old["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CollectorError.invalidCredential
        }

        var request = URLRequest(url: authURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        applyKimiHeaders(to: &request)
        let form = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        request.httpBody = form
            .map { key, value in "\(urlEncode(key))=\(urlEncode(value))" }
            .sorted()
            .joined(separator: "&")
            .data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw CollectorError.http(status) }
        guard var fresh = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CollectorError.invalidCredential
        }

        let expiresIn = LocalCollectors.number(fresh["expires_in"]) ?? 0
        fresh["expires_at"] = Date().timeIntervalSince1970 + expiresIn
        if fresh["refresh_token"] == nil {
            fresh["refresh_token"] = refreshToken
        }
        if fresh["scope"] == nil { fresh["scope"] = old["scope"] }
        if fresh["token_type"] == nil { fresh["token_type"] = old["token_type"] }

        let encoded = try JSONSerialization.data(
            withJSONObject: fresh,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try encoded.write(to: url, options: .atomic)
        chmod(url.path, S_IRUSR | S_IWUSR)
        return fresh
    }

    static func parseUsage(_ object: [String: Any]) -> [LimitWindow] {
        var rows: [LimitWindow] = []

        // 1. Direct usages mapping (Kimi Code /usages payload)
        if let usages = object["usages"] as? [String: Any] {
            if let month = usages["limit_month_total"] as? [String: Any] ?? usages["monthTotal"] as? [String: Any],
               let row = quotaEntryWindow(month, label: "月额度", id: "month-total", windowMinutes: 43_200) {
                rows.append(row)
            }
            if let fiveHour = usages["limit_5h"] as? [String: Any] ?? usages["limit5h"] as? [String: Any],
               let row = quotaEntryWindow(fiveHour, label: "5 小时", id: "limit-5h", windowMinutes: 300) {
                rows.append(row)
            }
            if let sevenDay = usages["limit_7d"] as? [String: Any] ?? usages["limit7d"] as? [String: Any],
               let row = quotaEntryWindow(sevenDay, label: "7 天", id: "limit-7d", windowMinutes: 10_080) {
                rows.append(row)
            }
        }

        // 2. Rolling summary
        if let usage = object["usage"] as? [String: Any],
           let row = usageWindow(usage, fallbackLabel: "7 天", id: "summary", fallbackMinutes: 10_080) {
            rows.append(row)
        }

        // 3. Limits array
        if let limits = object["limits"] as? [[String: Any]] {
            for (index, item) in limits.enumerated() {
                let detail = (item["detail"] as? [String: Any]) ?? item
                let window = item["window"] as? [String: Any]
                let (label, minutes) = usageLabelAndMinutes(item: item, detail: detail, window: window, index: index)
                if let row = usageWindow(detail, fallbackLabel: label, id: "limit-\(index)", fallbackMinutes: minutes) {
                    rows.append(row)
                }
            }
        }

        var seen = Set<String>()
        let unique = rows.filter { row in
            seen.insert(row.label).inserted
        }
        // Support up to 3 standard windows (5 hours, 7 days, monthly quota),
        // ordered by window duration so shorter rolling windows lead.
        return QuotaWindowSelector.ordered(Array(unique.prefix(3)))
    }

    static func parseBoosterBalance(_ object: [String: Any]) -> [AccountBalance] {
        if let wallet = object["booster_wallet"] as? [String: Any] ?? object["boosterWallet"] as? [String: Any],
           let balance = wallet["balance"] as? [String: Any] {
            let currency = (wallet["currency"] as? String) ?? "CNY"
            let rawAmount = LocalCollectors.number(balance["amountLeft"]) ?? LocalCollectors.number(balance["amount"]) ?? 0
            if rawAmount > 0 {
                let amountInCurrency = Decimal(rawAmount) / 100
                return [AccountBalance(currency: currency, total: amountInCurrency, granted: 0, toppedUp: amountInCurrency)]
            }
        }

        if let webStats = object["_quotabar_web_stats"] as? [String: Any],
           let wallets = webStats["boosterWallets"] as? [[String: Any]] {
            for wallet in wallets {
                if let moneyLeft = wallet["moneyLeft"] as? [String: Any],
                   let cents = LocalCollectors.number(moneyLeft["priceInCents"]),
                   cents > 0 {
                    let currency = (moneyLeft["currency"] as? String) ?? "CNY"
                    let amount = Decimal(cents) / 100
                    return [AccountBalance(currency: currency, total: amount, granted: 0, toppedUp: amount)]
                }
            }
        }

        return []
    }

    private static func quotaEntryWindow(
        _ object: [String: Any],
        label: String,
        id: String,
        windowMinutes: Int
    ) -> LimitWindow? {
        guard let usedRatio = LocalCollectors.number(object["used_ratio"]) ?? LocalCollectors.number(object["usedRatio"]) else { return nil }
        let remainingPercent = max(0, min(100, (1.0 - usedRatio) * 100))
        let resetAt = parseReset(object)
        return LimitWindow(
            id: id,
            label: label,
            remainingPercent: remainingPercent,
            resetAt: resetAt,
            windowMinutes: windowMinutes
        )
    }

    private static func usageWindow(
        _ object: [String: Any],
        fallbackLabel: String,
        id: String,
        fallbackMinutes: Int? = nil
    ) -> LimitWindow? {
        guard let limit = LocalCollectors.number(object["limit"]), limit > 0 else { return nil }
        let used: Double
        if let value = LocalCollectors.number(object["used"]) {
            used = value
        } else if let remaining = LocalCollectors.number(object["remaining"]) {
            used = limit - remaining
        } else {
            return nil
        }

        let label = (object["name"] as? String)
            ?? (object["title"] as? String)
            ?? fallbackLabel
        let resetAt = parseReset(object)
        let finalLabel = translatedLabel(label)
        let minutes = fallbackMinutes ?? LimitWindow.minutes(fromLabel: finalLabel)
        return LimitWindow(
            id: id,
            label: finalLabel,
            remainingPercent: (limit - used) / limit * 100,
            resetAt: resetAt,
            windowMinutes: minutes == .max ? nil : minutes
        )
    }

    private static func usageLabelAndMinutes(
        item: [String: Any],
        detail: [String: Any],
        window: [String: Any]?,
        index: Int
    ) -> (String, Int?) {
        for key in ["name", "title", "scope"] {
            if let value = item[key] as? String ?? detail[key] as? String {
                let label = translatedLabel(value)
                return (label, LimitWindow.minutes(fromLabel: label))
            }
        }
        let duration = Int(
            LocalCollectors.number(window?["duration"])
                ?? LocalCollectors.number(item["duration"])
                ?? LocalCollectors.number(detail["duration"])
                ?? 0
        )
        let unit = (
            window?["timeUnit"] as? String
                ?? item["timeUnit"] as? String
                ?? detail["timeUnit"] as? String
                ?? ""
        ).uppercased()
        if unit.contains("MINUTE") {
            return (LocalCollectors.windowLabel(minutes: duration), duration)
        }
        if unit.contains("HOUR") {
            return ("\(duration) 小时", duration * 60)
        }
        if unit.contains("DAY") {
            if duration >= 28 && duration <= 31 {
                return ("月额度", 43_200)
            }
            return ("\(duration) 天", duration * 1_440)
        }
        if unit.contains("MONTH") {
            return ("月额度", 43_200 * max(1, duration))
        }
        return ("额度 \(index + 1)", nil)
    }

    private static func parseReset(_ object: [String: Any]) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] {
            if let value = object[key] {
                if let epoch = LocalCollectors.number(value), epoch > 0 {
                    return Date(timeIntervalSince1970: epoch)
                }
                if let string = value as? String {
                    if let date = ISO8601DateFormatter().date(from: string) {
                        return date
                    }
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: string) { return date }
                }
            }
        }
        for key in ["reset_in", "resetIn", "ttl"] {
            if let seconds = LocalCollectors.number(object[key]), seconds > 0 {
                return Date().addingTimeInterval(seconds)
            }
        }
        return nil
    }

    private static func translatedLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("month") || lower.contains("月") { return "月额度" }
        if lower.contains("week") || lower.contains("周") { return "7 天" }
        if lower.contains("5h") || lower.contains("5 h") { return "5 小时" }
        if lower.contains("day") { return label.replacingOccurrences(of: "days", with: "天") }
        return label
    }

    private func applyKimiHeaders(to request: inout URLRequest) {
        request.setValue("kimi_cli", forHTTPHeaderField: "X-Msh-Platform")
        request.setValue("QuotaBar/\(AppVersion.short)", forHTTPHeaderField: "X-Msh-Version")
        if let deviceID = try? String(
            contentsOf: home.appending(path: ".kimi-code/device_id"),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines), !deviceID.isEmpty {
            request.setValue(deviceID, forHTTPHeaderField: "X-Msh-Device-Id")
        }
    }

    private func urlEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(
            CharacterSet(charactersIn: "&=+")
        )) ?? value
    }

    private func cacheURL() -> URL {
        home.appending(path: ".quotabar/kimi-usage.json")
    }

    private func saveUsageCache(_ object: [String: Any], at date: Date) throws {
        var payload = object
        payload["_quotabar_fetched_at"] = date.timeIntervalSince1970
        let directory = cacheURL().deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try data.write(to: cacheURL(), options: .atomic)
        chmod(cacheURL().path, S_IRUSR | S_IWUSR)
    }

    private func loadCachedUsage() -> UsageResult? {
        guard
            let data = try? Data(contentsOf: cacheURL()),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        let date = LocalCollectors.number(object["_quotabar_fetched_at"])
            .map { Date(timeIntervalSince1970: $0) }
            ?? .distantPast
        let plan = (object["_quotabar_plan"] as? String) ?? ""
        let result = UsageResult(
            limits: Self.parseUsage(object),
            balances: Self.parseBoosterBalance(object),
            plan: plan,
            fetchedAt: date
        )
        lastResult = result
        return result
    }

    // MARK: - Web Subscription Stats Integration

    static func enrichWithWebStats(_ base: [String: Any], webStats: [String: Any]) -> [String: Any] {
        var merged = base
        var usages = (merged["usages"] as? [String: Any]) ?? [:]

        // 1. Subscription monthly quota
        if let subBalance = webStats["subscriptionBalance"] as? [String: Any] {
            let ratio = LocalCollectors.number(subBalance["amountUsedRatio"])
                ?? LocalCollectors.number(subBalance["amount_used_ratio"])
                ?? 0
            let resetTime = (subBalance["expireTime"] as? String)
                ?? (subBalance["expire_time"] as? String)
                ?? ""
            usages["limit_month_total"] = [
                "used_ratio": ratio,
                "reset_time": resetTime
            ]
        }

        // 2. Fallbacks for 5h and 7d if missing from CLI response
        if usages["limit_5h"] == nil,
           let code5h = webStats["ratelimitCode5h"] as? [String: Any] ?? webStats["ratelimit_code_5h"] as? [String: Any],
           let ratio = LocalCollectors.number(code5h["ratio"]) {
            usages["limit_5h"] = [
                "used_ratio": ratio,
                "reset_time": code5h["resetTime"] ?? code5h["reset_time"] ?? ""
            ]
        }

        if usages["limit_7d"] == nil,
           let code7d = webStats["ratelimitCode7d"] as? [String: Any] ?? webStats["ratelimit_code_7d"] as? [String: Any],
           let ratio = LocalCollectors.number(code7d["ratio"]) {
            usages["limit_7d"] = [
                "used_ratio": ratio,
                "reset_time": code7d["resetTime"] ?? code7d["reset_time"] ?? ""
            ]
        }

        merged["usages"] = usages
        merged["_quotabar_web_stats"] = webStats
        return merged
    }

    private func fetchWebSubscriptionStats() async -> [String: Any]? {
        do {
            let accessToken = try await resolveWebAccessToken()
            guard let url = URL(string: "https://www.kimi.com/apiv2/kimi.gateway.membership.v2.MembershipService/GetSubscriptionStats") else {
                return nil
            }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 10
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko)", forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.kimi.com/membership/subscription?tab=quota", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: [:])

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }

    private func resolveWebAccessToken() async throws -> String {
        let now = Date().timeIntervalSince1970

        // 1. Check existing saved web credential
        if let data = try? Data(contentsOf: webCredentialURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let expiresAt = LocalCollectors.number(json["expires_at"]) ?? 0
            if let accessToken = json["access_token"] as? String, !accessToken.isEmpty, expiresAt > now + 60 {
                return accessToken
            }
            if let refreshToken = json["refresh_token"] as? String, !refreshToken.isEmpty {
                if let refreshed = try? await refreshWebAccessToken(refreshToken: refreshToken) {
                    return refreshed
                }
            }
        }

        // 2. Discover refresh token from local storage (Kimi Desktop or Chromium browsers)
        if let discoveredToken = findLocalWebRefreshToken() {
            return try await refreshWebAccessToken(refreshToken: discoveredToken)
        }

        throw CollectorError.invalidCredential
    }

    private func refreshWebAccessToken(refreshToken: String) async throws -> String {
        guard let url = URL(string: "https://auth.kimi.com/api/account.gateway.v1.AuthService/RefreshToken") else {
            throw CollectorError.invalidCredential
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("https://www.kimi.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.kimi.com/", forHTTPHeaderField: "Referer")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["refreshToken": refreshToken])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw CollectorError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let newAccessToken = json["accessToken"] as? String, !newAccessToken.isEmpty else {
            throw CollectorError.invalidCredential
        }

        let newRefreshToken = (json["refreshToken"] as? String) ?? refreshToken
        let expiresAt = decodeJwtExp(newAccessToken) ?? (Date().timeIntervalSince1970 + 600)
        let savedPayload: [String: Any] = [
            "access_token": newAccessToken,
            "refresh_token": newRefreshToken,
            "expires_at": expiresAt
        ]
        let credDir = webCredentialURL.deletingLastPathComponent()
        try? fm.createDirectory(at: credDir, withIntermediateDirectories: true)
        if let encoded = try? JSONSerialization.data(withJSONObject: savedPayload, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: webCredentialURL, options: .atomic)
            chmod(webCredentialURL.path, S_IRUSR | S_IWUSR)
        }
        return newAccessToken
    }

    private func findLocalWebRefreshToken() -> String? {
        let candidateDirs = [
            home.appending(path: "Library/Application Support/kimi-desktop/Local Storage/leveldb"),
            home.appending(path: "Library/Application Support/Google/Chrome/Default/Local Storage/leveldb"),
            home.appending(path: "Library/Application Support/Microsoft Edge/Default/Local Storage/leveldb")
        ]

        guard let jwtPattern = try? NSRegularExpression(pattern: "ey[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}\\.[A-Za-z0-9_-]{20,}") else {
            return nil
        }

        var candidates: [(exp: TimeInterval, token: String)] = []
        let now = Date().timeIntervalSince1970

        for dir in candidateDirs {
            guard let files = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for fileName in files where fileName.hasSuffix(".log") || fileName.hasSuffix(".ldb") {
                let fileURL = dir.appending(path: fileName)
                guard let data = try? Data(contentsOf: fileURL),
                      let content = String(data: data, encoding: .isoLatin1) else { continue }

                let matches = jwtPattern.matches(in: content, range: NSRange(location: 0, length: content.utf16.count))
                for match in matches {
                    guard let range = Range(match.range, in: content) else { continue }
                    let tokenStr = String(content[range])
                    guard let payload = decodeJwtPayload(tokenStr) else { continue }
                    let typ = payload["typ"] as? String
                    let exp = (payload["exp"] as? Double) ?? ((payload["exp"] as? Int).map { Double($0) } ?? 0)
                    let sub = payload["sub"] as? String
                    if (typ == "refresh" || typ == nil), exp > now, sub != nil {
                        candidates.append((exp, tokenStr))
                    }
                }
            }
        }

        candidates.sort { $0.exp > $1.exp }
        return candidates.first?.token
    }

    private func decodeJwtPayload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var base64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func decodeJwtExp(_ token: String) -> TimeInterval? {
        guard let payload = decodeJwtPayload(token) else { return nil }
        return (payload["exp"] as? Double) ?? ((payload["exp"] as? Int).map { Double($0) })
    }

    private func fetchUserPlan(accessToken: String) async -> String? {
        guard let url = URL(string: "https://api.kimi.com/coding/v1/me") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        applyKimiHeaders(to: &request)

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["user_level_name"] as? String) ?? (json["userLevelName"] as? String)
    }
}
