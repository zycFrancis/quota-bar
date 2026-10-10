import Combine
import Foundation

@MainActor
final class AppPreferences: ObservableObject {
    @Published var language: AppLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    @Published var refreshMode: RefreshMode {
        didSet { defaults.set(refreshMode.rawValue, forKey: Keys.refreshMode) }
    }

    @Published var customRefreshSeconds: Int {
        didSet {
            defaults.set(customRefreshSeconds, forKey: Keys.customRefreshSeconds)
        }
    }

    @Published var quotaWindow: QuotaWindowPreference {
        didSet { defaults.set(quotaWindow.rawValue, forKey: Keys.quotaWindow) }
    }

    @Published var menuBarDisplayMode: MenuBarDisplayMode {
        didSet {
            defaults.set(
                menuBarDisplayMode.rawValue,
                forKey: Keys.menuBarDisplayMode
            )
        }
    }

    @Published var panelLayout: PanelLayoutMode {
        didSet { defaults.set(panelLayout.rawValue, forKey: Keys.panelLayout) }
    }

    @Published var providerOrder: [ProviderID] {
        didSet {
            defaults.set(providerOrder.map(\.rawValue), forKey: Keys.providerOrder)
        }
    }

    @Published var hiddenProviders: Set<ProviderID> {
        didSet {
            defaults.set(
                hiddenProviders.map(\.rawValue).sorted(),
                forKey: Keys.hiddenProviders
            )
        }
    }

    @Published var pausedProviders: Set<ProviderID> {
        didSet {
            defaults.set(
                pausedProviders.map(\.rawValue).sorted(),
                forKey: Keys.pausedProviders
            )
        }
    }

    /// Percentage at or below which a provider is treated as running low. Zero
    /// turns the warning off.
    @Published var lowQuotaThreshold: Int {
        didSet { defaults.set(lowQuotaThreshold, forKey: Keys.lowQuotaThreshold) }
    }

    /// 面板背景不透明度（0.35–1.0），同时作用于浮窗与右键下拉面板。
    @Published var panelOpacity: Double {
        didSet { defaults.set(panelOpacity, forKey: Keys.panelOpacity) }
    }

    /// 右键下拉面板的宽度（pt）。
    @Published var popoverWidth: Double {
        didSet { defaults.set(popoverWidth, forKey: Keys.popoverWidth) }
    }

    /// 菜单栏图标旁百分比数字的来源。
    @Published var statusPercentSource: StatusPercentSource {
        didSet { defaults.set(statusPercentSource.rawValue, forKey: Keys.statusPercentSource) }
    }

    @Published var hudEnabled: Bool {
        didSet { defaults.set(hudEnabled, forKey: Keys.hudEnabled) }
    }


    /// 接力失败时发 macOS 通知。

    @Published var hudPort: Int {
        didSet { defaults.set(hudPort, forKey: Keys.hudPort) }
    }

    /// When off the HUD only answers on 127.0.0.1, which is useless for a phone
    /// but handy for testing on the Mac itself.
    @Published var hudAllowsLAN: Bool {
        didSet { defaults.set(hudAllowsLAN, forKey: Keys.hudAllowsLAN) }
    }

    private let defaults: UserDefaults

    private enum Keys {
        static let language = "appLanguage"
        static let refreshMode = "refreshMode"
        static let customRefreshSeconds = "customRefreshSeconds"
        static let quotaWindow = "quotaWindow"
        static let menuBarDisplayMode = "menuBarDisplayMode"
        static let panelLayout = "panelLayout"
        static let providerOrder = "providerOrder"
        static let hiddenProviders = "hiddenProviders"
        static let pausedProviders = "pausedProviders"
        static let knownProviders = "knownProviders"
        static let lowQuotaThreshold = "lowQuotaThreshold"
        static let hudEnabled = "hudEnabled"
        static let hudPort = "hudPort"
        static let hudAllowsLAN = "hudAllowsLAN"
        static let hudToken = "hudToken"

