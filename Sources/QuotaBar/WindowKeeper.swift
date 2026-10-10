import Foundation
import UserNotifications

/// 可参与窗口接力的供应商。
enum KeeperProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case glm
    case kimi
    case claude

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glm: "GLM"
        case .kimi: "Kimi"
        case .claude: "Claude"
        }
    }

    /// 点火默认模型：选各家最便宜/最快的档位，16 个 token 足以开启窗口。
    var defaultModel: String {
        switch self {
        case .glm: "glm-4.5-air"
        case .kimi: "kimi-k2-turbo-preview"
        case .claude: "haiku"
        }
    }

    init?(_ provider: ProviderID) {
        switch provider {
        case .glm: self = .glm
        case .kimi: self = .kimi
        case .claude: self = .claude
        default: return nil
        }
    }

    var providerID: ProviderID {
        switch self {
        case .glm: .glm
        case .kimi: .kimi
        case .claude: .claude
        }
    }
}

/// 服务端观测到的 5 小时窗口状态。
enum ServerWindow: Equatable, Sendable {
    /// 有活跃窗口，将于 resetAt 重置。
    case active(resetAt: Date)
    /// 观测确认当前无活跃窗口（重置已过且无人再调用）——点火时机。
    case noActiveWindow
    /// 本次没有可靠观测（接口失败 / 无 API）。
    case unknown
}

/// 每供应商的接力状态，持久化到 UserDefaults。
struct KeeperProviderState: Codable, Equatable, Sendable {
    /// 最近一次点火成功的时刻。
    var lastArmAt: Date?
    /// 最近一次点火尝试（含失败）——保险丝用。
    var lastAttemptAt: Date?
    /// 当前认定的窗口重置锚点（服务端权威值或 Claude 自持网格）。
    var lastKnownResetAt: Date?
    /// 计划中的下次点火时刻（重启后恢复定时用）。
    var nextArmAt: Date?
    var lastError: String?
    var armCount: Int = 0
    /// 本轮连续失败次数（成功即清零），决定退避间隔。
    var consecutiveFailures: Int = 0
}

/// 纯决策逻辑：给定状态与观测，决定下一步动作。独立于 IO，便于单元测试。
enum KeeperPlanner {
    /// 重置时刻之后等多久点火：避开重置瞬间的服务端抖动。
    static let armDelayAfterReset: TimeInterval = 10
    /// 保险丝：任意两次点火尝试的最小间隔，状态机异常也不至于刷请求。
    static let fuseInterval: TimeInterval = 600
    /// 被限流（Claude）后，在解析出的重置时刻上再加的余量。
    static let blockedRetryDelay: TimeInterval = 45
    /// 观测不可用时的兜底重试间隔。
    static let unknownFallbackDelay: TimeInterval = 1_800
    /// 点火失败后的退避序列。
    static let retryDelays: [TimeInterval] = [30, 120, 600, 600, 600]

    enum Action: Equatable, Sendable {
        case none
        case armNow
        case wait(Date)
    }

    struct Decision: Equatable, Sendable {
        var action: Action
        /// 非空表示应把窗口锚点更新为该值；nil 表示维持原锚点。
        var resetAt: Date?
    }

    static func plan(
        state: KeeperProviderState,
        window: ServerWindow,
        now: Date
    ) -> Decision {
        switch window {
        case .active(let resetAt):
            guard resetAt > now else {
                return plan(state: state, window: .noActiveWindow, now: now)
            }
            return Decision(
                action: .wait(resetAt.addingTimeInterval(armDelayAfterReset)),
                resetAt: resetAt
            )
        case .noActiveWindow:
            if
                let lastAttempt = state.lastAttemptAt,
                now.timeIntervalSince(lastAttempt) < fuseInterval
            {
                return Decision(
                    action: .wait(lastAttempt.addingTimeInterval(fuseInterval)),
                    resetAt: nil
                )
            }
            return Decision(action: .armNow, resetAt: nil)
        case .unknown:
            if let anchor = state.lastKnownResetAt {
                if anchor > now {
                    return Decision(
                        action: .wait(anchor.addingTimeInterval(armDelayAfterReset)),
                        resetAt: nil
                    )
                }
                // 锚点已过且无观测：按无活跃窗口处理（保险丝仍然生效）。
                return plan(state: state, window: .noActiveWindow, now: now)
            }
            // 从未建立锚点：点一次把网格立起来。
            return plan(state: state, window: .noActiveWindow, now: now)
        }
    }

