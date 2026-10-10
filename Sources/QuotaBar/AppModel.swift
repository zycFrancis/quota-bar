import AppKit
import Combine
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var snapshots: [ProviderSnapshot] = ProviderID.allCases.map {
        ProviderSnapshot.placeholder($0)
    }
    @Published var isRefreshing = false
    @Published var notice: String?
    @Published var lastRefresh = Date()
    @Published var deepSeekKeyConfigured = DeepSeekCredentialStore.load() != nil
    @Published var updateState: UpdateState = .idle

    let preferences = AppPreferences()
    let hud = HUDBridge()

    private let codexClient = CodexUsageClient()
    private let deepSeekClient = DeepSeekBalanceClient()
    private let kimiClient = KimiUsageClient()
    private let glmClient = GlmUsageClient()
    private let antigravityClient = AntigravityUsageClient()
    private var scheduledRefresh: Task<Void, Never>?
    private var latestRelease: LatestRelease?
    private var keeperCancellable: AnyCancellable?

    /// 窗口接力引擎。lazy：依赖上面的 client 实例。
    lazy var keeper = WindowKeeper(glmClient: glmClient, kimiClient: kimiClient)

    var language: AppLanguage { preferences.language }

    var versionText: String { "v\(AppVersion.short)" }

    var refreshPolicyText: String {
        preferences.refreshMode.label(language: language)
    }

    var visibleSnapshots: [ProviderSnapshot] {
        preferences.visibleProviderOrder.compactMap { provider in
            snapshots.first { $0.id == provider }
        }
    }

    func start() {
        if
            LocalCollectors.claudeCollectorInstalled(),
            LocalCollectors.claudeCollectorNeedsRepair()
        {
            try? ClaudeCollectorInstaller.install()
        }
        applyKeeperConfig()
        forwardKeeperChanges()
        observeWorkspaceWake()
        Task { await refresh(forceRemote: true) }
        // Quiet update check shortly after launch so the settings row and the
        // menu item already know whether a new release exists.
        Task {
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            await checkForUpdate()
        }
    }

    // MARK: - WindowKeeper wiring

    private func applyKeeperConfig() {
        keeper.config = WindowKeeper.Config(
            enabled: preferences.keeperEnabled,
            providers: preferences.keeperProviders,
            models: Dictionary(
                uniqueKeysWithValues: KeeperProvider.allCases.map {
                    ($0, preferences.keeperModel(for: $0))
                }
            ),
            notifyOnFailure: preferences.keeperNotifyOnFailure
        )
    }

    /// 引擎状态变化转发给 AppModel 的订阅者，设置面板才能实时刷新脚注。
    private func forwardKeeperChanges() {
        guard keeperCancellable == nil else { return }
        keeperCancellable = keeper.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    /// 睡眠唤醒后立即检查错过的点火时刻（launchd/系统定时器睡眠中会漂移）。
    private func observeWorkspaceWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.keeper.handleWake()
            }
        }
    }

    /// 设置面板「立即点火」按钮入口。
    func keeperManualArm(_ provider: KeeperProvider) async {
        await keeper.manualArm(provider)
        await refresh(forceRemote: true)
    }

    // MARK: - Updates

    func checkForUpdate() async {
        guard AppUpdater.canSelfUpdate else {
            updateState = .failed(
                language.text(
                    "需要以 App 方式运行才能检查更新",
                    "Updates require running the packaged .app"
                )
            )
            return
        }
        updateState = .checking
        do {
            let release = try await AppUpdater.fetchLatestRelease()
            latestRelease = release
            if AppUpdater.isNewer(release.version, than: AppVersion.short) {
                updateState = .available(release.version)
            } else {
                updateState = .upToDate
            }
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    /// One click: download the latest release, swap the bundle and relaunch.
    func installUpdate() async {
        guard case .available = updateState else { return }
        var release = latestRelease
        if release == nil {
            release = try? await AppUpdater.fetchLatestRelease()
        }
        guard let release else {
            updateState = .failed(
                language.text("找不到可下载的更新", "Could not find a downloadable update")
            )
            return
        }
        latestRelease = release
        updateState = .downloading
        do {
            let staged = try await AppUpdater.downloadAndStage(release)
            updateState = .installing
            try AppUpdater.swapAndRelaunch(stagedAppURL: staged)
            NSApp.terminate(nil)
        } catch {
            updateState = .failed(error.localizedDescription)
        }
    }

    func refresh(
        forceRemote: Bool,
        preserveRemoteDataOnFailure: Bool = false
    ) async {
        guard !isRefreshing else { return }
        scheduledRefresh?.cancel()
        isRefreshing = true
        let currentLanguage = preferences.language
        deepSeekKeyConfigured = DeepSeekCredentialStore.hasCredential()
        let previousSnapshots = snapshots

        let bundle = await Task.detached(priority: .utility) {
            LocalCollectors.collect(language: currentLanguage)
        }.value
        var merged = bundle.all

        for provider in preferences.pausedProviders {
            guard let currentIndex = merged.firstIndex(where: { $0.id == provider }) else {
                continue
            }
            if let previous = previousSnapshots.first(where: { $0.id == provider }) {
                merged[currentIndex].limits = previous.limits
                merged[currentIndex].balances = previous.balances
                merged[currentIndex].lastUpdated = previous.lastUpdated
                merged[currentIndex].source = previous.source
                if provider == .deepseek {
                    merged[currentIndex].activity = previous.activity
                }
            } else {
                merged[currentIndex].activity = .offline
            }
            merged[currentIndex].detail = currentLanguage.text(
                "额度刷新已暂停",
                "Quota refresh paused"
            )
        }

        if
            bundle.codex.isInstalled,
            !preferences.hiddenProviders.contains(.codex),
            !preferences.pausedProviders.contains(.codex)
        {
            do {
                let usage = try await codexClient.fetchIfNeeded(
                    force: forceRemote,
                    language: currentLanguage
                )
                if let index = merged.firstIndex(where: { $0.id == .codex }) {
                    merged[index].limits = usage.limits
                    merged[index].lastUpdated = usage.fetchedAt
                    if !usage.balances.isEmpty {
                        merged[index].balances = usage.balances
                    }
                    if let resetCards = usage.resetCards {
                        merged[index].resetCards = resetCards
                    }
                    if let prediction = await CodexResetMonitorClient.shared.fetchIfNeeded(force: forceRemote) {
                        merged[index].resetPrediction = prediction
                    }
                    merged[index].source = currentLanguage.text(
                        "Codex 账号额度 + 本地任务状态",
                        "Codex account quota + local task status"
                    )
                    if !usage.plan.isEmpty,
                       !merged[index].detail.localizedCaseInsensitiveContains(usage.plan) {
                        merged[index].detail = "\(usage.plan) · \(merged[index].detail)"
                    }
                }
            } catch {
                if let index = merged.firstIndex(where: { $0.id == .codex }) {
                    if
                        preserveRemoteDataOnFailure,
                        let previous = previousSnapshots.first(where: {
                            $0.id == .codex && !$0.limits.isEmpty
                        })
                    {
                        merged[index].limits = previous.limits
                        merged[index].balances = previous.balances
                        merged[index].resetCards = previous.resetCards
                        merged[index].resetPrediction = previous.resetPrediction
                        merged[index].lastUpdated = previous.lastUpdated
                        merged[index].source = previous.source
                    } else {
                        merged[index].source = currentLanguage.text(
                            "Codex 本地快照（账号同步暂不可用）",
                            "Local Codex snapshot (account sync unavailable)"
                        )
                    }
                }
            }
        }

        if
            bundle.glm.isInstalled,
            !preferences.hiddenProviders.contains(.glm),
            !preferences.pausedProviders.contains(.glm)
        {
            do {
                let usage = try await glmClient.fetchIfNeeded(force: forceRemote)
                if let index = merged.firstIndex(where: { $0.id == .glm }) {
                    merged[index].limits = usage.limits
                    merged[index].lastUpdated = usage.fetchedAt
                    if !usage.plan.isEmpty,
                       !merged[index].detail.localizedCaseInsensitiveContains(usage.plan) {
                        merged[index].detail = "\(usage.plan) · \(merged[index].detail)"
                    }
                    if usage.limits.isEmpty {
                        merged[index].detail = currentLanguage.text(
                            "额度服务暂未返回可展示窗口",
                            "The quota service returned no displayable window"
                        )
                    }
                }
            } catch {
                if let index = merged.firstIndex(where: { $0.id == .glm }) {
                    merged[index].activity = .needsAttention
                    merged[index].detail = glmError(error, language: currentLanguage)
                }
            }
        }

        if
            bundle.kimi.isInstalled,
            !preferences.hiddenProviders.contains(.kimi),
            !preferences.pausedProviders.contains(.kimi)
        {
            do {
                let kimiIsWorking = bundle.kimi.activity == .working || bundle.kimi.activity == .thinking
                let usage = try await kimiClient.fetchIfNeeded(
                    force: forceRemote,
                    allowRemote: true,
                    kimiIsWorking: kimiIsWorking
                )
                if let index = merged.firstIndex(where: { $0.id == .kimi }) {
                    merged[index].limits = usage.limits
                    merged[index].lastUpdated = usage.fetchedAt
                    if !usage.balances.isEmpty {
                        merged[index].balances = usage.balances
                    }
                    if !usage.plan.isEmpty,
                       !merged[index].detail.localizedCaseInsensitiveContains(usage.plan) {
                        merged[index].detail = "\(usage.plan) · \(merged[index].detail)"
                    }
                    if usage.limits.isEmpty {
                        merged[index].detail = currentLanguage.text(
                            "额度服务暂未返回可展示窗口",
                            "The quota service returned no displayable window"
                        )
                    }
                }
            } catch {
                if let index = merged.firstIndex(where: { $0.id == .kimi }) {
                    if !bundle.kimi.activity.isActive {
                        merged[index].activity = .needsAttention
                    }
                    merged[index].detail = kimiError(error, language: currentLanguage)
                }
            }
        }

        if
            deepSeekKeyConfigured,
            !preferences.hiddenProviders.contains(.deepseek),
            (!preferences.pausedProviders.contains(.deepseek) || (forceRemote && merged.first(where: { $0.id == .deepseek })?.balances.isEmpty == true))
        {
            do {
                let balance = try await deepSeekClient.fetchIfNeeded(force: forceRemote)
                if let index = merged.firstIndex(where: { $0.id == .deepseek }) {
                    merged[index].balances = balance.balances
                    merged[index].lastUpdated = balance.fetchedAt
                    if !merged[index].activity.isActive {
                        merged[index].activity = balance.isAvailable
                            ? .connected
                            : .needsAttention
                    }
                    let primary = balance.balances.first
                    merged[index].detail = currentLanguage.text(
                        primary.map { "账户余额 \($0.compactText)" }
                            ?? "已同步账户余额",
                        primary.map { "Account balance \($0.compactText)" }
                            ?? "Account balance synced"
                    )
                }
            } catch {
                if let index = merged.firstIndex(where: { $0.id == .deepseek }) {
                    if
                        preserveRemoteDataOnFailure,
                        let previous = previousSnapshots.first(where: {
                            $0.id == .deepseek && !$0.balances.isEmpty
                        })
                    {
                        merged[index].balances = previous.balances
                        merged[index].lastUpdated = previous.lastUpdated
                        merged[index].activity = previous.activity
                        merged[index].detail = currentLanguage.text(
                            "自动刷新暂时失败，保留上次余额",
                            "Automatic refresh failed; showing the last balance"
                        )
                    } else {
                        if !merged[index].activity.isActive {
                            merged[index].activity = .needsAttention
                        }
                        merged[index].detail = deepSeekError(
                            error,
                            language: currentLanguage
                        )
                    }
                }
            }
        }

        if
            bundle.gemini.isInstalled,
            !preferences.hiddenProviders.contains(.gemini),
            !preferences.pausedProviders.contains(.gemini)
        {
            do {
                let usage = try await antigravityClient.fetchIfNeeded(
                    force: forceRemote,
                    language: currentLanguage
                )
                if let index = merged.firstIndex(where: { $0.id == .gemini }) {
                    merged[index].limits = usage.limits
                    merged[index].lastUpdated = usage.fetchedAt
                    merged[index].source = currentLanguage.text(
                        "Antigravity 实时配额（gRPC）",
                        "Antigravity real-time quota (gRPC)"
                    )
                    if let detail = usage.detail, !detail.isEmpty {
                        merged[index].detail = detail
                    }
                    if let act = usage.activity {
                        merged[index].activity = act
                    }
                }
            } catch {
                if let index = merged.firstIndex(where: { $0.id == .gemini }) {
                    if
                        preserveRemoteDataOnFailure,
                        let previous = previousSnapshots.first(where: {
                            $0.id == .gemini && !$0.limits.isEmpty
                        })
                    {
                        merged[index].limits = previous.limits
                        merged[index].lastUpdated = previous.lastUpdated
                        merged[index].source = previous.source
                    }
                }
            }
        }

        keeper.ingest(snapshots: merged)
        let keeperNotes = keeper.notes(language: currentLanguage)
        for index in merged.indices {
            let note = keeperNotes[merged[index].id]
            merged[index].keeperNote = note?.text
            merged[index].keeperNoteHasError = note?.isError ?? false
        }

        snapshots = merged
        lastRefresh = Date()
        isRefreshing = false
        hud.apply(preferences: preferences, snapshots: merged)
        scheduleNextRefresh()
    }

    func preferencesChanged(languageChanged: Bool) {
        hud.apply(preferences: preferences, snapshots: snapshots)
        applyKeeperConfig()
        if preferences.keeperEnabled {
            Task { await KeeperNotifier.requestAuthorization() }
        }
        if languageChanged {
            Task { await refresh(forceRemote: false) }
        } else {
            scheduleNextRefresh()
        }
    }

    /// Any provider running at or below the configured warning threshold.
    var lowQuotaProviders: [ProviderID] {
        guard preferences.lowQuotaThreshold > 0 else { return [] }
        return visibleSnapshots.compactMap { snapshot in
            guard
                let limit = QuotaWindowSelector.primary(
                    in: snapshot.limits,
                    preference: preferences.quotaWindow
                ),
                Int(limit.clampedRemaining.rounded()) <= preferences.lowQuotaThreshold
            else {
                return nil
            }
            return snapshot.id
        }
    }

    func installClaudeCollector() {
        do {
            try ClaudeCollectorInstaller.install()
            notice = language.text(
                "Claude 零额度采集器已配置；重启 Claude Code，首次正常响应后会显示额度、重置时间和审批状态。",
                "Claude zero-token capture is configured. Restart Claude Code; quota, reset times, and approval state appear after its first normal response."
            )
            Task { await refresh(forceRemote: false) }
        } catch {
            notice = error.localizedDescription
        }
    }

    func dismissNotice() {
        notice = nil
    }

    var deepSeekCredentialSource: DeepSeekCredentialSource? {
        DeepSeekCredentialStore.loadCredentialInfo()?.source
    }

    func saveDeepSeekAPIKey(_ key: String) async {
        do {
            let normalized = DeepSeekCredentialStore.normalizedAPIKey(key)
            _ = try await deepSeekClient.validate(apiKey: normalized)
            try DeepSeekCredentialStore.save(normalized)
            deepSeekKeyConfigured = true
            preferences.setProvider(.deepseek, hidden: false)
            preferences.setProvider(.deepseek, paused: false)
            notice = language.text(
                "DeepSeek API Key 验证成功，余额已同步。",
                "DeepSeek API key verified and balance synced."
            )
            await refresh(forceRemote: true)
        } catch {
            notice = deepSeekError(error, language: language)
        }
    }

    func removeDeepSeekAPIKey() async {
        do {
            try DeepSeekCredentialStore.delete()
            deepSeekKeyConfigured = DeepSeekCredentialStore.hasCredential()
            notice = language.text(
                "DeepSeek API Key 已从 macOS 钥匙串移除。",
                "DeepSeek API key was removed from macOS Keychain."
            )
            await refresh(forceRemote: true)
        } catch {
            notice = deepSeekError(error, language: language)
        }
    }

    private func scheduleNextRefresh() {
        scheduledRefresh?.cancel()
        let hasActiveProvider = snapshots.contains { $0.activity.isActive }
        guard let interval = preferences.refreshMode.interval(
            hasActiveProvider: hasActiveProvider,
            customSeconds: preferences.customRefreshSeconds
        ) else {
            return
        }

        scheduledRefresh = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await self?.scheduledRefreshDidFire()
        }
    }

    private func scheduledRefreshDidFire() async {
        scheduledRefresh = nil
        await refresh(
            forceRemote: true,
            preserveRemoteDataOnFailure: true
        )
    }

    private func kimiError(_ error: Error, language: AppLanguage) -> String {
        if let collectorError = error as? CollectorError {
            switch collectorError {
            case .invalidCredential:
                return language.text(
                    "Kimi 登录已过期，请先运行 kimi login",
                    "Kimi sign-in expired; run kimi login"
                )
            case .http(let status):
                return language.text(
                    "Kimi 额度服务返回 HTTP \(status)",
                    "Kimi quota service returned HTTP \(status)"
                )
            default:
                break
            }
        }
        return language.text("Kimi 额度同步失败", "Kimi quota sync failed")
    }

    private func glmError(_ error: Error, language: AppLanguage) -> String {
        if let clientError = error as? GlmUsageClient.ClientError {
            switch clientError {
            case .missingCredential:
                return language.text(
                    "GLM 凭证缺失：设置 ZAI_CODING_CN_API_KEY 或写入 ~/.dsh/.credentials.yaml",
                    "GLM credential missing: set ZAI_CODING_CN_API_KEY or ~/.dsh/.credentials.yaml"
                )
            case .invalidCredential:
                return language.text(
                    "GLM API Key 无效，请检查 ZAI Coding Plan Key",
                    "GLM API key invalid; check your Z.AI Coding Plan key"
                )
            case .invalidResponse(let message):
                return language.text(
                    "GLM 额度响应异常：\(message)",
                    "GLM quota response error: \(message)"
                )
            case .http(let status):
                return language.text(
                    "GLM 额度服务返回 HTTP \(status)",
                    "GLM quota service returned HTTP \(status)"
                )
            }
        }
        return language.text("GLM 额度同步失败", "GLM quota sync failed")
    }

    private func deepSeekError(_ error: Error, language: AppLanguage) -> String {
        if let clientError = error as? DeepSeekBalanceClient.ClientError {
            switch clientError {
            case .missingCredential:
                return language.text(
                    "请先配置 DeepSeek API Key",
                    "Configure a DeepSeek API key first"
                )
            case .invalidCredential:
                return language.text(
                    "DeepSeek 拒绝了该 Key（401）。请使用开放平台生成的 API Key，不是网页或桌面端登录信息。",
                    "DeepSeek rejected this key (401). Use an API key created on the developer platform, not web or desktop sign-in details."
                )
            case .http(let status):
                return language.text(
                    "DeepSeek 余额接口返回 HTTP \(status)",
                    "DeepSeek balance endpoint returned HTTP \(status)"
                )
            case .keychain:
                return language.text(
                    "无法访问 macOS 钥匙串",
                    "Could not access macOS Keychain"
                )
            case .invalidResponse:
                return language.text(
                    "DeepSeek 返回了无法识别的余额数据",
                    "DeepSeek returned unreadable balance data"
                )
            }
        }
        return language.text("DeepSeek 余额同步失败", "DeepSeek balance sync failed")
    }
}
