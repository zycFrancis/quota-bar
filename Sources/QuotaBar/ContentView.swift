import AppKit
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers

    var id: String { rawValue }

    func title(language: AppLanguage) -> String {
        switch self {
        case .general:
            return language.text("常规设置", "General")
        case .providers:
            return language.text("模型管理", "Models")
        }
    }

    var icon: String {
        switch self {
        case .general:
            return "gearshape.fill"
        case .providers:
            return "slider.horizontal.3"
        }
    }
}

private struct TrafficLights: View {
    let onClose: () -> Void
    let onMinimize: () -> Void
    let onZoom: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TrafficLightButton(
                color: Color(red: 1, green: 0.37, blue: 0.34),
                symbol: "xmark",
                help: "Hide",
                action: onClose
            )
            TrafficLightButton(
                color: Color(red: 1, green: 0.74, blue: 0.23),
                symbol: "minus",
                help: "One line",
                action: onMinimize
            )
            TrafficLightButton(
                color: Color(red: 0.2, green: 0.78, blue: 0.35),
                symbol: "arrow.up.left.and.arrow.down.right",
                help: "Standard",
                action: onZoom
            )
        }
        .frame(width: 48)
    }
}

private struct TrafficLightButton: View {
    let color: Color
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .overlay {
                    if isHovering {
                        Image(systemName: symbol)
                            .font(.system(size: 6, weight: .black))
                            .foregroundStyle(Color.black.opacity(0.58))
                    }
                }
                .frame(width: 12, height: 12)
                .overlay {
                    Circle().stroke(Color.black.opacity(0.18), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

private struct ProviderCard: View {
    let snapshot: ProviderSnapshot
    let language: AppLanguage
    let quotaWindow: QuotaWindowPreference
    let lowQuotaThreshold: Int
    let installClaudeCollector: () -> Void
    let manageProviders: () -> Void

    private var accent: Color { snapshot.id.accent }

    private var showsBalance: Bool {
        snapshot.balances.first != nil
            && (snapshot.id == .deepseek || snapshot.limits.isEmpty)
    }

    /// The window the user asked to see, falling back to the shortest one the
    /// provider reported.
    private var primaryLimit: LimitWindow? {
        QuotaWindowSelector.primary(in: snapshot.limits, preference: quotaWindow)
    }

    private var secondaryLimits: [LimitWindow] {
        QuotaWindowSelector.secondary(in: snapshot.limits, preference: quotaWindow)
    }

    private var isLow: Bool {
        guard lowQuotaThreshold > 0, let primaryLimit else { return false }
        return Int(primaryLimit.clampedRemaining.rounded()) <= lowQuotaThreshold
    }

    private var activityColor: Color {
        switch snapshot.activity {
        case .waitingApproval: Color(red: 1, green: 0.7, blue: 0.28)
        case .working: Color(red: 0.43, green: 0.92, blue: 0.66)
        case .thinking: Color(red: 0.48, green: 0.7, blue: 1)
        case .idle: Color.white.opacity(0.34)
        case .offline: Color.white.opacity(0.2)
        case .needsAttention: Color(red: 1, green: 0.69, blue: 0.3)
        case .connected: Color(red: 0.43, green: 0.92, blue: 0.66)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                BrandLogoView(
                    provider: snapshot.id,
                    size: 16,
                    dimmed: snapshot.activity == .offline
                )
                .frame(width: 25, height: 25)
                .background(
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .fill(accent.opacity(0.18))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                        .stroke(accent.opacity(0.28), lineWidth: 0.8)
                }

                Text(snapshot.id.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(2)

                Spacer(minLength: 2)

                HStack(spacing: 4) {
                    Circle()
                        .fill(activityColor)
                        .frame(width: 5, height: 5)
                    Text(snapshot.activity.label(language: language))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.52))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .layoutPriority(0)
            }

            if showsBalance, let balance = snapshot.balances.first {
                balanceBody(balance)
            } else if let primaryLimit {
                quotaBody(primaryLimit)
            } else {
                emptyBody
            }

            Spacer(minLength: 0)

            if let resetCards = snapshot.resetCards, resetCards.availableCount > 0 {
                resetCardsBadge(resetCards)
            }

            if let prediction = snapshot.resetPrediction {
                resetPredictionBadge(prediction)
            }

            Text(snapshot.detail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.38))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(snapshot.source)

            if snapshot.id == .deepseek {
                Button {
                    if let url = URL(string: "https://platform.deepseek.com/") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(language.text("前往 API 平台", "Open API platform"))
                            .font(.system(size: 9, weight: .semibold))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 7.5, weight: .bold))
                    }
                }
                .buttonStyle(CollectorButtonStyle(tint: accent))
                .help(language.text(
                    "在浏览器中打开 platform.deepseek.com",
                    "Opens platform.deepseek.com in your browser"
                ))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(isLow ? Color(red: 1, green: 0.35, blue: 0.32).opacity(0.09)
                            : Color.white.opacity(0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            isLow
                                ? AnyShapeStyle(Color(red: 1, green: 0.42, blue: 0.38).opacity(0.55))
                                : AnyShapeStyle(LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.13),
                                        Color.white.opacity(0.035)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )),
                            lineWidth: 0.75
                        )
                }
        )
    }

    @ViewBuilder
    private func resetCardsBadge(_ cards: ResetCardInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(cards.items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 4) {
                    Image(systemName: "ticket.fill")
                        .font(.system(size: 7.5))
                        .foregroundStyle(Color(red: 0.28, green: 0.82, blue: 0.72))
                    Text(language.text("重置卡 #\(index + 1)", "Pass #\(index + 1)"))
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("· " + item.localizedExpiryText(language: language))
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }
                .padding(.horizontal, 5)
                .padding(.vertical, 2.5)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(Color.white.opacity(0.09), lineWidth: 0.5)
                        )
                )
                .help(item.tooltipText(language: language))
            }
        }
    }

    @ViewBuilder
    private func resetPredictionBadge(_ prediction: CodexResetPrediction) -> some View {
        Button {
            if let url = URL(string: "https://aihot.news/codex-reset") {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3.5) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 7.5))
                    .foregroundStyle(Color(red: 1, green: 0.65, blue: 0.3))
                Text(prediction.displayText)
                    .font(.system(size: 8.8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 6.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(red: 1, green: 0.65, blue: 0.3).opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color(red: 1, green: 0.65, blue: 0.3).opacity(0.18), lineWidth: 0.5)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(prediction.fullTooltip(language: language))
    }

    private func balanceBody(_ balance: AccountBalance) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(balance.compactText)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Text(language.text("余额", "balance"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.42))
            }

            HStack {
                Text(language.text("充值", "Topped up"))
                Spacer()
                Text("\(balance.symbol)\(NSDecimalNumber(decimal: balance.toppedUp).stringValue)")
            }
            HStack {
                Text(language.text("赠送", "Granted"))
                Spacer()
                Text("\(balance.symbol)\(NSDecimalNumber(decimal: balance.granted).stringValue)")
            }
            .padding(.top, 2)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.53))
    }

    private func quotaBody(_ primary: LimitWindow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(Int(primary.clampedRemaining.rounded()))")
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .foregroundStyle(isLow ? Color(red: 1, green: 0.5, blue: 0.46) : .white)
                    Text("%")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer(minLength: 2)
                    Text(
                        "\(localizedLimitLabel(primary.label)) "
                            + language.text("可用", "available")
                    )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }

                QuotaProgress(
                    value: primary.clampedRemaining / 100,
                    tint: isLow ? Color(red: 1, green: 0.42, blue: 0.38) : accent
                )

                if let reset = primary.resetText(language: language) {
                    Text(reset)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }
            }

            ForEach(secondaryLimits.prefix(2)) { secondary in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(localizedLimitLabel(secondary.label))
                        Spacer(minLength: 2)
                        Text(
                            "\(Int(secondary.clampedRemaining.rounded()))% "
                                + language.text("可用", "available")
                        )
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.53))
                    .lineLimit(1)
                    QuotaProgress(value: secondary.clampedRemaining / 100, tint: accent)
                    if let reset = secondary.resetText(language: language) {
                        Text(reset)
                            .font(.system(size: 8.8, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var emptyBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("—")
                .font(.system(size: 28, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.32))
            Text(language.text("暂无精确额度", "No exact quota yet"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))

            if snapshot.id == .claude && snapshot.setupAvailable {
                Button(
                    language.text("配置 / 修复采集", "Configure / repair capture"),
                    action: installClaudeCollector
                )
                    .buttonStyle(CollectorButtonStyle(tint: accent))
            } else if snapshot.id == .deepseek {
                Button(
                    language.text("管理 DeepSeek", "Manage DeepSeek"),
                    action: manageProviders
                )
                .buttonStyle(CollectorButtonStyle(tint: accent))
            }
        }
    }

    private func localizedLimitLabel(_ label: String) -> String {
        let lower = label.lowercased()
        if lower == "7 天" || lower.contains("week") {
            return language.text("7 天", "7 days")
        }
        if lower == "5 小时" || lower.contains("5h") {
            return language.text("5 小时", "5 hours")
        }
        if lower == "月额度" || lower.contains("month") || lower == "30 天" || lower == "月" {
            return language.text("月额度", "Monthly")
        }
        if language == .english {
            return label
                .replacingOccurrences(of: " 小时", with: " hours")
                .replacingOccurrences(of: " 天", with: " days")
                .replacingOccurrences(of: " 分钟", with: " minutes")
                .replacingOccurrences(of: "月额度", with: "Monthly")
                .replacingOccurrences(of: "额度", with: "Quota")
        }
        return label
    }
}

