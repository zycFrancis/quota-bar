import Darwin
import Foundation
import SQLite3

struct LocalSnapshotBundle: Sendable {
    var codex: ProviderSnapshot
    var claude: ProviderSnapshot
    var kimi: ProviderSnapshot
    var glm: ProviderSnapshot
    var gemini: ProviderSnapshot
    var grok: ProviderSnapshot
    var deepseek: ProviderSnapshot
    var devin: ProviderSnapshot

    var all: [ProviderSnapshot] { [codex, claude, kimi, glm, gemini, grok, deepseek, devin] }
}

struct ClaudeDesktopUsage: Sendable {
    var limits: [LimitWindow]
    var capturedAt: Date
}

enum LocalCollectors {
    private static var fm: FileManager { FileManager.default }
    private static var home: URL { fm.homeDirectoryForCurrentUser }

    static func collect(language: AppLanguage) -> LocalSnapshotBundle {
        let processText = processList()
        return LocalSnapshotBundle(
            codex: collectCodex(processText: processText, language: language),
            claude: collectClaude(processText: processText, language: language),
            kimi: collectKimi(processText: processText, language: language),
            glm: collectGlm(language: language),
            gemini: collectGemini(processText: processText, language: language),
            grok: collectGrok(processText: processText, language: language),
            deepseek: collectDeepSeek(processText: processText, language: language),
            devin: collectDevin(language: language)
        )
    }

    static func claudeCollectorInstalled() -> Bool {
        let settingsURL = home.appending(path: ".claude/settings.json")
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = object["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String
        else {
            return false
        }
        guard command.contains("QuotaBarCapture") else { return false }
        guard let hooks = object["hooks"] as? [String: Any] else { return false }
        return hooks.values.contains { value in
            guard let entries = value as? [[String: Any]] else { return false }
            return entries.contains { entry in
                guard let commands = entry["hooks"] as? [[String: Any]] else { return false }
                return commands.contains {
                    ($0["command"] as? String)?.contains("QuotaBarCapture") == true
                }
            }
        }
    }

    static func claudeCollectorNeedsRepair() -> Bool {
        guard claudeCollectorInstalled() else { return true }
        let settingsURL = home.appending(path: ".claude/settings.json")
        guard
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let statusLine = object["statusLine"] as? [String: Any],
            let command = statusLine["command"] as? String,
            let currentHelper = ClaudeCollectorInstaller.helperURL()?.path
        else {
            return true
        }
        let configuredPath = command
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
        return URL(fileURLWithPath: configuredPath).standardizedFileURL.path
            != URL(fileURLWithPath: currentHelper).standardizedFileURL.path
    }

    private static func collectCodex(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let root = home.appending(path: ".codex/sessions")
        let isRunning = processText.localizedCaseInsensitiveContains("/codex")
            || processText.localizedCaseInsensitiveContains("CodexCLI.app")
        var cachedResetCards: ResetCardInfo? = nil
        if let data = UserDefaults.standard.data(forKey: "codex_reset_cards_cache"),
           let cached = try? JSONDecoder().decode(ResetCardInfo.self, from: data) {
            cachedResetCards = cached
        }
        var cachedPrediction: CodexResetPrediction? = nil
        if let data = UserDefaults.standard.data(forKey: "codex_reset_prediction_cache"),
           let cached = try? JSONDecoder().decode(CodexResetPrediction.self, from: data) {
            cachedPrediction = cached
        }

        guard let latest = latestFile(in: root, named: nil, suffix: ".jsonl") else {
            let installed = fm.fileExists(atPath: home.appending(path: ".codex").path)
                || CodexUsageClient.codexExecutable() != nil
            return ProviderSnapshot(
                id: .codex,
                activity: isRunning ? .idle : .offline,
                limits: [],
                detail: language.text("尚未发现 Codex 本地会话", "No local Codex session found"),
                source: language.text("本地会话", "Local sessions"),
                lastUpdated: nil,
                setupAvailable: false,
                isInstalled: installed,
                resetCards: cachedResetCards,
                resetPrediction: cachedPrediction
            )
        }

        let modified = modificationDate(latest)
        let lines = tailLines(of: latest, maxBytes: 4_000_000)
        var limits: [LimitWindow] = []
        var plan = ""
        var eventActivity: ActivityState?

        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }

            if let payload = rootObject["payload"] as? [String: Any] {
                if limits.isEmpty,
                   rootObject["type"] as? String == "event_msg",
                   payload["type"] as? String == "token_count",
                   let rateLimits = payload["rate_limits"] as? [String: Any] {
                    plan = (rateLimits["plan_type"] as? String)?.capitalized ?? ""
                    if let primary = rateLimits["primary"] as? [String: Any] {
                        limits.append(makePercentWindow(primary, fallbackID: "primary"))
                    }
                    if let secondary = rateLimits["secondary"] as? [String: Any] {
                        limits.append(makePercentWindow(secondary, fallbackID: "secondary"))
                    }
                }
                if eventActivity == nil {
                    eventActivity = codexActivity(rootType: rootObject["type"] as? String, payload: payload)
                }
            }
            if !limits.isEmpty, eventActivity != nil { break }
        }

