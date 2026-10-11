import Foundation

actor CodexUsageClient {
    struct UsageResult: Sendable {
        let limits: [LimitWindow]
        let fetchedAt: Date
        let plan: String
        var balances: [AccountBalance] = []
        var resetCards: ResetCardInfo? = nil
    }

    enum UsageError: LocalizedError {
        case executableMissing
        case launchFailed
        case timedOut
        case invalidResponse
        case credentialExpired
        case server(String)

        var errorDescription: String? {
            switch self {
            case .executableMissing:
                "The official Codex executable could not be found."
            case .launchFailed:
                "The Codex account reader could not be started."
            case .timedOut:
                "The Codex account reader timed out."
            case .invalidResponse:
                "Codex returned an unreadable account-usage response."
            case .credentialExpired:
                "Codex sign-in expired; run `codex login`."
            case .server(let message):
                "Codex account reader error: \(message)"
            }
        }
    }

    private var lastRemoteFetch: Date?
    private var lastResult: UsageResult?
    private var lastResponse: Data?
    private var cachedResetCards: ResetCardInfo?
    private var lastResetCardSyncDate: Date?

    init() {
        if let data = UserDefaults.standard.data(forKey: "codex_reset_cards_cache"),
           let cached = try? JSONDecoder().decode(ResetCardInfo.self, from: data) {
            self.cachedResetCards = cached
            self.lastResetCardSyncDate = cached.lastSyncDate
        }
    }

    private func shouldSyncResetCards() -> Bool {
        guard let lastSync = lastResetCardSyncDate, cachedResetCards != nil else {
            return true
        }
        return !Calendar.current.isDateInToday(lastSync) || Date().timeIntervalSince(lastSync) >= 86_400
    }

    func fetchIfNeeded(
        force: Bool,
        language: AppLanguage
    ) async throws -> UsageResult {
        if
            !force,
            let lastRemoteFetch,
            let lastResult,
            Date().timeIntervalSince(lastRemoteFetch) < 300
        {
            if let lastResponse {
                return try Self.parseResponse(
                    lastResponse,
                    fetchedAt: lastResult.fetchedAt,
                    language: language,
                    resetCards: cachedResetCards
                )
            }
            return lastResult
        }

        // id_token 过期时服务端可能返回失真数据（如恒 0%），先挡住并提示重新登录。
        if Self.isCredentialExpired() {
            throw UsageError.credentialExpired
        }

        let response = try await Task.detached(priority: .utility) {
            try Self.readAccountRateLimits()
        }.value

        // Daily sync for reset cards (synced at most once per calendar day / 24h)
        if shouldSyncResetCards(),
           let envelope = try? JSONSerialization.jsonObject(with: response) as? [String: Any],
           let newCards = Self.parseResetCredits(envelope, syncDate: Date()) {
            self.cachedResetCards = newCards
            self.lastResetCardSyncDate = newCards.lastSyncDate
            if let encoded = try? JSONEncoder().encode(newCards) {
                UserDefaults.standard.set(encoded, forKey: "codex_reset_cards_cache")
            }
        }

        let result = try Self.parseResponse(
            response,
            fetchedAt: Date(),
            language: language,
            resetCards: cachedResetCards
        )
        lastRemoteFetch = result.fetchedAt
        lastResult = result
        lastResponse = response
        return result
    }

    static func parseResponse(
        _ data: Data,
        fetchedAt: Date = Date(),
        language: AppLanguage = .chinese,
        resetCards: ResetCardInfo? = nil
    ) throws -> UsageResult {
        guard
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw UsageError.invalidResponse
        }
        if let error = envelope["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "unknown error"
            throw UsageError.server(message)
        }
        guard let result = envelope["result"] as? [String: Any] else {
            throw UsageError.invalidResponse
        }

        let rateLimits: [String: Any]? = {
            if
                let byID = result["rateLimitsByLimitId"] as? [String: Any],
                let codex = byID["codex"] as? [String: Any]
            {
                return codex
            }
            return result["rateLimits"] as? [String: Any]
        }()
        guard let rateLimits else { throw UsageError.invalidResponse }

        var limits: [LimitWindow] = []
        for (id, key) in [("primary", "primary"), ("secondary", "secondary")] {
            guard let window = rateLimits[key] as? [String: Any] else { continue }
            let used = LocalCollectors.number(window["usedPercent"]) ?? 0
            let minutes = Int(LocalCollectors.number(window["windowDurationMins"]) ?? 0)
            let resetAt = LocalCollectors.number(window["resetsAt"]).flatMap {
                $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
            }
            limits.append(
                LimitWindow(
                    id: "account-\(id)-\(minutes)",
                    label: windowLabel(minutes: minutes, language: language),
                    remainingPercent: 100 - used,
                    resetAt: resetAt,
                    windowMinutes: minutes > 0 ? minutes : nil
                )
            )
        }
        guard !limits.isEmpty else { throw UsageError.invalidResponse }

        let plan = (rateLimits["planType"] as? String ?? "")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized

        var balances: [AccountBalance] = []
        if
            let credits = rateLimits["credits"] as? [String: Any],
            let balanceValue = credits["balance"],
            let amount = LocalCollectors.number(balanceValue),
            amount > 0
        {
            let decimal = Decimal(string: "\(amount)") ?? Decimal(amount)
            balances.append(
                AccountBalance(
                    currency: "USD",
                    total: decimal,
                    granted: 0,
                    toppedUp: decimal
                )
            )
        }

        let finalResetCards: ResetCardInfo? = {
            if let resetCards { return resetCards }
            return parseResetCredits(envelope, syncDate: fetchedAt)
        }()

        return UsageResult(
            limits: QuotaWindowSelector.ordered(limits),
            fetchedAt: fetchedAt,
            plan: plan,
            balances: balances,
            resetCards: finalResetCards
        )
    }

    nonisolated static func parseResetCredits(
        _ envelope: [String: Any],
        syncDate: Date = Date()
    ) -> ResetCardInfo? {
        guard let result = envelope["result"] as? [String: Any],
              let resetCreditsObj = result["rateLimitResetCredits"] as? [String: Any],
              let availableCount = LocalCollectors.number(resetCreditsObj["availableCount"])
        else {
            return nil
        }
        var items: [ResetCardItem] = []
        if let creditsArray = resetCreditsObj["credits"] as? [[String: Any]] {
            let activeCredits = creditsArray.filter { ($0["status"] as? String) == "available" }
            for (idx, credit) in activeCredits.enumerated() {
                let creditId = credit["id"] as? String ?? "card-\(idx + 1)"
                let title = credit["title"] as? String ?? "Full reset"
                let desc = credit["description"] as? String
                let exp = LocalCollectors.number(credit["expiresAt"]).flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
                let granted = LocalCollectors.number(credit["grantedAt"]).flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
                }
                items.append(
                    ResetCardItem(
                        id: creditId,
                        title: title,
                        expiresAt: exp,
                        grantedAt: granted,
                        descriptionText: desc
                    )
                )
            }
        }
        items.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }

        return ResetCardInfo(
            availableCount: Int(availableCount),
            items: items,
            lastSyncDate: syncDate
        )
    }

    private nonisolated static func windowLabel(
        minutes: Int,
        language: AppLanguage
    ) -> String {
        guard language == .english else {
            return LocalCollectors.windowLabel(minutes: minutes)
        }
        return switch minutes {
        case 300: "5 hours"
        case 1_440: "1 day"
        case 10_080: "7 days"
        case let value where value > 0 && value % 1_440 == 0:
            "\(value / 1_440) days"
        case let value where value > 0 && value % 60 == 0:
            "\(value / 60) hours"
        case let value where value > 0:
            "\(value) minutes"
        default:
            "Quota"
        }
    }

    /// ~/.codex/auth.json 的 access_token 是否已过期（exp < now）。
    /// 注意不能用 id_token 判断：它只有 1 小时寿命，CLI 并不会随时刷新，
    /// 拿它判过期会常年误报；access_token 约 10 天，过期才真正不可信。
    nonisolated static func isCredentialExpired() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appending(path: ".codex/auth.json")
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = object["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String
        else {
            return false
        }
        let segments = accessToken.split(separator: ".")
        guard segments.count >= 2 else { return false }
        var base64 = String(segments[1])
        while base64.count % 4 != 0 { base64 += "=" }
        guard let payload = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let exp = LocalCollectors.number(claims["exp"])
        else {
            return false
        }
        return exp < Date().timeIntervalSince1970
    }

    private nonisolated static func readAccountRateLimits() throws -> Data {
        guard let executable = codexExecutable() else {
            throw UsageError.executableMissing
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server", "--stdio"]
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw UsageError.launchFailed
        }

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + 8,
            execute: timeout
        )
        defer {
            timeout.cancel()
            try? input.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
            process.waitUntilExit()
        }

        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "quota-bar",
                        "title": "Quota Bar",
                        "version": AppVersion.short
                    ],
                    "capabilities": ["experimentalApi": true]
                ]
            ],
            to: input.fileHandleForWriting
        )

        var buffer = Data()
        var responseData: Data?
        var sentReadRequest = false
        while process.isRunning, responseData == nil {
            let chunk = output.fileHandleForReading.availableData
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)
            for line in takeLines(from: &buffer) {
                guard
                    let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                    let responseID = LocalCollectors.number(object["id"])
                else {
                    continue
                }
                if responseID == 1, !sentReadRequest {
                    try send(["method": "initialized"], to: input.fileHandleForWriting)
                    try send(
                        [
                            "id": 2,
                            "method": "account/rateLimits/read",
                            "params": NSNull()
                        ],
                        to: input.fileHandleForWriting
                    )
                    sentReadRequest = true
                } else if responseID == 2 {
                    responseData = line
                    break
                }
            }
        }

        if let responseData {
            return responseData
        }
        for line in takeLines(from: &buffer, includeTrailing: true) {
            guard
                let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                LocalCollectors.number(object["id"]) == 2
            else {
                continue
            }
            return line
        }
        if !process.isRunning {
            throw UsageError.timedOut
        }
        throw UsageError.invalidResponse
    }

    private nonisolated static func send(
        _ object: [String: Any],
        to handle: FileHandle
    ) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(0x0A)
        try handle.write(contentsOf: data)
    }

    private nonisolated static func takeLines(
        from buffer: inout Data,
        includeTrailing: Bool = false
    ) -> [Data] {
        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            if !line.isEmpty {
                lines.append(Data(line))
            }
            buffer.removeSubrange(...newline)
        }
        if includeTrailing, !buffer.isEmpty {
            lines.append(buffer)
            buffer.removeAll()
        }
        return lines
    }

    nonisolated static func codexExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "\(home)/Applications/ChatGPT.app/Contents/Resources/codex",
            "\(home)/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates.lazy
            .map(URL.init(fileURLWithPath:))
            .first { isWorkingExecutable($0) }
    }

    private nonisolated static func isWorkingExecutable(_ url: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: url.path) else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in semaphore.signal() }
        do {
            try process.run()
            if semaphore.wait(timeout: .now() + 1.5) == .timedOut {
                process.terminate()
                return false
            }
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