    static func retryDelay(failures: Int) -> TimeInterval {
        guard failures > 0, !retryDelays.isEmpty else { return unknownFallbackDelay }
        let index = min(failures - 1, retryDelays.count - 1)
        return retryDelays[index]
    }

    /// 从任意一家返回的 LimitWindow 集合里挑出 5 小时窗口。
    static func fiveHourWindow(_ limits: [LimitWindow]) -> LimitWindow? {
        limits.first { $0.effectiveMinutes == 300 }
            ?? limits.first { $0.id == "limit-5h" || $0.id == "glm-5h" }
    }
}

/// 接力失败通知（成功不通知：每 5 小时一条没人受得了）。
enum KeeperNotifier {
    static func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    static func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// 窗口接力引擎：每个 5 小时窗口到点重置后，立刻发一个最小请求把新窗口
/// 点着（策略 A：永续网格）。锚点永远以服务端权威重置时间为准，本地只做
/// 调度；Claude 无用量 API，以点火 CLI 输出 + 自持网格代替。
@MainActor
final class WindowKeeper: ObservableObject {
    struct Config: Equatable, Sendable {
        var enabled = false
        var providers: Set<KeeperProvider> = []
        var models: [KeeperProvider: String] = [:]
        var notifyOnFailure = true
    }

    struct KeeperNote: Equatable, Sendable {
        var text: String
        var isError: Bool
    }

    @Published private(set) var states: [KeeperProvider: KeeperProviderState] = [:]
    @Published private(set) var isArming: Set<KeeperProvider> = []

    var config = Config() {
        didSet { configDidChange() }
    }

    private let glmClient: GlmUsageClient
    private let kimiClient: KimiUsageClient
    private let defaults: UserDefaults
    private var timers: [KeeperProvider: Task<Void, Never>] = [:]
    private var scheduledAt: [KeeperProvider: Date] = [:]
    private var notifiedFailures: Set<KeeperProvider> = []
    private static let storageKey = "windowKeeper.states.v1"

    init(
        glmClient: GlmUsageClient,
        kimiClient: KimiUsageClient,
        defaults: UserDefaults = .standard
    ) {
        self.glmClient = glmClient
        self.kimiClient = kimiClient
        self.defaults = defaults
        if
            let data = defaults.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode(
                [KeeperProvider: KeeperProviderState].self,
                from: data
            )
        {
            states = saved
        }
    }

    // MARK: - 对外入口

    /// AppModel 每轮刷新后喂入快照，用服务端数据校准锚点与定时。
    func ingest(snapshots: [ProviderSnapshot]) {
        guard config.enabled else { return }
        for snapshot in snapshots {
            guard let provider = KeeperProvider(snapshot.id) else { continue }
            guard isEnabled(provider) else { continue }
            guard let window = KeeperPlanner.fiveHourWindow(snapshot.limits) else {
                if provider != .claude, !snapshot.limits.isEmpty {
                    reconcile(provider, window: .noActiveWindow)
                }
                continue
            }
            guard let resetAt = window.resetAt else { continue }
            if resetAt > Date() {
                reconcile(provider, window: .active(resetAt: resetAt))
            } else if provider != .claude {
                reconcile(provider, window: .noActiveWindow)
            }
        }
    }

    /// 唤醒（含正常刷新路径）时校准：错过的点火立即补上。
    func handleWake() {
        for provider in KeeperProvider.allCases where isEnabled(provider) {
            if let scheduled = scheduledAt[provider], scheduled > Date() { continue }
            schedule(provider, at: Date().addingTimeInterval(3))
        }
    }

    /// 设置面板「立即点火」按钮：绕过等待计划（人工意图优先），仍记录尝试时刻。
    func manualArm(_ provider: KeeperProvider) async {
        guard isEnabled(provider) else { return }
        timers[provider]?.cancel()
        timers[provider] = nil
        await performArm(provider, bypassFuse: true)
    }

