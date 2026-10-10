import AppKit
import Carbon
import Combine
import QuartzCore
import SwiftUI

final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// How close an edge has to be before the panel jumps flush against it.
    private let snapDistance: CGFloat = 14

    override func constrainFrameRect(
        _ frameRect: NSRect,
        to screen: NSScreen?
    ) -> NSRect {
        let target = screen
            ?? NSScreen.screens.first { $0.frame.intersects(frameRect) }
            ?? NSScreen.main
        guard let target else { return frameRect }

        // AppKit would otherwise keep a titled window below the menu bar, which
        // is exactly what stops the panel reaching the top of the display.
        let full = target.frame
        let visible = target.visibleFrame
        var frame = frameRect

        let candidateX: [CGFloat] = [full.minX, visible.minX, visible.maxX - frame.width, full.maxX - frame.width]
        for candidate in candidateX where abs(frame.minX - candidate) < snapDistance {
            frame.origin.x = candidate
            break
        }
        let candidateY: [CGFloat] = [full.minY, visible.minY, visible.maxY - frame.height, full.maxY - frame.height]
        for candidate in candidateY where abs(frame.origin.y - candidate) < snapDistance {
            frame.origin.y = candidate
            break
        }

        // Stay fully on the display, but allow every edge including the strip
        // behind the menu bar.
        frame.origin.x = min(
            max(frame.origin.x, full.minX),
            max(full.minX, full.maxX - frame.width)
        )
        frame.origin.y = min(
            max(frame.origin.y, full.minY),
            max(full.minY, full.maxY - frame.height)
        )
        return frame
    }
}

final class MenuBarMarqueeView: NSView {
    private let iconView = NSImageView()
    private let textClipView = NSView()
    private let textLayer = CATextLayer()
    private var currentText = ""
    private(set) var cycleDuration: CFTimeInterval = 0
    private(set) var singleCycleWidth: CGFloat = 0
    private(set) var textContentWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        iconView.imageScaling = .scaleProportionallyDown
        addSubview(iconView)

        textClipView.wantsLayer = true
        textClipView.layer?.masksToBounds = true
        addSubview(textClipView)