        static let panelTopLeft = "panelTopLeft"
        static let panelOpacity = "panelOpacity"
        static let popoverWidth = "popoverWidth"
        static let statusPercentSource = "statusPercentSource"

        static func panelSize(_ mode: PanelLayoutMode) -> String {
            "panelSize.\(mode.rawValue)"
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if
            let raw = defaults.string(forKey: Keys.language),
            let saved = AppLanguage(rawValue: raw)
        {
            language = saved
        } else {
            language = Locale.preferredLanguages.first?.hasPrefix("zh") == true
                ? .chinese
                : .english
        }

        if
            let raw = defaults.string(forKey: Keys.refreshMode),
            let saved = RefreshMode(rawValue: raw)
        {
            refreshMode = saved
        } else {
            refreshMode = .smart
        }

        let savedSeconds = defaults.integer(forKey: Keys.customRefreshSeconds)
        customRefreshSeconds = savedSeconds == 0
            ? 120
            : min(max(savedSeconds, 10), 86_400)

        let savedOpacity = defaults.double(forKey: Keys.panelOpacity)
        panelOpacity = savedOpacity == 0 ? 1.0 : min(max(savedOpacity, 0.35), 1.0)

        let savedPopoverWidth = defaults.double(forKey: Keys.popoverWidth)
        popoverWidth = savedPopoverWidth == 0
            ? 340
            : min(max(savedPopoverWidth, 260), 560)

        statusPercentSource = StatusPercentSource(
            rawValue: defaults.string(forKey: Keys.statusPercentSource) ?? ""
        ) ?? .auto

        if
            let raw = defaults.string(forKey: Keys.quotaWindow),
            let saved = QuotaWindowPreference(rawValue: raw)
        {
            quotaWindow = saved
        } else {
            quotaWindow = .fiveHour
        }

        if
            let raw = defaults.string(forKey: Keys.menuBarDisplayMode),
            let saved = MenuBarDisplayMode(rawValue: raw)
        {
            menuBarDisplayMode = saved
        } else {
            menuBarDisplayMode = .automatic
        }

        if
            let raw = defaults.string(forKey: Keys.panelLayout),
            let saved = PanelLayoutMode(rawValue: raw)
        {
            panelLayout = saved
        } else {
            panelLayout = .standard
        }

        let savedOrder = (defaults.stringArray(forKey: Keys.providerOrder) ?? [])
            .compactMap(ProviderID.init(rawValue:))
        providerOrder = savedOrder
            + ProviderID.allCases.filter { !savedOrder.contains($0) }

        let isFirstRun = defaults.object(forKey: Keys.hiddenProviders) == nil
        if isFirstRun {
            hiddenProviders = ProviderID.optInByDefault
        } else {
            // Providers added by an update start hidden so an upgrade never
            // silently widens the panel with services the user does not use.
            let recorded = (defaults.stringArray(forKey: Keys.knownProviders) ?? [])
                .compactMap(ProviderID.init(rawValue:))
            // Installs from before this key existed knew exactly these four.
            let known = recorded.isEmpty
                ? Set<ProviderID>([.codex, .claude, .kimi, .deepseek])
                : Set(recorded)
            let introduced = ProviderID.allCases.filter { !known.contains($0) }
            hiddenProviders = Set(
                (defaults.stringArray(forKey: Keys.hiddenProviders) ?? [])
                    .compactMap(ProviderID.init(rawValue:))
            ).union(introduced)
        }
        defaults.set(ProviderID.allCases.map(\.rawValue), forKey: Keys.knownProviders)

        pausedProviders = Set(
            (defaults.stringArray(forKey: Keys.pausedProviders) ?? [])
                .compactMap(ProviderID.init(rawValue:))
        )

        lowQuotaThreshold = defaults.object(forKey: Keys.lowQuotaThreshold) == nil
            ? 10
            : min(max(defaults.integer(forKey: Keys.lowQuotaThreshold), 0), 100)

        hudEnabled = defaults.bool(forKey: Keys.hudEnabled)
        let savedPort = defaults.integer(forKey: Keys.hudPort)
        hudPort = savedPort == 0 ? 7_425 : min(max(savedPort, 1_024), 65_535)
        hudAllowsLAN = defaults.object(forKey: Keys.hudAllowsLAN) == nil
            ? true
            : defaults.bool(forKey: Keys.hudAllowsLAN)

    }