private struct TabItemButton: View {
    let tab: SettingsTab
    let isSelected: Bool
    let language: AppLanguage
    let namespace: Namespace.ID
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(tab.title(language: language))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(
                isSelected
                    ? Color.white
                    : (isHovered ? Color.white.opacity(0.85) : Color.white.opacity(0.55))
            )
            .padding(.horizontal, 11)
            .padding(.vertical, 5)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.11)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .matchedGeometryEffect(id: "activeTabIndicator", in: namespace)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.white.opacity(0.18), lineWidth: 0.8)
                        )
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                } else if isHovered {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.white.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

/// 独立设置窗口内容：不再挂在浮窗上，由 AppDelegate 以普通 NSWindow 承载。
struct SettingsPanelContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @ObservedObject private var hud: HUDBridge
    @State private var selectedTab: SettingsTab
    let onClose: () -> Void
    let onResetGeometry: () -> Void
    @State private var copiedHUDURL = false
    @State private var launchAtLoginError: String?
    @Namespace private var tabNamespace

    init(
        model: AppModel,
        initialTab: SettingsTab = .general,
        onClose: @escaping () -> Void,
        onResetGeometry: @escaping () -> Void
    ) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
        _hud = ObservedObject(wrappedValue: model.hud)
        _selectedTab = State(initialValue: initialTab)
        self.onClose = onClose
        self.onResetGeometry = onResetGeometry
    }

    private var language: AppLanguage { preferences.language }

    private var headerSubtitle: String {
        switch selectedTab {
        case .general:
            return "Quota Bar \(model.versionText)"
        case .providers:
            return language.text("模型排序、可见性与授权", "Order, visibility & auth")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1.5) {
                    Text(language.text("设置", "Settings"))
                        .font(.system(size: 14.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(headerSubtitle)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.42))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                tabPicker

                Spacer(minLength: 4)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(HeaderButtonStyle())
                .help(language.text("关闭", "Close"))
            }

            Group {
                switch selectedTab {
                case .general:
                    generalSettingsContent
                case .providers:
                    ProviderManagerContent(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            footerStatus
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                // 独立 NSWindow 不再继承浮窗的深色环境，这里自带背景。
                Color(red: 0.045, green: 0.052, blue: 0.066)
                    .opacity(0.9 * preferences.panelOpacity)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(red: 0.085, green: 0.095, blue: 0.115))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                    }
            }
        )
        .shadow(color: .black.opacity(0.42), radius: 20, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var tabPicker: some View {
        HStack(spacing: 3) {
            ForEach(SettingsTab.allCases) { tab in
                TabItemButton(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    language: language,
                    namespace: tabNamespace
                ) {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        selectedTab = tab
                    }
                }
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.black.opacity(0.3))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    private var generalSettingsContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 330), spacing: 8)],
                alignment: .leading,
                spacing: 8
            ) {
                languageRow
                launchAtLoginRow
                updateRow
                refreshRow
                quotaWindowRow
                menuBarDisplayRow
                warningRow
                opacityRow
                popoverWidthRow
                statusPercentRow
                hudRow
            }
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    @ViewBuilder
    private var footerStatus: some View {
        HStack(spacing: 7) {
            if selectedTab == .general {
                Image(systemName: "leaf.fill")
                    .foregroundStyle(Color(red: 0.43, green: 0.92, blue: 0.66))
                Text(language.text(
                    "状态只来自本地，不调用模型",
                    "Local status never calls a model"
                ))
            } else {
                Image(systemName: "slider.horizontal.2.square")
                    .foregroundStyle(Color(red: 0.43, green: 0.82, blue: 0.98))
                Text(language.text(
                    "调整顺序、显示隐藏或暂停刷新 · DeepSeek 凭证安全存于钥匙串",
                    "Reorder, hide or pause quotas · DeepSeek credentials stored securely in Keychain"
                ))
            }
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.white.opacity(0.5))
        .lineLimit(2)
    }

    private var languageRow: some View {
        settingRow(
            title: language.text("语言", "Language"),
            detail: language.text("界面语言立即切换", "Changes immediately")
        ) {
            Picker("", selection: $preferences.language) {
                ForEach(AppLanguage.allCases) { item in
                    Text(item.nativeName).tag(item)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .onChange(of: preferences.language) { _, _ in
                model.preferencesChanged(languageChanged: true)
            }
        }
    }

    private var opacityRow: some View {
        settingRow(
            title: language.text("面板透明度", "Panel opacity"),
            detail: language.text(
                "额度面板与设置窗口的背景不透明度",
                "Background opacity of the quota popover and settings window"
            )
        ) {
            Slider(value: $preferences.panelOpacity, in: 0.35...1.0, step: 0.05)
                .frame(width: 140)
        }
    }

    private var statusPercentRow: some View {
        settingRow(
            title: language.text("菜单栏百分比", "Menu bar percent"),
            detail: language.text(
                "图标旁显示哪家的剩余额度，或不显示",
                "Which quota shows beside the icon, or none"
            )
        ) {
            Picker("", selection: $preferences.statusPercentSource) {
                ForEach(StatusPercentSource.allCases) { source in
                    Text(source.label(language: language)).tag(source)
                }
            }
            .labelsHidden()
            .frame(width: 140)
        }
    }

    private var popoverWidthRow: some View {
        settingRow(
            title: language.text("下拉面板宽度", "Popover width"),
            detail: language.text(
                "右键状态栏图标的纵向列表宽度",
                "Width of the vertical list opened from the status icon"
            )
        ) {
            Slider(value: $preferences.popoverWidth, in: 260...560, step: 20)
                .frame(width: 140)
        }
    }

    private var launchAtLoginRow: some View {
        settingRow(
            title: language.text("开机自启", "Launch at login"),
            detail: launchAtLoginError
                ?? language.text(
                    "登录 macOS 时自动启动 Quota Bar",
                    "Start Quota Bar automatically when you log in"
                )
        ) {
            Toggle(
                "",
                isOn: Binding(
                    get: { LaunchAtLogin.isEnabled },
                    set: { enabled in
                        launchAtLoginError = LaunchAtLogin.setEnabled(enabled)
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
        }
    }

    private var updateRow: some View {
        settingRow(
            title: language.text("软件更新", "Software update"),
            detail: updateDetail
        ) {
            updateActionButton
        }
    }

    private var updateDetail: String {
        if !AppUpdater.canSelfUpdate {
            return language.text(
                "需以打包的 App 方式运行才能自动更新",
                "Self-update requires running the packaged .app"
            )
        }
        switch model.updateState {
        case .idle:
            return language.text(
                "当前 \(model.versionText) · 启动时会自动检查 GitHub 新版本",
                "Currently \(model.versionText) · checks GitHub on launch"
            )
        case .checking:
            return language.text("正在检查更新…", "Checking for updates…")
        case .upToDate:
            return language.text(
                "当前 \(model.versionText) · 已是最新版本",
                "Currently \(model.versionText) · up to date"
            )
        case .available(let version):
            return language.text(
                "发现新版本 v\(version) · 当前 \(model.versionText)",
                "New version v\(version) available · currently \(model.versionText)"
            )
        case .downloading:
            return language.text("正在下载新版本…", "Downloading the update…")
        case .installing:
            return language.text(
                "下载完成，正在替换并重启…",
                "Downloaded — swapping and restarting…"
            )
        case .failed(let message):
            return language.text(
                "检查失败：\(message)",
                "Update check failed: \(message)"
            )
        }
    }

    @ViewBuilder
    private var updateActionButton: some View {
        switch model.updateState {
        case .available(let version):
            Button {
                Task { await model.installUpdate() }
            } label: {
                Text(language.text("一键更新到 v\(version)", "Update to v\(version)"))
            }
            .buttonStyle(CollectorButtonStyle(tint: Color(red: 0.43, green: 0.92, blue: 0.66)))
        case .checking, .downloading, .installing:
            Text(language.text("请稍候…", "Please wait…"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        default:
            Button {
                Task { await model.checkForUpdate() }
            } label: {
                Text(language.text("检查更新", "Check for updates"))
            }
            .buttonStyle(CollectorButtonStyle(tint: Color(red: 0.55, green: 0.66, blue: 1)))
        }
    }

    private var refreshRow: some View {
        settingRow(
            title: language.text("刷新频率", "Refresh interval"),
            detail: refreshDetail
        ) {
            HStack(spacing: 7) {
                Picker("", selection: $preferences.refreshMode) {
                    ForEach(RefreshMode.allCases) { mode in
                        Text(mode.label(language: language)).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: preferences.refreshMode == .custom ? 108 : 216)
                .onChange(of: preferences.refreshMode) { _, _ in
                    model.preferencesChanged(languageChanged: false)
                }

                if preferences.refreshMode == .custom {
                    TextField("", value: customSecondsBinding, format: .number)
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 62)

                    Text(language.text("秒", "sec"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private var quotaWindowRow: some View {
        settingRow(
            title: language.text("额度窗口", "Quota window"),
            detail: language.text(
                "卡片及统计优先计算的周期",
                "Primary window for cards and stats"
            )
        ) {
            Picker("", selection: $preferences.quotaWindow) {
                ForEach(QuotaWindowPreference.allCases) { window in
                    Text(window.label(language: language)).tag(window)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 220)
        }
    }

    private var menuBarDisplayRow: some View {
        settingRow(
            title: language.text("顶部栏显示", "Menu bar display"),
            detail: language.text(
                "菜单栏额度完整展开或跑马灯滚动",
                "Show all quotas or scroll marquee"
            )
        ) {
            Picker("", selection: $preferences.menuBarDisplayMode) {
                ForEach(MenuBarDisplayMode.allCases) { mode in
                    Text(mode.label(language: language)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 130)
        }
    }

    private var warningRow: some View {
        settingRow(
            title: language.text("低额度提醒", "Low-quota warning"),
            detail: language.text(
                "低于阈值时卡片和单行都会变红",
                "Cards and the one-line bar turn red below this"
            )
        ) {
            Picker("", selection: $preferences.lowQuotaThreshold) {
                Text(language.text("关闭", "Off")).tag(0)
                ForEach([5, 10, 20, 30], id: \.self) { value in
                    Text("\(value)%").tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 200)
        }
    }

    // MARK: - 窗口接力

    private var hudRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(language.text("HUD 外接屏", "HUD display"))
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text(language.text(
                        "在备用手机或 ESP32 上显示额度，只读、不出局域网",
                        "Show quotas on a spare phone or an ESP32 — read-only, LAN only"
                    ))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: $preferences.hudEnabled)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .onChange(of: preferences.hudEnabled) { _, _ in
                        model.preferencesChanged(languageChanged: false)
                    }
            }

            if preferences.hudEnabled {
                HStack(spacing: 8) {
                    Text(language.text("端口", "Port"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    TextField("", value: hudPortBinding, format: .number.grouping(.never))
                        .multilineTextAlignment(.trailing)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)

                    Toggle(isOn: $preferences.hudAllowsLAN) {
                        Text(language.text("允许局域网访问", "Allow LAN access"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .toggleStyle(.checkbox)
                    .onChange(of: preferences.hudAllowsLAN) { _, _ in
                        model.preferencesChanged(languageChanged: false)
                    }

                    Spacer(minLength: 4)

                    Button(language.text("换新令牌", "New token")) {
                        _ = preferences.regenerateHUDToken()
                        model.preferencesChanged(languageChanged: false)
                        copiedHUDURL = false
                    }
                    .buttonStyle(CollectorButtonStyle(tint: .orange))
                }

                HStack(spacing: 8) {
                    Text(hud.hudURL(preferences: preferences)
                        ?? hudStatusPlaceholder)
                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    if let url = hud.hudURL(preferences: preferences) {
                        Button(copiedHUDURL
                            ? language.text("已复制", "Copied")
                            : language.text("复制网址", "Copy URL")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                            copiedHUDURL = true
                        }
                        .buttonStyle(CollectorButtonStyle(
                            tint: Color(red: 0.43, green: 0.92, blue: 0.66)
                        ))
                    }
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }

    private var hudStatusPlaceholder: String {
        switch hud.state {
        case .failed(let message):
            language.text("HUD 启动失败：\(message)", "HUD failed: \(message)")
        case .starting:
            language.text("正在启动…", "Starting…")
        default:
            language.text("未启动", "Not running")
        }
    }

    private var hudPortBinding: Binding<Int> {
        Binding(
            get: { preferences.hudPort },
            set: { newValue in
                preferences.hudPort = min(max(newValue, 1_024), 65_535)
                model.preferencesChanged(languageChanged: false)
            }
        )
    }

    private var customSecondsBinding: Binding<Int> {
        Binding(
            get: { preferences.customRefreshSeconds },
            set: { newValue in
                preferences.customRefreshSeconds = min(max(newValue, 10), 86_400)
                model.preferencesChanged(languageChanged: false)
            }
        )
    }

    private var refreshDetail: String {
        if preferences.refreshMode == .custom {
            return language.text(
                "可输入 10–86400 秒（最长 24 小时）",
                "Enter 10–86400 seconds (up to 24 hours)"
            )
        }
        return language.text(
            "智能模式在全部空闲时仅每 5 分钟读取一次",
            "Smart mode checks only every 5 minutes while idle"
        )
    }

    private func settingRow<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text(detail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .fixedSize(horizontal: false, vertical: true)
        }
        // Side by side while there is room, stacked once the panel narrows.
        return ViewThatFits(in: .horizontal) {
            HStack {
                label
                Spacer(minLength: 8)
                content()
            }
            VStack(alignment: .leading, spacing: 7) {
                label
                content()
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }
}

private struct ProviderManagerContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var preferences: AppPreferences
    @State private var apiKey = ""
    @State private var isSaving = false

    init(model: AppModel) {
        self.model = model
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    private var language: AppLanguage { preferences.language }

    var body: some View {
        GeometryReader { proxy in
            if proxy.size.width >= 560 {
                HStack(alignment: .top, spacing: 12) {
                    ScrollView(.vertical, showsIndicators: false) {
                        providerItems
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxWidth: .infinity)

                    deepSeekSetup
                        .frame(width: min(320, max(260, proxy.size.width * 0.44)))
                }
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        providerItems
                        deepSeekSetup
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var providerItems: some View {
        VStack(spacing: 6) {
            ForEach(Array(preferences.providerOrder.enumerated()), id: \.element) {
                index, provider in
                providerRow(provider, index: index)
            }
        }
    }

    private func providerRow(_ provider: ProviderID, index: Int) -> some View {
        let isHidden = preferences.hiddenProviders.contains(provider)
        let isPaused = preferences.pausedProviders.contains(provider)
        return HStack(spacing: 7) {
            BrandLogoView(provider: provider, size: 14.5, dimmed: isHidden)
                .frame(width: 20)
            Text(provider.title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(isHidden ? 0.35 : 0.82))
            Spacer(minLength: 2)
            Button {
                let willHide = !isHidden
                preferences.setProvider(provider, hidden: willHide)
                if !willHide {
                    Task { await model.refresh(forceRemote: false) }
                }
            } label: {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(ManagerButtonStyle())
            .help(language.text(
                isHidden ? "显示" : "隐藏",
                isHidden ? "Show" : "Hide"
            ))

            Button {
                preferences.setProvider(provider, paused: !isPaused)
                Task { await model.refresh(forceRemote: isPaused) }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .frame(width: 23, height: 23)
            }
            .buttonStyle(ManagerButtonStyle())
            .help(language.text(
                isPaused ? "恢复额度刷新" : "暂停额度刷新",
                isPaused ? "Resume quota refresh" : "Pause quota refresh"
            ))

            Button {
                preferences.moveProvider(provider, offset: -1)
            } label: {
                Image(systemName: "chevron.up")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ManagerButtonStyle())
            .disabled(index == 0)

            Button {
                preferences.moveProvider(provider, offset: 1)
            } label: {
                Image(systemName: "chevron.down")
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(ManagerButtonStyle())
            .disabled(index == preferences.providerOrder.count - 1)
        }
        .padding(.horizontal, 8)
        .frame(height: 31)
        .background(
            Color.white.opacity(isHidden ? 0.025 : 0.05),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var deepSeekStatusText: String {
        guard model.deepSeekKeyConfigured else {
            return language.text("未配置", "Not configured")
        }
        if let source = model.deepSeekCredentialSource {
            switch source {
            case .harness:
                return language.text("DeepSeek Harness 已授权", "DeepSeek Harness authorized")
            case .environment:
                return language.text("环境变量已配置", "Environment variable")
            case .keychain:
                return language.text("钥匙串已配置", "Keychain configured")
            case .config:
                return language.text("本地配置已生效", "Local config")
            }
        }
        return language.text("已配置", "Configured")
    }

    private var deepSeekSetup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                BrandLogoView(provider: .deepseek, size: 15)
                Text("DeepSeek")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer()
                Text(deepSeekStatusText)
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(
                        model.deepSeekKeyConfigured
                            ? Color.green.opacity(0.75)
                            : Color.white.opacity(0.35)
                    )
            }

            SecureField(
                model.deepSeekKeyConfigured
                    ? language.text("输入新 Key 可替换", "Enter a new key to replace")
                    : "sk-…",
                text: $apiKey
            )
            .textFieldStyle(.roundedBorder)

            HStack(spacing: 7) {
                Button {
                    let key = apiKey
                    guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        return
                    }
                    isSaving = true
                    Task {
                        await model.saveDeepSeekAPIKey(key)
                        apiKey = ""
                        isSaving = false
                    }
                } label: {
                    Text(isSaving
                        ? language.text("验证中…", "Checking…")
                        : language.text("保存并验证", "Save & verify"))
                }
                .buttonStyle(CollectorButtonStyle(tint: ProviderID.deepseek.accent))
                .disabled(isSaving || apiKey.isEmpty)

                if model.deepSeekKeyConfigured {
                    Button {
                        Task { await model.removeDeepSeekAPIKey() }
                    } label: {
                        Text(language.text("移除", "Remove"))
                    }
                    .buttonStyle(CollectorButtonStyle(tint: .orange))
                }
            }

            Text(language.text(
                "支持自动识别 DeepSeek Harness 桌面端登录凭证或环境变量 DEEPSEEK_API_KEY，也可在此手动保存 API Key（仅存于钥匙串，只请求 /user/balance）。",
                "Automatically detects DeepSeek Harness credentials or DEEPSEEK_API_KEY env variable, or save an API key manually (stored in Keychain; only /user/balance is requested)."
            ))
            .font(.system(size: 8.8, weight: .medium))
            .foregroundStyle(.white.opacity(0.4))
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(11)
        .background(
            Color.white.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}

private struct QuotaProgress: View {
    let value: Double
    let tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.075))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.7), tint],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(3, proxy.size.width * min(max(value, 0), 1)))
                    .shadow(color: tint.opacity(0.25), radius: 4)
            }
        }
        .frame(height: 5)
    }
}

private struct ManagerButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 8.5, weight: .bold))
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.4 : 0.64))
            .background(
                Color.white.opacity(configuration.isPressed ? 0.09 : 0.045),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

/// 左键状态栏图标的下拉面板：各 provider 纵向排列，
/// 点击面板外任意位置自动收起（NSPopover transient 行为）。
struct QuotaPopoverContent: View {
    let model: AppModel
    let onOpenSettings: () -> Void

    @ObservedObject private var preferences: AppPreferences

    private var language: AppLanguage { preferences.language }

    init(
        model: AppModel,
        onOpenSettings: @escaping () -> Void
    ) {
        self.model = model
        self.onOpenSettings = onOpenSettings
        _preferences = ObservedObject(wrappedValue: model.preferences)
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Text(language.text("额度总览", "Quotas"))
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Spacer(minLength: 6)
                Text(model.lastRefresh, style: .relative)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .help(language.text("距上次刷新的时间", "Time since last refresh"))
                Button {
                    Task { await model.refresh(forceRemote: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(HeaderButtonStyle())
                .help(language.text("立即刷新", "Refresh now"))
                Button(action: onOpenSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.76))
                        .frame(width: 24, height: 22)
                }
                .buttonStyle(HeaderButtonStyle())
                .help(language.text("打开设置", "Open settings"))
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(model.visibleSnapshots) { snapshot in
                        ProviderCard(
                            snapshot: snapshot,
                            language: language,
                            quotaWindow: preferences.quotaWindow,
                            lowQuotaThreshold: preferences.lowQuotaThreshold,
                            installClaudeCollector: model.installClaudeCollector,
                            manageProviders: onOpenSettings
                        )
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(
            ZStack {
                VisualEffectBackground(alphaValue: preferences.panelOpacity)
                Color(red: 0.045, green: 0.052, blue: 0.066)
                    .opacity(0.9 * preferences.panelOpacity)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .environment(\.colorScheme, .dark)
    }
}

private struct VisualEffectBackground: NSViewRepresentable {
    var alphaValue: Double = 1.0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.alphaValue = alphaValue
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.alphaValue = alphaValue
    }
}

private struct HeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.48 : 0.76))
            .background(
                Color.white.opacity(configuration.isPressed ? 0.1 : 0.065),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
    }
}

private struct CollectorButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 9.5, weight: .semibold))
            // The label used to be the tint at full strength, which only reached
            // about 3:1 against its own tinted capsule. The capsule carries the
            // colour now, so the label can go white and clear 4.5:1.
            .foregroundStyle(.white.opacity(configuration.isPressed ? 0.72 : 0.96))
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(tint.opacity(configuration.isPressed ? 0.08 : 0.13), in: Capsule())
    }
}

private struct NoticeView: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color(red: 0.57, green: 0.72, blue: 1))
            Text(text)
                .font(.system(size: 10.5, weight: .medium))
                .lineLimit(2)
            Spacer()
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white.opacity(0.82))
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.7)
        }
    }
}
