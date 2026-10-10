import Foundation

/// Claude 订阅点火器。用清洗过环境变量的 claude -p 发一个最小请求，
/// 让 5 小时窗口在重置后立刻重新开始计时；OAuth 细节全部交给 claude CLI。
/// 没有公开的用量 API，被限流时 CLI 输出自带重置时间，直接解析复用。
enum ClaudeArmer {
    enum Outcome: Sendable, Equatable {
        /// 点火成功：新窗口已开启（或已有活跃窗口，请求被正常并入）。
        case armed
        /// 账号当前被限流；附带解析出的重置时间（可能解析失败为 nil）。
        case blocked(resetAt: Date?)
        /// 需要人工处理（未登录、指向第三方端点等），message 已面向用户。
        case failed(String)
    }

    /// Claude 用量窗口固定 5 小时。
    static let windowLength: TimeInterval = 5 * 3_600

    /// 点火子进程的超时；首次调用可能要冷启动，给足余量。
    private static let timeout: TimeInterval = 150

    private static let pathMemo = PathMemo()

    private final class PathMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?

        func cached() -> String? { lock.withLock { value } }
        func store(_ newValue: String?) { lock.withLock { value = newValue } }
    }

    /// cc-switch 等工具会把 ANTHROPIC_BASE_URL 写进 ~/.claude/settings.json 的
    /// env 段。此时点火会打到第三方后端（既点不着 Claude，还可能消耗别家额度），
    /// 直接拒绝并提示用户。
    static func officialEndpointConfigured() -> Bool {
        var base: String?
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appending(path: ".claude/settings.json")
        if
            let data = try? Data(contentsOf: settingsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let env = object["env"] as? [String: Any],
            let value = env["ANTHROPIC_BASE_URL"] as? String,
            !value.isEmpty
        {
            base = value
        }
        if base == nil {
            base = ProcessInfo.processInfo.environment["ANTHROPIC_BASE_URL"]
        }
        guard let base, !base.isEmpty else { return true }
        return base.hasPrefix("https://api.anthropic.com")
    }

    /// 定位 claude CLI。GUI 应用的 PATH 里通常没有 Homebrew，先查常见位置，
    /// 再退回登录 shell 查询一次并缓存。
    static func locateClaude() async -> String? {
        if let cached = pathMemo.cached() { return cached }
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        where fm.isExecutableFile(atPath: path) {
            pathMemo.store(path)
            return path
        }
        // zsh -lc 只传不可变参数，shell 进程本身在 detached task 里同步跑完。
        let discovered = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v claude"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else {
                return nil
            }
            return path
        }.value
        pathMemo.store(discovered)
        return discovered
    }

    /// 执行点火。结果分类与时间解析都是纯函数（classify / parseResets），
    /// 便于单元测试覆盖。
    static func arm(model: String) async -> Outcome {
        guard officialEndpointConfigured() else {
            return .failed(
                "Claude Code 当前指向第三方端点（ANTHROPIC_BASE_URL），已跳过点火"
            )
        }
        guard let executable = await locateClaude() else {
            return .failed("找不到 claude CLI，请先安装并登录 Claude Code")
        }

        // 清洗环境：防止进程环境里的第三方 BASE_URL/AUTH_TOKEN 把请求带偏。
        var environment = ProcessInfo.processInfo.environment
        for key in environment.keys where key.hasPrefix("ANTHROPIC_") {
            environment.removeValue(forKey: key)
        }
        environment["NO_COLOR"] = "1"

        let output = await run(
            executable: executable,
            arguments: [
                "-p", "hi",
                "--model", model.isEmpty ? "haiku" : model,
                "--max-turns", "1"
            ],
            environment: environment,
            timeout: timeout
        )
        return classify(
            output: output.text,
            terminationStatus: output.terminationStatus
        )
    }

    // MARK: - 纯逻辑（单元测试覆盖）

    /// 依据 CLI 输出分类。实测被限流输出形如：
    /// "You've hit your session limit · resets 7:40pm (Asia/Singapore)"。
    static func classify(output: String, terminationStatus: Int32) -> Outcome {
        let lowered = output.lowercased()
        let limitMarkers = [
            "session limit",
            "session cap",
            "usage limit",
            "weekly limit"
        ]
        if limitMarkers.contains(where: lowered.contains) {
            let resetAt = parseResets(output)
            return .blocked(resetAt: resetAt)
        }
        let authMarkers = [
            "please run /login",
            "invalid api key",
            "not logged in",
            "authentication error",
            "unauthorized",
            "no valid credentials"
        ]
        if authMarkers.contains(where: lowered.contains) {
            return .failed("Claude Code 未登录或凭据无效，请先 claude login")
        }
        guard terminationStatus == 0 else {
            let tail = output
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .suffix(120)
            return .failed("claude CLI 退出码 \(terminationStatus)：\(tail)")
        }
        return .armed
    }

    /// 解析 "resets 7:40pm (Asia/Singapore)" / "resets Monday 7:40am" 之类的
    /// 重置时间。CLI 以本机时区格式化，因此去掉时区括号后按本地时间解析；
    /// 解析失败返回 nil，调用方按固定间隔兜底重试。
    static func parseResets(_ output: String, now: Date = Date()) -> Date? {
        guard
            let range = output.range(
                of: #"resets\s+([^\r\n]+)"#,
                options: .regularExpression
            )
        else { return nil }
        var text = String(output[range])
            .dropFirst("resets".count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // 去掉结尾的时区括号。
        if let paren = text.range(
            of: #"\s*\([^)]*\)$"#,
            options: .regularExpression
        ) {
            text = String(text[..<paren.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 摘出星期几（周窗口会带 "Monday" 之类前缀）。
        let weekdays = [
            "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4,
            "thursday": 5, "friday": 6, "saturday": 7
        ]
        var targetWeekday: Int?
        for (name, number) in weekdays {
            if let range = text.range(of: name, options: [.caseInsensitive]) {
                targetWeekday = number
                // 保留星期词之后的钟点部分（"Monday 7:40am" → "7:40am"）。
                text = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        // 丢掉可能存在的日期前缀（如 "March 3"），只解析钟点。
        let clockPattern = #"(\d{1,2}):(\d{2})\s*(am|pm)?"#
        guard
            let clock = text.range(of: clockPattern, options: .regularExpression),
            let match = captureGroups(in: text[clock], pattern: clockPattern),
            match.count >= 2,
            let hour = Int(match[0]),
            let minute = Int(match[1])
        else { return nil }
        // 可选的 am/pm 组未参与匹配时不会出现在结果数组里。
        let ampm = match.count > 2 ? match[2].lowercased() : ""

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        var components = calendar.dateComponents(
            [.year, .month, .day, .weekday],
            from: now
        )
        components.hour = hour
        components.minute = minute
        // 12 小时制换算；无 am/pm 后缀按 24 小时制处理。
        if ampm == "pm", hour < 12 { components.hour = hour + 12 }
        if ampm == "am", hour == 12 { components.hour = 0 }
        guard var date = calendar.date(from: components) else { return nil }

        if let targetWeekday {
            // 周窗口：推进到下一个匹配的星期几（含今天）。
            while calendar.component(.weekday, from: date) != targetWeekday
                || date.timeIntervalSince(now) < -120 {
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                    return nil
                }
                date = next
                if date.timeIntervalSince(now) > 8 * 86_400 { return nil }
            }
        } else if date.timeIntervalSince(now) < -120 {
            // 钟点已过（如现在 20:00 解析到 7:40pm）→ 视为明天。
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else {
                return nil
            }
            date = next
        }
        return date
    }

    /// 从正则匹配文本里取捕获组。
    private static func captureGroups(in text: Substring, pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let source = String(text)
        let nsRange = NSRange(location: 0, length: source.utf16.count)
        guard
            let match = regex.firstMatch(in: source, range: nsRange),
            match.numberOfRanges > 1
        else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: source) else {
                return nil
            }
            return String(source[range])
        }
    }

    // MARK: - 进程执行

    private struct RunResult: Sendable {
        var text: String
        var terminationStatus: Int32
    }

    /// 在独立 utility 线程同步跑子进程：进程对象不跨并发域，规避 Swift 6
    /// 对非 Sendable 类型逃逸闭包捕获的检查；退出后一次性读完输出
    /// （claude -p 输出远小于管道缓冲，先等退出再读不会死锁）。
    private static func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval
    ) async -> RunResult {
        await Task.detached(priority: .utility) { () -> RunResult in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
            } catch {
                return RunResult(
                    text: "failed to launch claude CLI: \(error.localizedDescription)",
                    terminationStatus: -1
                )
            }

            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning, Date() < deadline {
                // 异步上下文禁用 Thread.sleep；轮询间隔同样用 Task.sleep。
                try? await Task.sleep(for: .milliseconds(200))
            }
            if process.isRunning {
                process.terminate()
                try? await Task.sleep(for: .seconds(1))
            }
            guard !process.isRunning else {
                return RunResult(
                    text: "claude CLI timed out after \(Int(timeout))s",
                    terminationStatus: -1
                )
            }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8) ?? ""
            return RunResult(
                text: text,
                terminationStatus: process.terminationStatus
            )
        }.value
    }
}