    /// 读取某供应商的点火模型（未配置时给默认值）。
    // MARK: - Panel geometry

    /// Panel geometry is written on every drag, so it deliberately lives
    /// outside `@Published` state: republishing here would redraw the whole
    /// panel while the user is still moving it.
    ///
    /// The position is stored as the *top* left corner and shared by both
    /// layouts. AppKit frames grow upwards from their origin, so remembering a
    /// bottom-left corner per layout made the panel's top edge jump every time
    /// it collapsed or expanded. Sizes stay per layout, and are only recorded
    /// when the user resizes by hand, so showing another service still widens a
    /// panel that has never been resized.
    func savedPanelTopLeft() -> CGPoint? {
        guard
            let values = defaults.array(forKey: Keys.panelTopLeft) as? [Double],
            values.count == 2
        else {
            return nil
        }
        return CGPoint(x: values[0], y: values[1])
    }

    func setPanelTopLeft(_ point: CGPoint) {
        defaults.set([point.x, point.y], forKey: Keys.panelTopLeft)
    }

    func savedPanelSize(for mode: PanelLayoutMode) -> CGSize? {
        guard
            let values = defaults.array(forKey: Keys.panelSize(mode)) as? [Double],
            values.count == 2,
            values[0] > 0,
            values[1] > 0
        else {
            return nil
        }
        return mode.clamp(CGSize(width: values[0], height: values[1]))
    }

    func setPanelSize(_ size: CGSize, for mode: PanelLayoutMode) {
        defaults.set([size.width, size.height], forKey: Keys.panelSize(mode))
    }

    var hasCustomPanelSize: Bool {
        PanelLayoutMode.allCases.contains { savedPanelSize(for: $0) != nil }
    }

    func resetPanelGeometry() {
        defaults.removeObject(forKey: Keys.panelTopLeft)
        for mode in PanelLayoutMode.allCases {
            defaults.removeObject(forKey: Keys.panelSize(mode))
        }
    }

    // MARK: - HUD

    /// Shared secret the HUD page and the ESP32 firmware present. Generated on
    /// demand and stored in defaults because it only guards a read-only status
    /// feed on the local network.
    func hudToken() -> String {
        if let existing = defaults.string(forKey: Keys.hudToken), !existing.isEmpty {
            return existing
        }
        let alphabet = Array("abcdefghijkmnopqrstuvwxyz23456789")
        let token = String((0..<12).map { _ in alphabet.randomElement() ?? "x" })
        defaults.set(token, forKey: Keys.hudToken)
        return token
    }

    func regenerateHUDToken() -> String {
        defaults.removeObject(forKey: Keys.hudToken)
        return hudToken()
    }

    var visibleProviderOrder: [ProviderID] {
        providerOrder.filter { !hiddenProviders.contains($0) }
    }

    func setProvider(_ provider: ProviderID, hidden: Bool) {
        var next = hiddenProviders
        if hidden {
            guard visibleProviderOrder.count > 1 else { return }
            next.insert(provider)
        } else {
            next.remove(provider)
        }
        hiddenProviders = next
    }

    func moveProvider(_ provider: ProviderID, offset: Int) {
        guard
            let oldIndex = providerOrder.firstIndex(of: provider),
            providerOrder.indices.contains(oldIndex + offset)
        else {
            return
        }
        var next = providerOrder
        next.swapAt(oldIndex, oldIndex + offset)
        providerOrder = next
    }

    func setProvider(_ provider: ProviderID, paused: Bool) {
        var next = pausedProviders
        if paused {
            next.insert(provider)
        } else {
            next.remove(provider)
        }
        pausedProviders = next
    }
}