        textLayer.alignmentMode = .left
        textLayer.truncationMode = .none
        textLayer.isWrapped = false
        textLayer.shadowColor = NSColor.black.cgColor
        textLayer.shadowOpacity = 0.55
        textLayer.shadowRadius = 1
        textLayer.shadowOffset = .zero
        textClipView.layer?.addSublayer(textLayer)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(
            x: 3,
            y: (bounds.height - 17) / 2,
            width: 17,
            height: 17
        )
        textClipView.frame = NSRect(
            x: 25,
            y: 0,
            width: max(0, bounds.width - 28),
            height: bounds.height
        )
        textLayer.frame.origin.y = (textClipView.bounds.height - textLayer.frame.height) / 2
    }

    func update(text: String, image: NSImage?, font: NSFont) {
        iconView.image = image
        guard currentText != text || textLayer.animation(forKey: "marquee") == nil else {
            return
        }
        currentText = text
        let cycle = text + "      "
        let repeatedText = cycle + cycle
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.96)
        ]
        textLayer.contentsScale = window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
        textLayer.string = NSAttributedString(
            string: repeatedText,
            attributes: attributes
        )
        let cycleWidth = (cycle as NSString).size(
            withAttributes: attributes
        ).width
        let completeSize = (repeatedText as NSString).size(
            withAttributes: attributes
        )
        singleCycleWidth = ceil(cycleWidth)
        textContentWidth = ceil(completeSize.width)
        textLayer.frame = NSRect(
            x: 0,
            y: (textClipView.bounds.height - ceil(completeSize.height)) / 2,
            width: textContentWidth,
            height: ceil(completeSize.height)
        )
        layoutSubtreeIfNeeded()

        textLayer.removeAllAnimations()
        let animation = CABasicAnimation(keyPath: "transform.translation.x")
        animation.fromValue = 0
        animation.toValue = -singleCycleWidth
        animation.duration = min(12, max(6, Double(cycleWidth / 40)))
        cycleDuration = animation.duration
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        textLayer.add(animation, forKey: "marquee")
    }

    func stop() {
        textLayer.removeAllAnimations()
        currentText = ""
    }

    var isAnimating: Bool {
        textLayer.animation(forKey: "marquee") != nil
    }

    var renderedText: String {
        (textLayer.string as? NSAttributedString)?.string ?? ""
    }

    var renderedTextColor: NSColor? {
        guard
            let attributed = textLayer.string as? NSAttributedString,
            attributed.length > 0
        else {
            return nil
        }
        return attributed.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? NSColor
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private let model = AppModel()
    private var panel: FloatingPanel?
    /// Set while the app itself is moving the panel so programmatic layout
    /// changes are not mistaken for the user repositioning it.
    private var isAdjustingPanel = false
    private var hostingView: NSHostingView<ContentView>?
    private var panelContainer: NSView?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?
    /// 右键状态栏图标的纵向额度下拉面板。
    private var quotaPopover: NSPopover?
    /// 左键状态栏图标打开的独立设置窗口。
    private var settingsWindow: NSWindow?
    private var toggleMenuItem: NSMenuItem?
    private var refreshMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var quitMenuItem: NSMenuItem?
    private var quotaWindowMenuItem: NSMenuItem?
    private var fiveHourMenuItem: NSMenuItem?
    private var weeklyMenuItem: NSMenuItem?
    private var monthlyMenuItem: NSMenuItem?
    private var snapshotObservation: AnyCancellable?
    private var quotaWindowObservation: AnyCancellable?
    private var panelLayoutObservation: AnyCancellable?
    private var providerOrderObservation: AnyCancellable?
    private var hiddenProvidersObservation: AnyCancellable?
    private var menuBarDisplayObservation: AnyCancellable?
    private var lowQuotaObservation: AnyCancellable?
    private var marqueeView: MenuBarMarqueeView?
    private var screenParametersObserver: NSObjectProtocol?
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?
    private var showPanelObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular：常规应用形态——Dock 图标、应用图标、系统菜单栏完整可用。
        NSApp.setActivationPolicy(.regular)
        makeMainMenu()
        makePanel()
        makeStatusItem()
        registerShowPanelHotKey()
        // 自动化入口：外部（AppleScript/终端）可通过分布式通知触发菜单弹出，
        // 便于自动化测试与无障碍脚本驱动。
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showMenuFromAutomation(_:)),
            name: NSNotification.Name("local.quotabar.showMenu"),
            object: nil
        )
        model.start()
    }

    @objc private func showMenuFromAutomation(_ notification: Notification) {
        guard let button = statusItem?.button else { return }
        updateMenuTitles()
        statusMenu?.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        if let showPanelObserver {
            NotificationCenter.default.removeObserver(showPanelObserver)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let hotKeyHandlerRef {
            RemoveEventHandler(hotKeyHandlerRef)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // 点 Dock 图标 = 弹出整个额度信息（与左键状态栏图标一致）。
        if let button = statusItem?.button {
            toggleQuotaPopover(from: button)
        } else {
            showPanel()
        }
        return true
    }

    private func makeMainMenu() {
        // SwiftUI previously supplied the application and editing menus. Keep
        // their keyboard shortcuts available in the AppKit lifecycle too.
        let language = model.language
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        let applicationMenu = NSMenu(title: "Quota Bar")
        let settingsItem = applicationMenu.addItem(
            withTitle: language.text("设置…", "Settings…"),
            action: #selector(openSettingsFromMenu), keyEquivalent: ","
        )
        settingsItem.target = self
        applicationMenu.addItem(
            withTitle: language.text("退出 Quota Bar", "Quit Quota Bar"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: language.text("编辑", "Edit"))
        editMenu.addItem(
            withTitle: language.text("撤销", "Undo"),
            action: Selector(("undo:")), keyEquivalent: "z"
        )
        let redo = editMenu.addItem(
            withTitle: language.text("重做", "Redo"),
            action: Selector(("redo:")), keyEquivalent: "z"
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(
            withTitle: language.text("剪切", "Cut"),
            action: #selector(NSText.cut(_:)), keyEquivalent: "x"
        )
        editMenu.addItem(
            withTitle: language.text("拷贝", "Copy"),
            action: #selector(NSText.copy(_:)), keyEquivalent: "c"
        )
        editMenu.addItem(
            withTitle: language.text("粘贴", "Paste"),
            action: #selector(NSText.paste(_:)), keyEquivalent: "v"
        )
        editMenu.addItem(
            withTitle: language.text("全选", "Select All"),
            action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"
        )
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)
        NSApp.mainMenu = mainMenu
    }

    private func makePanel() {
        let mode = model.preferences.panelLayout
        let size = mode.clamp(
            model.preferences.savedPanelSize(for: mode)
                ?? mode.defaultSize(
                    visibleProviderCount: model.preferences.visibleProviderOrder.count
                )
        )
        let panel = FloatingPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Quota Bar"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // The panel always paints its own dark chrome, so pin AppKit to the dark
        // appearance. Without this the panel inherits the system Light Mode and
        // every label that relies on the default `.primary` colour draws black on
        // the dark background, while the standard controls (segmented pickers,
        // switches, text fields) render in their light style.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.hasShadow = true
        // Above the menu bar so the panel stays readable when it is snapped to
        // the very top of the display.
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.minSize = mode.minSize
        panel.maxSize = mode.maxSize
        panel.delegate = self
        let hostingView = NSHostingView(
            rootView: ContentView(
                model: model,
                onOpenSettings: { [weak self] tab in
                    self?.openSettingsWindow(initialTab: tab)
                },
                onHideToMenuBar: { [weak self] in self?.collapsePanel() },
                onResetGeometry: { [weak self] in self?.resetPanelGeometry() }
            )
        )
        // A titled window hands SwiftUI a titlebar-sized top safe area, which
        // is what pushed the one-line bar's content off centre.
        hostingView.safeAreaRegions = []
        hostingView.sizingOptions = []

        // The hosting view deliberately is *not* the window's contentView. As
        // the contentView of a resizable window it mirrors the SwiftUI content's
        // min/max size onto the window, and measuring a root that contains a
        // ScrollView re-enters the constraint pass — which AppKit turns into a
        // fatal exception. A plain container sidesteps that; the panel already
        // sets its own size limits.
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.cornerRadius = mode.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: container.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        panel.contentView = container
        self.hostingView = hostingView
        self.panelContainer = container

        if let topLeft = model.preferences.savedPanelTopLeft() {
            panel.setFrame(
                NSRect(
                    x: topLeft.x,
                    y: topLeft.y - size.height,
                    width: size.width,
                    height: size.height
                ),
                display: false
            )
        } else if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(
                NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height)
            )
        } else {
            panel.center()
        }
        panel.orderFrontRegardless()
        self.panel = panel

        panelLayoutObservation = model.preferences.$panelLayout
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.resizePanel(for: mode)
            }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        rememberPanelOrigin()
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        rememberPanelSize()
    }

    private func rememberPanelOrigin() {
        guard let panel, panel.isVisible, !isAdjustingPanel else { return }
        model.preferences.setPanelTopLeft(Self.topLeft(of: panel.frame))
    }

    private func rememberPanelSize() {
        guard let panel, panel.isVisible, !isAdjustingPanel else { return }
        model.preferences.setPanelTopLeft(Self.topLeft(of: panel.frame))
        model.preferences.setPanelSize(panel.frame.size, for: model.preferences.panelLayout)
    }

    private static func topLeft(of frame: NSRect) -> CGPoint {
        CGPoint(x: frame.minX, y: frame.maxY)
    }

    private func resetPanelGeometry() {
        model.preferences.resetPanelGeometry()
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return }
        let mode = model.preferences.panelLayout
        let size = mode.defaultSize(
            visibleProviderCount: model.preferences.visibleProviderOrder.count
        )
        let visible = screen.visibleFrame
        isAdjustingPanel = true
        panel.setFrame(
            NSRect(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height,
                width: size.width,
                height: size.height
            ),
            display: true,
            animate: true
        )
        isAdjustingPanel = false
        panel.invalidateShadow()
    }

    private func makeStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.image = statusImage
            button.imagePosition = .imageLeading
            button.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let menu = NSMenu()
        menu.delegate = self
        let toggle = NSMenuItem(
            title: "",
            action: #selector(togglePanel),
            keyEquivalent: "q"
        )
        toggle.target = self
        toggle.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(toggle)
        let settingsItem = NSMenuItem(
            title: model.language.text("设置…", "Settings…"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())

        let windowMenu = NSMenu()
        let fiveHour = NSMenuItem(
            title: "",
            action: #selector(showFiveHourQuota),
            keyEquivalent: ""
        )
        fiveHour.target = self
        windowMenu.addItem(fiveHour)
        let weekly = NSMenuItem(
            title: "",
            action: #selector(showWeeklyQuota),
            keyEquivalent: ""
        )
        weekly.target = self
        windowMenu.addItem(weekly)
        let monthly = NSMenuItem(
            title: "",
            action: #selector(showMonthlyQuota),
            keyEquivalent: ""
        )
        monthly.target = self
        windowMenu.addItem(monthly)
        let windowParent = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        windowParent.submenu = windowMenu
        menu.addItem(windowParent)
        quotaWindowMenuItem = windowParent
        fiveHourMenuItem = fiveHour
        weeklyMenuItem = weekly
        monthlyMenuItem = monthly

        let refresh = NSMenuItem(
            title: "",
            action: #selector(refreshNow),
            keyEquivalent: "r"
        )
        refresh.target = self
        menu.addItem(refresh)
        menu.addItem(.separator())

        let update = NSMenuItem(
            title: "",
            action: #selector(checkForUpdateMenu),
            keyEquivalent: ""
        )
        update.target = self
        menu.addItem(update)
        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)
        statusMenu = menu
        toggleMenuItem = toggle
        refreshMenuItem = refresh
        updateMenuItem = update
        quitMenuItem = quit
        updateMenuTitles()
        updateStatusItem(snapshots: model.snapshots)
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
            }
        }
        snapshotObservation = model.$snapshots
            .receive(on: RunLoop.main)
            .sink { [weak self] snapshots in
                self?.updateStatusItem(snapshots: snapshots)
            }
        quotaWindowObservation = model.preferences.$quotaWindow
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
                self.updateMenuTitles()
                self.republishHUD()
            }
        lowQuotaObservation = model.preferences.$lowQuotaThreshold
            .removeDuplicates()
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
                self.republishHUD()
            }
        providerOrderObservation = model.preferences.$providerOrder
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
                self.updateMenuTitles()
            }
        hiddenProvidersObservation = model.preferences.$hiddenProviders
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
                self.updateMenuTitles()
                self.resizePanel(for: self.model.preferences.panelLayout)
                self.republishHUD()
            }
        menuBarDisplayObservation = model.preferences.$menuBarDisplayMode
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateStatusItem(snapshots: self.model.snapshots)
            }
    }

    private func republishHUD() {
        model.hud.apply(preferences: model.preferences, snapshots: model.snapshots)
    }

    func menuWillOpen(_ menu: NSMenu) {
        updateMenuTitles()
    }

    private func updateMenuTitles() {
        let language = model.language
        toggleMenuItem?.title = panel?.isVisible == true
            ? language.text("收起到菜单栏", "Collapse to menu bar")
            : language.text("显示浮窗", "Show panel")
        refreshMenuItem?.title = language.text("立即刷新", "Refresh now")
        updateMenuItem?.title = {
            switch model.updateState {
            case .available(let version):
                return language.text(
                    "更新到 v\(version)…",
                    "Update to v\(version)…"
                )
            case .downloading:
                return language.text("正在下载更新…", "Downloading update…")
            case .installing:
                return language.text("正在安装更新…", "Installing update…")
            case .checking:
                return language.text("正在检查更新…", "Checking for updates…")
            default:
                return language.text("检查更新", "Check for updates")
            }
        }()
        quitMenuItem?.title = language.text("退出 Quota Bar", "Quit Quota Bar")
        fiveHourMenuItem?.title = language.text("显示 5 小时额度", "Show 5-hour quota")
        weeklyMenuItem?.title = language.text("显示周额度", "Show weekly quota")
        monthlyMenuItem?.title = language.text("显示月额度", "Show monthly quota")
        fiveHourMenuItem?.state = model.preferences.quotaWindow == .fiveHour ? .on : .off
        weeklyMenuItem?.state = model.preferences.quotaWindow == .weekly ? .on : .off
        monthlyMenuItem?.state = model.preferences.quotaWindow == .monthly ? .on : .off
        quotaWindowMenuItem?.title = language.text(
            "顶部栏额度",
            "Menu bar quota"
        )
    }

    private func updateStatusItem(snapshots: [ProviderSnapshot]) {
        let providers = model.preferences.visibleProviderOrder

        // 小图标模式：仅 gauge 图标 + 最优 provider 的单一百分比，
        // 宽度与其他菜单栏应用一致，避免五家摘要平铺成超宽横条。
        if model.preferences.menuBarDisplayMode == .icon {
            statusItem?.length = NSStatusItem.variableLength
            if let marquee = marqueeView {
                marquee.stop()
                marquee.isHidden = true
            }
            let headline = providers
                .compactMap { provider in
                    snapshots.first { $0.id == provider }
                }
                .compactMap { snapshot in
                    MenuBarSummary.value(
                        snapshot: snapshot,
                        preference: model.preferences.quotaWindow
                    )
                }
                .first { $0.hasSuffix("%") }
            statusItem?.button?.image = statusImage
            statusItem?.button?.title = headline ?? ""
            statusItem?.button?.toolTip = MenuBarSummary.accessibilityText(
                snapshots: snapshots,
                language: model.language,
                preference: model.preferences.quotaWindow,
                providers: providers
            )
            return
        }

        let fullSummary = MenuBarSummary.text(
            snapshots: snapshots,
            preference: model.preferences.quotaWindow,
            providers: providers
        )
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        let fullWidth = (fullSummary as NSString).size(
            withAttributes: [.font: font]
        ).width
        let screenWidth = statusItem?.button?.window?.screen?.visibleFrame.width
            ?? NSScreen.main?.visibleFrame.width
            ?? 1_440
        let useScrolling = MenuBarSummary.shouldUseScrolling(
            mode: model.preferences.menuBarDisplayMode,
            screenWidth: screenWidth,
            fullSummaryWidth: fullWidth
        )
        if useScrolling, let statusItem, let button = statusItem.button {
            statusItem.length = 155
            button.image = nil
            button.title = ""
            let marquee = marqueeView ?? MenuBarMarqueeView(frame: button.bounds)
            if marqueeView == nil {
                marquee.autoresizingMask = [.width, .height]
                button.addSubview(marquee)
                marqueeView = marquee
            }
            marquee.isHidden = false
            marquee.frame = button.bounds
            marquee.update(
                text: fullSummary,
                image: statusImage,
                font: .monospacedSystemFont(ofSize: 11, weight: .semibold)
            )
        } else {
            marqueeView?.stop()
            marqueeView?.isHidden = true
            statusItem?.length = NSStatusItem.variableLength
            statusItem?.button?.image = statusImage
            statusItem?.button?.title = fullSummary
        }
        statusItem?.button?.toolTip = MenuBarSummary.accessibilityText(
            snapshots: snapshots,
            language: model.language,
            preference: model.preferences.quotaWindow,
            providers: providers
        )
    }

    private var statusImage: NSImage? {
        // 三环表盘图标，与 Dock 应用图标同款设计；
        // 正常态为 template 单色（系统按菜单栏明暗自动着色），
        // 任一可见套餐低于阈值时转为橙色警示（非 template）。
        let isLow = !model.lowQuotaProviders.isEmpty
        let image = StatusRingIcon.image(
            size: 16,
            color: isLow ? .systemOrange : .black
        )
        image.isTemplate = !isLow
        return image
    }


    @objc private func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            collapsePanel()
        } else {
            showPanel()
        }
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            // 右键：标准系统菜单（白底实体菜单），含设置入口。
            updateMenuTitles()
            statusMenu?.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.minY - 4),
                in: sender
            )
        } else {
            // 左键：弹出整个额度信息（纵向下拉面板）。
            toggleQuotaPopover(from: sender)
        }
    }

    @objc private func openSettingsFromMenu() {
        openSettingsWindow()
    }

    /// 左键：打开独立设置窗口（正常弹窗，不再挂在浮窗上）。
    /// 已打开且目标 tab 相同则前置激活；请求不同 tab 时重建以切换页面。
    /// 浮窗开关仍保留在 ⌥⌘Q 与"…"菜单里。
    private func openSettingsWindow(initialTab: SettingsTab = .general) {
        if
            let window = settingsWindow,
            window.isVisible,
            initialTab == .general
        {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        settingsWindow?.orderOut(nil)
        let content = SettingsPanelContent(
            model: model,
            initialTab: initialTab,
            onClose: { [weak self] in
                self?.settingsWindow?.orderOut(nil)
            },
            onResetGeometry: { [weak self] in
                self?.resetPanelGeometry()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "Quota Bar"
        window.contentView = hosting
        window.isReleasedWhenClosed = false
        // .normal：普通弹窗层级，切换到其他应用时正常退后，
        // 而不是像 .floating 一样永远浮在最前。
        window.level = .normal
        // 出现在状态栏图标下方，水平方向夹在屏幕内。
        if
            let button = statusItem?.button,
            let buttonWindow = button.window,
            let screen = buttonWindow.screen
        {
            let iconRect = buttonWindow.convertToScreen(
                button.convert(button.bounds, to: nil)
            )
            var topLeft = NSPoint(
                x: iconRect.midX - window.frame.width / 2,
                y: iconRect.minY
            )
            topLeft.x = max(screen.visibleFrame.minX,
                            min(topLeft.x, screen.visibleFrame.maxX - window.frame.width))
            window.setFrameTopLeftPoint(topLeft)
        } else {
            window.center()
        }
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 右键：在状态栏图标下方弹出各 provider 纵向排列的下拉面板，
    /// 点击面板外任意位置自动收起（transient）。
    private func toggleQuotaPopover(from sender: NSStatusBarButton) {
        if let popover = quotaPopover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let content = QuotaPopoverContent(
            model: model,
            onOpenSettings: { [weak self] in
                self?.quotaPopover?.performClose(nil)
                self?.openSettingsWindow()
            }
        )
        let hosting = NSHostingView(rootView: content)
        let width = model.preferences.popoverWidth
        hosting.setFrameSize(NSSize(width: width, height: 0))
        let fitting = hosting.fittingSize
        let maxHeight = (sender.window?.screen?.visibleFrame.height ?? 900) * 0.72
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let controller = NSViewController()
        controller.view = hosting
        popover.contentViewController = controller
        popover.contentSize = NSSize(
            width: width,
            height: min(max(fitting.height, 180), maxHeight)
        )
        quotaPopover = popover
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    private func collapsePanel() {
        panel?.orderOut(nil)
        updateMenuTitles()
    }

    @objc private func showPanel() {
        panel?.orderFrontRegardless()
        updateMenuTitles()
    }

    private func registerShowPanelHotKey() {
        showPanelObserver = NotificationCenter.default.addObserver(
            forName: .quotaBarShowPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.showPanel()
            }
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )
        let handler: EventHandlerUPP = { _, event, _ in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            guard status == noErr, hotKeyID.id == 1 else { return status }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .quotaBarShowPanel, object: nil)
            }
            return noErr
        }
        InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &hotKeyHandlerRef
        )
        let hotKeyID = EventHotKeyID(
            signature: fourCharacterCode("QBAR"),
            id: 1
        )
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Q),
            UInt32(cmdKey | optionKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }

    /// Resizes in place: the top edge and whichever side edge the panel is
    /// parked against both stay put, so collapsing and expanding never walks
    /// the panel across the screen.
    private func resizePanel(for mode: PanelLayoutMode) {
        guard let panel else { return }
        let oldFrame = panel.frame
        let newSize = mode.clamp(
            model.preferences.savedPanelSize(for: mode)
                ?? mode.defaultSize(
                    visibleProviderCount: model.preferences.visibleProviderOrder.count
                )
        )
        let newFrame = PanelGeometry.resized(
            oldFrame,
            to: newSize,
            onScreen: panel.screen?.frame
        )
        isAdjustingPanel = true
        panel.minSize = mode.minSize
        panel.maxSize = mode.maxSize
        panelContainer?.layer?.cornerRadius = mode.cornerRadius
        panel.setFrame(newFrame, display: true, animate: true)
        isAdjustingPanel = false
        model.preferences.setPanelTopLeft(Self.topLeft(of: panel.frame))
        panel.invalidateShadow()
        updateMenuTitles()
    }

    @objc private func showFiveHourQuota() {
        model.preferences.quotaWindow = .fiveHour
    }

    @objc private func showWeeklyQuota() {
        model.preferences.quotaWindow = .weekly
    }

    @objc private func showMonthlyQuota() {
        model.preferences.quotaWindow = .monthly
    }

    @objc private func refreshNow() {
        Task { await model.refresh(forceRemote: true) }
    }

    /// One click from the status menu: check, and if a newer release exists,
    /// download, swap and relaunch without further prompts.
    @objc private func checkForUpdateMenu() {
        Task {
            await model.checkForUpdate()
            switch model.updateState {
            case .available:
                await model.installUpdate()
            case .upToDate:
                showUpdateAlert(
                    model.language.text(
                        "已是最新版本（v\(AppVersion.short)）。",
                        "You are on the latest version (v\(AppVersion.short))."
                    )
                )
            case .failed(let message):
                showUpdateAlert(
                    model.language.text(
                        "检查更新失败：\(message)",
                        "Update check failed: \(message)"
                    )
                )
            default:
                break
            }
        }
    }

    private func showUpdateAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Quota Bar"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

enum MenuBarSummary {
    static func shouldUseScrolling(
        mode: MenuBarDisplayMode,
        screenWidth: CGFloat,
        fullSummaryWidth: CGFloat
    ) -> Bool {
        switch mode {
        case .icon:
            // icon 模式在 updateStatusItem 里提前返回，不会走到这里。
            false
        case .automatic:
            fullSummaryWidth > max(160, screenWidth * 0.14)
        case .full:
            false
        case .scrolling:
            true
        }
    }

    static func text(
        snapshots: [ProviderSnapshot],
        preference: QuotaWindowPreference,
        providers: [ProviderID]
    ) -> String {
        let values = providers.map { provider in
            let quota = snapshots
                .first { $0.id == provider }
                .flatMap { value(snapshot: $0, preference: preference) }
                ?? "—"
            return "\(abbreviation(provider)) \(quota)"
        }
        return values.joined(separator: "  ")
    }

    static func accessibilityText(
        snapshots: [ProviderSnapshot],
        language: AppLanguage,
        preference: QuotaWindowPreference,
        providers: [ProviderID]
    ) -> String {
        let values = providers.map { provider in
            let quota = snapshots
                .first { $0.id == provider }
                .flatMap { value(snapshot: $0, preference: preference) }
                ?? language.text("未知", "unknown")
            return "\(provider.title) \(quota)"
        }
        return "Quota Bar · "
            + preference.label(language: language)
            + " · "
            + values.joined(separator: ", ")
    }

    private static func abbreviation(_ provider: ProviderID) -> String {
        provider.title
    }

    static func value(
        snapshot: ProviderSnapshot,
        preference: QuotaWindowPreference
    ) -> String? {
        if
            let balance = snapshot.balances.first,
            snapshot.id == .deepseek || snapshot.limits.isEmpty
        {
            return balance.compactText
        }
        // Fall back to the provider's own window: services like Gemini only
        // report a daily allowance and would otherwise read "—" in weekly mode.
        if let limit = QuotaWindowSelector.primary(
            in: snapshot.limits,
            preference: preference
        ) {
            return "\(Int(limit.clampedRemaining.rounded()))%"
        }
        return snapshot.balances.first?.compactText
    }
}

private extension Notification.Name {
    static let quotaBarShowPanel = Notification.Name("QuotaBarShowPanel")
}

@main
enum QuotaBarApp {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        // AppDelegate owns the panel and its settings overlay. A placeholder
        // SwiftUI Settings scene can open an empty window at launch.
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