    /// 面板脚注文本（静态时刻，避免每秒刷新抖动）。
    func notes(language: AppLanguage) -> [ProviderID: KeeperNote] {
        var result: [ProviderID: KeeperNote] = [:]
        guard config.enabled else { return result }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: language == .chinese ? "zh_CN" : "en_US")
        formatter.dateFormat = language == .chinese ? "HH:mm" : "h:mm a"
        for provider in KeeperProvider.allCases where isEnabled(provider) {
            let state = states[provider] ?? KeeperProviderState()
            let target = scheduledAt[provider] ?? state.nextArmAt
            if let error = state.lastError {
                let trimmed = String(error.prefix(36))
                result[provider.providerID] = KeeperNote(
                    text: language.text(
                        "接力异常：\(trimmed)",
                        "Re-arm error: \(trimmed)"
                    ),
                    isError: true
                )
            } else if let target {
                let clock = formatter.string(from: target)
                result[provider.providerID] = KeeperNote(
                    text: language.text(
                        "接力 · \(clock) 点火",
                        "Re-arms at \(clock)"
                    ),
                    isError: false
                )
            } else {
                result[provider.providerID] = KeeperNote(
                    text: language.text("接力待命", "Re-arm standing by"),
                    isError: false
                )
            }
        }
        return result
    }

    // MARK: - 内部实现

    private func isEnabled(_ provider: KeeperProvider) -> Bool {
        config.enabled && config.providers.contains(provider)
    }

    private func configDidChange() {
        notifiedFailures.removeAll()
        guard config.enabled else {
            for (provider, task) in timers {
                task.cancel()
                timers[provider] = nil
            }
            scheduledAt.removeAll()
            return
        }
        for provider in KeeperProvider.allCases where isEnabled(provider) {
            reconcile(provider, window: .unknown)
        }
    }

    private func reconcile(_ provider: KeeperProvider, window: ServerWindow) {
        guard isEnabled(provider) else { return }
        let state = states[provider] ?? KeeperProviderState()
        let decision = KeeperPlanner.plan(state: state, window: window, now: Date())
        if let resetAt = decision.resetAt {
            updateState(provider) { $0.lastKnownResetAt = resetAt }
        }
        switch decision.action {
        case .none:
            break
        case .armNow:
            // 已有临近的定时器就不重复安排。
            if
                let scheduled = scheduledAt[provider],
                scheduled <= Date().addingTimeInterval(60)
            { return }
            if isArming.contains(provider) { return }
            schedule(provider, at: Date().addingTimeInterval(2))
        case .wait(let date):
            if isArming.contains(provider) { return }
            if
                let scheduled = scheduledAt[provider],
                abs(scheduled.timeIntervalSince(date)) < 60
            { return }
            schedule(provider, at: date)
        }
    }

    /// 定时器到点：先核对服务端状态再决定是否真的发请求。
    private func fire(_ provider: KeeperProvider) async {
        timers[provider] = nil
        scheduledAt[provider] = nil
        guard isEnabled(provider) else { return }
        switch provider {
        case .glm, .kimi:
            let window = await fetchWindow(provider)
            let state = states[provider] ?? KeeperProviderState()
            let decision = KeeperPlanner.plan(
                state: state,
                window: window,
                now: Date()
            )
            if let resetAt = decision.resetAt {
                updateState(provider) { $0.lastKnownResetAt = resetAt }
            }
            switch decision.action {
            case .none:
                return
            case .wait(let date):
                schedule(provider, at: date)
                return
            case .armNow:
                break
            }
        case .claude:
            break
        }
        await performArm(provider, bypassFuse: false)
    }

    private enum ArmOutcome {
        /// 点火成功；anchor 为新窗口的重置时刻。
        case armed(anchor: Date)
        /// 被限流；at 为解析出的重置时刻。
        case blockedRetry(at: Date)
        case failed(String)
    }