        let liveManagedTasks = liveCodexManagedTaskCount()
        let recentlyChanged = modified.map { Date().timeIntervalSince($0) < 90 } ?? false
        let activity: ActivityState
        if !isRunning {
            activity = .offline
        } else if eventActivity == .waitingApproval {
            activity = .waitingApproval
        } else if eventActivity == .idle, liveManagedTasks == 0 {
            activity = .idle
        } else if liveManagedTasks > 0 || recentlyChanged {
            activity = eventActivity == .thinking ? .thinking : .working
        } else {
            activity = .idle
        }
        let folder = latest.deletingLastPathComponent().lastPathComponent
        let detail = liveManagedTasks > 0
            ? language.text(
                "\(liveManagedTasks) 个任务正在执行",
                "\(liveManagedTasks) task\(liveManagedTasks == 1 ? "" : "s") running"
            )
            : (
                plan.isEmpty
                    ? language.text("最近会话 · \(folder)", "Latest session · \(folder)")
                    : language.text(
                        "\(plan) · 最近会话 \(folder)",
                        "\(plan) · latest session \(folder)"
                    )
            )

        return ProviderSnapshot(
            id: .codex,
            activity: activity,
            limits: limits,
            detail: detail,
            source: language.text(
                "Codex 本地 rate-limit 快照",
                "Local Codex rate-limit snapshot"
            ),
            lastUpdated: modified,
            setupAvailable: false,
            isInstalled: true,
            resetCards: cachedResetCards,
            resetPrediction: cachedPrediction
        )
    }

    private static func collectClaude(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let cache = home.appending(path: ".quotabar/claude-status.json")
        let desktopHistory = home.appending(
            path: "Library/Application Support/Claude/plan-usage-history.json"
        )
        let isRunning = containsStandaloneProcess("claude", in: processText)
        let desktopInstalled = fm.fileExists(atPath: "/Applications/Claude.app")
            || fm.fileExists(atPath: home.appending(path: "Applications/Claude.app").path)
        let installed = desktopInstalled
            || fm.fileExists(atPath: home.appending(path: ".claude").path)
        let collectorInstalled = claudeCollectorInstalled()
        let collectorNeedsRepair = claudeCollectorNeedsRepair()
        let desktopUsage = (try? Data(contentsOf: desktopHistory))
            .flatMap(claudeDesktopUsage)

        let cliObject: [String: Any]? = {
            guard
                let data = try? Data(contentsOf: cache),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                return nil
            }
            return object
        }()
        let cliLimits = cliObject.map(claudeLimits) ?? []

        if var desktopUsage {
            for index in desktopUsage.limits.indices {
                guard desktopUsage.limits[index].resetAt == nil else { continue }
                let matchingCLI = cliLimits.first {
                    normalizedWindow($0.label) == normalizedWindow(
                        desktopUsage.limits[index].label
                    )
                }
                guard let matchingCLI else { continue }
                desktopUsage.limits[index] = LimitWindow(
                    id: desktopUsage.limits[index].id,
                    label: desktopUsage.limits[index].label,
                    remainingPercent: desktopUsage.limits[index].remainingPercent,
                    resetAt: matchingCLI.resetAt,
                    windowMinutes: desktopUsage.limits[index].windowMinutes
                )
            }

            return ProviderSnapshot(
                id: .claude,
                activity: isRunning ? claudeActivity() : .idle,
                limits: desktopUsage.limits,
                detail: language.text(
                    "Claude Desktop · 本地用量历史",
                    "Claude Desktop · local usage history"
                ),
                source: language.text(
                    "Claude Desktop 本地 plan-usage-history.json",
                    "Local Claude Desktop plan-usage-history.json"
                ),
                lastUpdated: desktopUsage.capturedAt,
                setupAvailable: false,
                isInstalled: true
            )
        }

        guard let object = cliObject else {
            let detail: String
            if claudeCommandLinkIsBroken() {
                detail = language.text(
                    "Claude 命令链接失效，请修复后重启 Claude Code",
                    "Claude command link is broken; repair it and restart Claude Code"
                )
            } else if collectorInstalled && !collectorNeedsRepair {
                detail = language.text(
                    "等待 Claude 正常响应后写入额度与重置时间",
                    "Waiting for a normal Claude response to capture quota and reset times"
                )
            } else if installed {
                detail = language.text(
                    "配置或修复零额度 status-line 采集",
                    "Configure or repair zero-token status-line capture"
                )
            } else {
                detail = language.text("未发现 Claude Code", "Claude Code not found")
            }
            return ProviderSnapshot(
                id: .claude,
                activity: isRunning ? claudeActivity() : (installed ? .idle : .offline),
                limits: [],
                detail: detail,
                source: language.text("Claude 官方 status line", "Official Claude status line"),
                lastUpdated: nil,
                setupAvailable: installed && !desktopInstalled,
                isInstalled: installed
            )
        }

        let limits = claudeLimits(object)

        let capturedAt = number(object["captured_at"]).map { Date(timeIntervalSince1970: $0) }
        let modelObject = object["model"] as? [String: Any]
        let model = (modelObject?["display_name"] as? String)
            ?? (modelObject?["id"] as? String)
            ?? "Claude"
        let cwd = (object["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        let version = object["version"] as? String
        let detail: String
        if limits.isEmpty {
            detail = language.text(
                "尚未收到额度字段 · 仅 Pro/Max 首次响应后提供",
                "No quota fields yet · available to Pro/Max after the first response"
            )
        } else {
            detail = [model, version, cwd].compactMap { $0 }.joined(separator: " · ")
        }

        return ProviderSnapshot(
            id: .claude,
            activity: isRunning ? claudeActivity() : .idle,
            limits: limits,
            detail: detail,
            source: language.text("Claude 官方 status line", "Official Claude status line"),
            lastUpdated: capturedAt ?? modificationDate(cache),
            setupAvailable: false,
            isInstalled: true
        )
    }

    static func claudeDesktopUsage(_ data: Data) -> ClaudeDesktopUsage? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let samples = object["samples"] as? [[String: Any]],
            let latest = samples.max(by: {
                (number($0["t"]) ?? 0) < (number($1["t"]) ?? 0)
            }),
            let timestamp = number(latest["t"]),
            let usage = latest["u"] as? [String: Any]
        else {
            return nil
        }

        let org = latest["org"] as? String
        let capturedAt = Date(timeIntervalSince1970: timestamp / 1_000)
        var limits: [LimitWindow] = []
        if let used = number(usage["fh"]) {
            limits.append(LimitWindow(
                id: "desktop-five-hour",
                label: "5 小时",
                remainingPercent: 100 - used,
                resetAt: inferredDesktopReset(
                    samples: samples,
                    org: org,
                    usageKey: "fh",
                    window: 5 * 3_600
                ),
                windowMinutes: 300
            ))
        }
        if let used = number(usage["sd"]) {
            limits.append(LimitWindow(
                id: "desktop-seven-day",
                label: "7 天",
                remainingPercent: 100 - used,
                resetAt: inferredDesktopReset(
                    samples: samples,
                    org: org,
                    usageKey: "sd",
                    window: 7 * 86_400
                ),
                windowMinutes: 10_080
            ))
        }
        guard !limits.isEmpty else { return nil }
        return ClaudeDesktopUsage(limits: limits, capturedAt: capturedAt)
    }

    private static func claudeLimits(_ object: [String: Any]) -> [LimitWindow] {
        guard let rateLimits = object["rate_limits"] as? [String: Any] else {
            return []
        }
        var limits: [LimitWindow] = []
        if let fiveHour = rateLimits["five_hour"] as? [String: Any] {
            limits.append(
                makeClaudeWindow(fiveHour, id: "five-hour", label: "5 小时", minutes: 300)
            )
        }
        if let sevenDay = rateLimits["seven_day"] as? [String: Any] {
            limits.append(
                makeClaudeWindow(sevenDay, id: "seven-day", label: "7 天", minutes: 10_080)
            )
        }
        return limits
    }

    private static func inferredDesktopReset(
        samples: [[String: Any]],
        org: String?,
        usageKey: String,
        window: TimeInterval
    ) -> Date? {
        let matching = samples.compactMap { sample -> (Date, Double)? in
            guard
                (sample["org"] as? String) == org,
                let timestamp = number(sample["t"]),
                let usage = sample["u"] as? [String: Any],
                let value = number(usage[usageKey])
            else {
                return nil
            }
            return (Date(timeIntervalSince1970: timestamp / 1_000), value)
        }.sorted { $0.0 < $1.0 }
        guard matching.count >= 2 else { return nil }

        for index in stride(from: matching.count - 1, through: 1, by: -1) {
            let previous = matching[index - 1]
            let current = matching[index]
            if current.1 + 1 < previous.1
                || (previous.1 == 0 && current.1 > 0) {
                let reset = current.0.addingTimeInterval(window)
                return reset > Date() ? reset : nil
            }
        }
        return nil
    }

    private static func normalizedWindow(_ label: String) -> String {
        let lower = label.lowercased()
        if lower.contains("5") && (lower.contains("小时") || lower.contains("hour")) {
            return "five-hour"
        }
        if lower.contains("7") && (lower.contains("天") || lower.contains("day")) {
            return "seven-day"
        }
        return lower
    }

    private static func collectKimi(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let root = home.appending(path: ".kimi-code/sessions")
        // CLI 未装但凭证文件存在时同样视为已安装：
        // KimiUsageClient 只需要 ~/.kimi-code/credentials/kimi-code.json 即可拉取官方额度。
        let installed = fm.fileExists(atPath: home.appending(path: ".kimi-code/bin/kimi").path)
            || fm.fileExists(atPath: home.appending(path: ".kimi-code/credentials/kimi-code.json").path)
            || fm.fileExists(atPath: home.appending(path: ".kimi/credentials/kimi-code.json").path)
        let isRunning = containsStandaloneProcess("kimi", in: processText)
        let latestWire = latestFile(in: root, named: "wire.jsonl", suffix: nil)
        var detail = installed
            ? language.text("等待额度同步", "Waiting for quota sync")
            : language.text("未发现 Kimi Code", "Kimi Code not found")
        var modified: Date?
        var activity: ActivityState = isRunning ? .idle : (installed ? .idle : .offline)

        if let latestWire {
            modified = modificationDate(latestWire)
            let lines = tailLines(of: latestWire, maxBytes: 1_500_000)
            activity = kimiActivity(lines: lines, isRunning: isRunning, modified: modified)
            for line in lines.reversed() {
                guard
                    let data = line.data(using: .utf8),
                    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                if let usage = object["usage"] as? [String: Any] {
                    let input = number(usage["inputOther"]) ?? 0
                    let cache = number(usage["inputCacheRead"]) ?? 0
                    let output = number(usage["output"]) ?? 0
                    let total = Int(input + cache + output)
                    let model = (object["model"] as? String) ?? "Kimi"
                    detail = language.text(
                        "\(model.replacingOccurrences(of: "kimi-code/", with: "")) · 最近一轮 \(compactNumber(total)) tokens",
                        "\(model.replacingOccurrences(of: "kimi-code/", with: "")) · last turn \(compactNumber(total)) tokens"
                    )
                    break
                }
            }
        }

        return ProviderSnapshot(
            id: .kimi,
            activity: activity,
            limits: [],
            detail: detail,
            source: language.text(
                "Kimi 官方 /usages + 本地会话",
                "Official Kimi /usages + local sessions"
            ),
            lastUpdated: modified,
            setupAvailable: false,
            isInstalled: installed
        )
    }

    /// Collects Gemini / Antigravity usage. Supports both Google Antigravity
    /// (desktop app, language server, conversation database and transcripts)
    /// and legacy Gemini CLI logs.
    private static func collectGemini(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let antigravityRoot = home.appending(path: ".gemini/antigravity")
        let antigravityAppInstalled = fm.fileExists(atPath: "/Applications/Antigravity.app")
            || fm.fileExists(atPath: home.appending(path: "Applications/Antigravity.app").path)
        let antigravityInstalled = antigravityAppInstalled || fm.fileExists(atPath: antigravityRoot.path)
        let geminiCLIInstalled = fm.fileExists(atPath: home.appending(path: ".gemini").path)
        let installed = antigravityInstalled || geminiCLIInstalled

        let isAntigravityRunning = processText.localizedCaseInsensitiveContains("antigravity")
        let isGeminiRunning = containsStandaloneProcess("gemini", in: processText)
        let isRunning = isAntigravityRunning || isGeminiRunning

        guard installed else {
            return ProviderSnapshot(
                id: .gemini,
                activity: .offline,
                limits: [],
                detail: language.text("未发现 Antigravity / Gemini", "Antigravity / Gemini not found"),
                source: language.text("本地 ~/.gemini", "Local ~/.gemini"),
                lastUpdated: nil,
                setupAvailable: false,
                isInstalled: false
            )
        }

        var antigravityWorking = false
        var allDates: [Date] = []

        if antigravityInstalled {
            let info = readAntigravityInfo(root: antigravityRoot)
            antigravityWorking = info.isWorking
            allDates.append(contentsOf: info.timestamps)
        }

        // Also include any legacy Gemini CLI prompts if present
        let cliLogs = geminiPromptTimestamps(root: home.appending(path: ".gemini/tmp"))
        allDates.append(contentsOf: cliLogs)

        // Deduplicate timestamps within 2 seconds
        allDates.sort()
        var deduped: [Date] = []
        for date in allDates {
            if let last = deduped.last, abs(date.timeIntervalSince(last)) < 2 {
                continue
            }
            deduped.append(date)
        }

        let startOfDay = Calendar.current.startOfDay(for: Date())
        let today = deduped.filter { $0 >= startOfDay }.count
        let latest = deduped.max()
        let dailyAllowance = 1_000.0
        let remaining = max(0, min(100, (dailyAllowance - Double(today)) / dailyAllowance * 100))
        let limits = [
            LimitWindow(
                id: "gemini-daily",
                label: language.text("1 天", "1 day"),
                remainingPercent: remaining,
                resetAt: Calendar.current.date(byAdding: .day, value: 1, to: startOfDay),
                windowMinutes: 1_440
            )
        ]

        let recentlyChanged = latest.map { Date().timeIntervalSince($0) < 90 } ?? false
        let activity: ActivityState
        if isRunning {
            if isAntigravityRunning && (antigravityWorking || recentlyChanged) {
                activity = .working
            } else if !isAntigravityRunning && recentlyChanged {
                activity = .working
            } else {
                activity = .idle
            }
        } else {
            activity = .offline
        }

        if antigravityInstalled {
            let cached = AntigravityUsageClient.loadDiskCache(language: language)
            let limits = cached?.limits ?? []
            let detail = cached?.detail ?? language.text("正在同步 Antigravity 额度…", "Syncing Antigravity quota…")
            let source = language.text("Antigravity 实时配额（gRPC）", "Antigravity real-time quota (gRPC)")
            let lastUpdated = cached?.fetchedAt ?? latest

            return ProviderSnapshot(
                id: .gemini,
                activity: activity,
                limits: limits,
                detail: detail,
                source: source,
                lastUpdated: lastUpdated,
                setupAvailable: false,
                isInstalled: true
            )
        }

        let source = language.text("Gemini CLI 本地会话日志（免费层每日 1000 次）", "Local Gemini CLI logs (free tier: 1000 requests/day)")

        return ProviderSnapshot(
            id: .gemini,
            activity: activity,
            limits: limits,
            detail: language.text(
                "今日 \(today)/\(Int(dailyAllowance)) 次请求",
                "\(today)/\(Int(dailyAllowance)) requests today"
            ),
            source: source,
            lastUpdated: latest,
            setupAvailable: false,
            isInstalled: true
        )
    }

    private struct AntigravityInfo {
        var isWorking: Bool
        var timestamps: [Date]
    }

    private static func readAntigravityInfo(root: URL) -> AntigravityInfo {
        var isWorking = false
        var timestamps: [Date] = []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plainIso = ISO8601DateFormatter()

        // 1. Read transcript.jsonl from brain directories
        let brainDir = root.appending(path: "brain")
        if let brainEntries = try? fm.contentsOfDirectory(
            at: brainDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in brainEntries {
                let transcriptURL = entry.appending(path: ".system_generated/logs/transcript.jsonl")
                guard let data = try? Data(contentsOf: transcriptURL),
                      let text = String(data: data, encoding: .utf8) else { continue }
                for line in text.split(separator: "\n") {
                    guard line.contains("\"type\":\"USER_INPUT\"") || line.contains("\"USER_INPUT\"") else { continue }
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          obj["type"] as? String == "USER_INPUT",
                          let dateStr = obj["created_at"] as? String else { continue }
                    if let date = iso.date(from: dateStr) ?? plainIso.date(from: dateStr) {
                        timestamps.append(date)
                    }
                }
            }
        }

        // 2. Read conversation_summaries.db for active status and timestamps
        let dbPath = "file:" + root.appending(path: "conversation_summaries.db").path + "?immutable=1"
        var db: OpaquePointer?
        if sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK {
            var stmt: OpaquePointer?
            let query = "SELECT not_fully_idle, status, last_user_input_time FROM conversation_summaries WHERE last_user_input_time != ''"
            if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let notIdle = sqlite3_column_int(stmt, 0)
                    if let statusStr = sqlite3_column_text(stmt, 1) {
                        let status = String(cString: statusStr)
                        if notIdle == 1 || status == "CASCADE_RUN_STATUS_RUNNING" {
                            isWorking = true
                        }
                    }
                    if let timeStr = sqlite3_column_text(stmt, 2) {
                        let str = String(cString: timeStr).replacingOccurrences(of: " ", with: "T")
                        if let date = iso.date(from: str) ?? plainIso.date(from: str) {
                            timestamps.append(date)
                        }
                    }
                }
                sqlite3_finalize(stmt)
            }
            sqlite3_close(db)
        }

        return AntigravityInfo(isWorking: isWorking, timestamps: timestamps)
    }

    private static func geminiPromptTimestamps(root: URL) -> [Date] {
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()

        var dates: [Date] = []
        for entry in entries {
            let log = entry.appending(path: "logs.json")
            guard
                let size = try? log.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                // Refreshes run as often as every 30s; skip a runaway log rather
                // than re-parsing megabytes of prompts each time.
                size < 8 * 1_024 * 1_024,
                let data = try? Data(contentsOf: log),
                let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else {
                continue
            }
            for row in rows {
                guard let raw = row["timestamp"] as? String else { continue }
                if let date = formatter.date(from: raw) ?? plain.date(from: raw) {
                    dates.append(date)
                }
            }
        }
        return dates
    }

    /// Grok CLI keeps its settings and conversation history under `~/.grok`.
    /// There is no public quota endpoint, so this reports work state and the
    /// configured model rather than inventing a percentage.
    private static func collectGrok(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let root = home.appending(path: ".grok")
        let installed = fm.fileExists(atPath: root.path)
        let isRunning = containsStandaloneProcess("grok", in: processText)
        guard installed else {
            return ProviderSnapshot(
                id: .grok,
                activity: .offline,
                limits: [],
                detail: language.text("未发现 Grok CLI", "Grok CLI not found"),
                source: language.text("本地 ~/.grok", "Local ~/.grok"),
                lastUpdated: nil,
                setupAvailable: false,
                isInstalled: false
            )
        }

        let settings: [String: Any]? = (
            try? Data(contentsOf: root.appending(path: "user-settings.json"))
        )
        .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let model = (settings?["defaultModel"] as? String)
            ?? (settings?["model"] as? String)
            ?? "Grok"
        let latest = latestFile(in: root, named: nil, suffix: nil)
        let modified = latest.flatMap(modificationDate)
        let recentlyChanged = modified.map { Date().timeIntervalSince($0) < 90 } ?? false

        let activity: ActivityState
        if isRunning {
            activity = recentlyChanged ? .working : .idle
        } else {
            activity = .offline
        }

        return ProviderSnapshot(
            id: .grok,
            activity: activity,
            limits: [],
            detail: language.text(
                "\(model) · 额度需在 xAI 控制台查看",
                "\(model) · check quota in the xAI console"
            ),
            source: language.text(
                "Grok CLI 本地状态（xAI 未公开额度接口）",
                "Local Grok CLI state (xAI exposes no quota endpoint)"
            ),
            lastUpdated: modified,
            setupAvailable: false,
            isInstalled: true
        )
    }

    /// GLM Coding Plan：纯远程 provider，无本地工作状态可采；
    /// 有凭证即视为已安装，凭证来源见 GlmCredentialStore。
    private static func collectGlm(language: AppLanguage) -> ProviderSnapshot {
        let keyConfigured = GlmCredentialStore.hasCredential()
        let installed = keyConfigured || fm.fileExists(atPath: home.appending(path: ".zai").path)

        let detail = keyConfigured
            ? language.text("等待同步 GLM Coding Plan 额度", "Waiting to sync GLM Coding Plan quota")
            : language.text(
                "未发现 GLM 凭证（ZAI_CODING_CN_API_KEY）",
                "GLM credential not found (ZAI_CODING_CN_API_KEY)"
            )

        return ProviderSnapshot(
            id: .glm,
            activity: keyConfigured ? .connected : .offline,
            limits: [],
            detail: detail,
            source: language.text("open.bigmodel.cn · 官方额度接口", "open.bigmodel.cn · official quota API"),
            lastUpdated: nil,
            setupAvailable: false,
            isInstalled: installed
        )
    }

    private static func collectDeepSeek(
        processText: String,
        language: AppLanguage
    ) -> ProviderSnapshot {
        let harnessAppInstalled = fm.fileExists(atPath: "/Applications/DeepSeek Harness.app")
            || fm.fileExists(atPath: home.appending(path: "Applications/DeepSeek Harness.app").path)
        let dshConfigInstalled = fm.fileExists(atPath: home.appending(path: ".dsh").path)
            || fm.fileExists(atPath: home.appending(path: "Library/Application Support/@deepseek-ai").path)
        let deepSeekConfigInstalled = fm.fileExists(atPath: home.appending(path: ".deepseek").path)
        let keyConfigured = DeepSeekCredentialStore.hasCredential()
        let installed = harnessAppInstalled || dshConfigInstalled || deepSeekConfigInstalled || keyConfigured

        let isHarnessRunning = processText.localizedCaseInsensitiveContains("DeepSeek Harness")
            || processText.localizedCaseInsensitiveContains("/dsh-desktop")
            || containsStandaloneProcess("dsh", in: processText)
        let isStandaloneRunning = containsStandaloneProcess("deepseek", in: processText)
        let isRunning = isHarnessRunning || isStandaloneRunning

        let sessionsDir = home.appending(path: ".dsh/sessions")
        let latestSession = latestFile(in: sessionsDir, named: nil, suffix: nil)
        let sessionModified = latestSession.flatMap(modificationDate)
        let recentlyActive = sessionModified.map { Date().timeIntervalSince($0) < 90 } ?? false

        let activity: ActivityState
        if isRunning {
            activity = recentlyActive ? .working : .idle
        } else if keyConfigured {
            activity = .connected
        } else {
            activity = .offline
        }

        let detail: String
        if !installed {
            detail = language.text(
                "未发现 DeepSeek Harness 或 API Key",
                "DeepSeek Harness or API key not found"
            )
        } else if isRunning && recentlyActive {
            detail = language.text("DeepSeek Harness 正在执行任务", "DeepSeek Harness working on tasks")
        } else if isRunning {
            detail = language.text("DeepSeek Harness 运行中", "DeepSeek Harness running")
        } else if keyConfigured {
            detail = language.text("等待同步账户余额", "Waiting to sync account balance")
        } else {
            detail = language.text(
                "在模型管理中配置 API Key",
                "Configure an API key in Model management"
            )
        }

        let source: String
        if let info = DeepSeekCredentialStore.loadCredentialInfo() {
            switch info.source {
            case .harness:
                source = language.text(
                    "DeepSeek Harness · 官方账户余额",
                    "DeepSeek Harness · official balance"
                )
            case .environment:
                source = language.text(
                    "环境变量 DEEPSEEK_API_KEY · DeepSeek 官方账户余额",
                    "DEEPSEEK_API_KEY env · official DeepSeek balance"
                )
            case .keychain:
                source = language.text(
                    "macOS 钥匙串 · DeepSeek 官方账户余额",
                    "macOS Keychain · official DeepSeek balance"
                )
            case .config:
                source = language.text(
                    "本地配置 · DeepSeek 官方账户余额",
                    "Local config · official DeepSeek balance"
                )
            }
        } else if harnessAppInstalled || dshConfigInstalled {
            source = language.text("DeepSeek Harness 本地状态", "Local DeepSeek Harness state")
        } else {
            source = language.text("DeepSeek 官方账户余额接口", "Official DeepSeek account balance endpoint")
        }

        return ProviderSnapshot(
            id: .deepseek,
            activity: activity,
            limits: [],
            detail: detail,
            source: source,
            lastUpdated: sessionModified,
            setupAvailable: !keyConfigured,
            isInstalled: installed
        )
    }

    /// Devin：纯远程 provider，无本地会话态可解析；
    /// 凭据文件存在即视为已安装，额度由 DevinUsageClient 远程拉取。
    private static func collectDevin(language: AppLanguage) -> ProviderSnapshot {
        let installed = fm.fileExists(
            atPath: home.appending(path: ".local/share/devin/credentials.toml").path
        )

        return ProviderSnapshot(
            id: .devin,
            activity: installed ? .idle : .offline,
            limits: [],
            detail: installed
                ? language.text("等待同步 Devin 额度", "Waiting to sync Devin quota")
                : language.text("未发现 Devin CLI", "Devin CLI not found"),
            source: language.text(
                "Devin 账号额度（GetUserStatus）",
                "Devin account quota (GetUserStatus)"
            ),
            lastUpdated: nil,
            setupAvailable: false,
            isInstalled: installed
        )
    }

    private static func makePercentWindow(
        _ object: [String: Any],
        fallbackID: String
    ) -> LimitWindow {
        let minutes = Int(number(object["window_minutes"]) ?? 0)
        let used = number(object["used_percent"]) ?? 0
        let reset = number(object["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        return LimitWindow(
            id: "\(fallbackID)-\(minutes)",
            label: windowLabel(minutes: minutes),
            remainingPercent: 100 - used,
            resetAt: reset,
            windowMinutes: minutes > 0 ? minutes : nil
        )
    }

    private static func makeClaudeWindow(
        _ object: [String: Any],
        id: String,
        label: String,
        minutes: Int
    ) -> LimitWindow {
        let used = number(object["used_percentage"]) ?? 0
        let reset = flexibleDate(object["resets_at"])
        return LimitWindow(
            id: id,
            label: label,
            remainingPercent: 100 - used,
            resetAt: reset,
            windowMinutes: minutes
        )
    }

    static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func flexibleDate(_ value: Any?) -> Date? {
        if let epoch = number(value), epoch > 0 {
            let seconds = epoch > 10_000_000_000 ? epoch / 1_000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }
        guard let string = value as? String else { return nil }
        if let date = ISO8601DateFormatter().date(from: string) {
            return date
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    static func windowLabel(minutes: Int) -> String {
        switch minutes {
        case 300: "5 小时"
        case 1_440: "1 天"
        case 10_080: "7 天"
        case let value where value > 0 && value % 1_440 == 0: "\(value / 1_440) 天"
        case let value where value > 0 && value % 60 == 0: "\(value / 60) 小时"
        case let value where value > 0: "\(value) 分钟"
        default: "额度"
        }
    }

    static func compactNumber(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            String(format: "%.1fM", Double(value) / 1_000_000)
        case 1_000...:
            String(format: "%.1fK", Double(value) / 1_000)
        default:
            "\(value)"
        }
    }

    private static func processList() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,etime=,args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drain stdout before waiting so a long process list cannot fill the
            // pipe buffer and deadlock the background refresh.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }

    private static func containsStandaloneProcess(_ name: String, in list: String) -> Bool {
        list.split(separator: "\n").contains { line in
            let lower = line.lowercased()
            guard !lower.contains("quotabar") else { return false }
            return lower.contains("/\(name) ")
                || lower.hasSuffix("/\(name)")
                || lower.contains(" \(name) ")
        }
    }

    private static func codexActivity(
        rootType: String?,
        payload: [String: Any]
    ) -> ActivityState? {
        let payloadType = (payload["type"] as? String ?? "").lowercased()
        let name = (payload["name"] as? String ?? "").lowercased()
        if name.contains("request_user_input")
            || name.contains("ask_user")
            || payloadType.contains("approval_request")
        {
            return .waitingApproval
        }
        if rootType == "response_item", payloadType == "reasoning" {
            return .thinking
        }
        switch payloadType {
        case "task_complete":
            return .idle
        case "agent_reasoning":
            return .thinking
        case "task_started", "agent_message", "mcp_tool_call_begin", "web_search_begin":
            return .working
        default:
            if rootType == "response_item",
               payloadType == "function_call" || payloadType == "custom_tool_call" {
                return .working
            }
            return nil
        }
    }

    private static func claudeActivity() -> ActivityState {
        let url = home.appending(path: ".quotabar/claude-activity.json")
        guard
            let data = try? Data(contentsOf: url),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let captured = number(object["captured_at"]),
            Date().timeIntervalSince1970 - captured < 900,
            let raw = object["state"] as? String,
            let state = ActivityState(rawValue: raw)
        else {
            return .idle
        }
        return state
    }

    private static func claudeCommandLinkIsBroken() -> Bool {
        let command = home.appending(path: ".local/bin/claude")
        guard
            let attributes = try? fm.attributesOfItem(atPath: command.path),
            attributes[.type] as? FileAttributeType == .typeSymbolicLink
        else {
            return false
        }
        return !fm.fileExists(atPath: command.path)
    }

    private static func kimiActivity(
        lines: [String],
        isRunning: Bool,
        modified: Date?
    ) -> ActivityState {
        guard isRunning else { return .idle }
        for line in lines.reversed() {
            guard
                let data = line.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                continue
            }
            let type = object["type"] as? String ?? ""
            let event = object["event"] as? [String: Any]
            let eventType = event?["type"] as? String ?? ""
            let eventName = event?["name"] as? String ?? ""
            if eventType == "tool.call",
               eventName == "AskUserQuestion" || eventName == "ExitPlanMode" {
                return .waitingApproval
            }
            if type == "llm.request" || eventType == "step.begin" {
                return .working
            }
            if eventType == "step.end"
                || type == "turn.steer"
                || type == "context.append_message" {
                break
            }
        }
        let recentlyChanged = modified.map { Date().timeIntervalSince($0) < 60 } ?? false
        return recentlyChanged ? .working : .idle
    }

    private static func liveCodexManagedTaskCount() -> Int {
        let url = home.appending(path: ".codex/process_manager/chat_processes.json")
        guard
            let data = try? Data(contentsOf: url),
            let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            return 0
        }
        return items.reduce(into: 0) { count, item in
            guard let pidValue = number(item["osPid"]) else { return }
            if Darwin.kill(pid_t(pidValue), 0) == 0 {
                count += 1
            }
        }
    }

    private static func latestFile(
        in root: URL,
        named: String?,
        suffix: String?
    ) -> URL? {
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        var result: (url: URL, date: Date)?
        for case let url as URL in enumerator {
            if let named, url.lastPathComponent != named { continue }
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { continue }
            guard
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                values.isRegularFile == true,
                let date = values.contentModificationDate
            else {
                continue
            }
            if result == nil || date > result!.date {
                result = (url, date)
            }
        }
        return result?.url
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private static func tailLines(of url: URL, maxBytes: UInt64) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let length = (try? handle.seekToEnd()) ?? 0
        let offset = length > maxBytes ? length - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        guard var text = String(data: data, encoding: .utf8) else { return [] }
        if offset > 0, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }
}