    private func performArm(
        _ provider: KeeperProvider,
        bypassFuse: Bool
    ) async {
        let now = Date()
        let state = states[provider] ?? KeeperProviderState()
        if !bypassFuse {
            // 保险丝：任意两次点火尝试至少间隔 fuseInterval。
            if
                let lastAttempt = state.lastAttemptAt,
                now.timeIntervalSince(lastAttempt) < KeeperPlanner.fuseInterval
            {
                schedule(
                    provider,
                    at: lastAttempt.addingTimeInterval(KeeperPlanner.fuseInterval)
                )
                return
            }
        }
        updateState(provider) { $0.lastAttemptAt = now }
        isArming.insert(provider)
        defer { isArming.remove(provider) }

        let model = config.models[provider] ?? provider.defaultModel
        let outcome: ArmOutcome
        switch provider {
        case .glm:
            do {
                try await glmClient.arm(model: model)
                outcome = await verifyOutcome(provider, armedAt: now)
            } catch {
                outcome = .failed(armErrorMessage(provider, error))
            }
        case .kimi:
            do {
                try await kimiClient.arm(model: model)
                outcome = await verifyOutcome(provider, armedAt: now)
            } catch {
                outcome = .failed(armErrorMessage(provider, error))
            }
        case .claude:
            switch await ClaudeArmer.arm(model: model) {
            case .armed:
                outcome = .armed(
                    anchor: now.addingTimeInterval(ClaudeArmer.windowLength)
                )
            case .blocked(let resetAt):
                // 被限流不是失败：锚到重置时刻，到点再点。
                let anchor = resetAt
                    ?? now.addingTimeInterval(KeeperPlanner.unknownFallbackDelay)
                outcome = .blockedRetry(at: anchor)
            case .failed(let message):
                outcome = .failed(message)
            }
        }

        switch outcome {
        case .armed(let anchor):
            updateState(provider) {
                $0.lastArmAt = now
                $0.lastKnownResetAt = anchor
                $0.lastError = nil
                $0.consecutiveFailures = 0
                $0.armCount += 1
            }
            notifiedFailures.remove(provider)
            schedule(
                provider,
                at: anchor.addingTimeInterval(KeeperPlanner.armDelayAfterReset)
            )
        case .blockedRetry(let resetAt):
            updateState(provider) {
                $0.lastKnownResetAt = resetAt
                $0.lastError = nil
                $0.consecutiveFailures = 0
            }
            notifiedFailures.remove(provider)
            schedule(
                provider,
                at: resetAt.addingTimeInterval(KeeperPlanner.blockedRetryDelay)
            )
        case .failed(let message):
            var failures = state.consecutiveFailures + 1
            if failures > KeeperPlanner.retryDelays.count + 2 {
                // 长期失败时封顶，避免失败计数无限增长。
                failures = KeeperPlanner.retryDelays.count + 2
            }
            updateState(provider) {
                $0.lastError = message
                $0.consecutiveFailures = failures
            }
            if
                config.notifyOnFailure,
                !notifiedFailures.contains(provider),
                failures >= 2
            {
                notifiedFailures.insert(provider)
                KeeperNotifier.post(
                    title: "\(provider.title) 窗口接力失败",
                    body: message
                )
            }
            schedule(
                provider,
                at: now.addingTimeInterval(KeeperPlanner.retryDelay(failures: failures))
            )
        }
    }

    /// GLM/Kimi 点火后回读官方接口，采用服务端权威锚点。
    private func verifyOutcome(
        _ provider: KeeperProvider,
        armedAt: Date
    ) async -> ArmOutcome {
        let window = await fetchWindow(provider)
        if case .active(let resetAt) = window {
            return .armed(anchor: resetAt)
        }
        // 回读失败/仍无窗口：按窗口长度自持锚点，下轮定时再校正。
        return .armed(anchor: armedAt.addingTimeInterval(5 * 3_600))
    }

    private func fetchWindow(_ provider: KeeperProvider) async -> ServerWindow {
        do {
            let limits: [LimitWindow]
            switch provider {
            case .glm:
                limits = try await glmClient.fetchIfNeeded(force: true).limits
            case .kimi:
                limits = try await kimiClient.fetchIfNeeded(
                    force: true,
                    allowRemote: true,
                    kimiIsWorking: false
                ).limits
            case .claude:
                return .unknown
            }
            guard let window = KeeperPlanner.fiveHourWindow(limits) else {
                return .noActiveWindow
            }
            guard let resetAt = window.resetAt else { return .noActiveWindow }
            return resetAt > Date() ? .active(resetAt: resetAt) : .noActiveWindow
        } catch {
            return .unknown
        }
    }

    private func armErrorMessage(
        _ provider: KeeperProvider,
        _ error: Error
    ) -> String {
        let message = error.localizedDescription
        return "\(provider.title) 点火失败：\(message)"
    }

    private func schedule(_ provider: KeeperProvider, at date: Date) {
        timers[provider]?.cancel()
        let interval = max(1, date.timeIntervalSinceNow)
        scheduledAt[provider] = date
        updateState(provider) { $0.nextArmAt = date }
        timers[provider] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.fire(provider)
        }
    }

    private func updateState(
        _ provider: KeeperProvider,
        _ mutate: (inout KeeperProviderState) -> Void
    ) {
        var state = states[provider] ?? KeeperProviderState()
        let original = state
        mutate(&state)
        guard state != original else { return }
        states[provider] = state
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Self.storageKey)
        }
    }
}
