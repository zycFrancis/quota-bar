# HANDOVER — quota-bar（zycFrancis fork）

本轮日期：2026-10-17~19。上游 [pumpkinpieuncle/quota-bar](https://github.com/pumpkinpieuncle/quota-bar) v1.4.0。

## 本轮事实
- **v1.5.11（2026-10-19，跨空间状态栏面板彻底修复，用户已验证）**：症状「前台有程序/全屏 app 时点状态栏图标看不到余额栏，仅空桌面可见」。三层根因（全部插桩实证，诊断工具：/tmp/realclick CGEvent 真实点击 + Swift 直发分布式通知绕开挂起的 notifyutil + 文件级日志绕开统一日志 <private> 重d）：
  1. macOS 27 在活动 app 位于其它空间（全屏 Chrome 等）时**整段吞掉**第三方状态项点击——事件只进 global monitor（NSEvent.addGlobalMonitorForEvents，无需权限），本地/action/菜单接管均收不到；同空间未激活 app 则正常投递。对策：global monitor 兜底，命中按钮 `accessibilityFrame()`（离屏代理 window 的 convertToScreen 是假坐标，AX 帧才是合成后真实位置）且 200ms 内无本地投递 → 直接 toggle。
  2. NSPopover 窗口空间被钉死在状态项离屏代理所属的桌面空间，show 后设 canJoinAllSpaces 无效（onActiveSpace 恒 false）。对策：下拉面板改自管 NSPanel（borderless+nonactivatingPanel、level .statusBar、上屏**前**设 [.canJoinAllSpaces, .fullScreenAuxiliary]、hidesOnDeactivate=false、AX 帧定位）。
  3. show 同瞬间 NSApp.activate 与新状态栏导航场景（NSMenuBarNavigateAction）竞争致 transient popover <300ms 内被系统关闭。对策：不激活。
  transient 收起语义由 local+global 监视器自实现（面板/图标帧外点击收起）；右键菜单、Dock 点击不变。排查弯路存证：v1.5.10 曾用「activate 再 show」修掉了同空间遮挡场景但没修跨空间（用户验证不通过后深挖）。
- **发布流水线修复（v1.5.9/v1.5.10）**：publish 步骤 `test -f RELEASE_NOTES_$version.md` 缺 v 前缀，与仓库 v1.4.1 起 `RELEASE_NOTES_v*.md` 命名不符——**v1.4.1 以来每次发版 publish 必挂**，被 continue-on-error 掩盖成「偶发」，历史 release 全靠手动补发。已改公式（`RELEASE_NOTES_v$version.md`）+ 加 set -x + 去 continue-on-error，v1.5.10 起流水线全自动发布验证通过。
- **v1.5.8（2026-10-17）**：新增第八家 provider **Devin**（Cognition CLI，Connect RPC GetUserStatus，`~/.local/share/devin/credentials.toml` 的 windsurf_api_key，周/日窗、微美元透支余额可负）。多 Agent 协作完成（glm-5.3×2 并行执行 + Lead 验收）。CI 三轮收敛：谓词闭包版 `#expect(throws:)` 在 runner 的 swift-testing 不存在（改 do/catch + Equatable）；新增 ProviderID 必须同步改 Tests 里三处硬编码名单断言（providerOrder/visibleProviderOrder/hiddenProviders）。
- **PR 流程**：PR #1（auto-rearm→main，rebase 合并）；main 为唯一发版源，auto-rearm 为开发分支（注意：auto-rearm 的 Info.plist 版本号落后 main，其 CI artifact 文件名是旧版本号）。
- **v1.5.6（2026-10-11 Codex 数据排查）**：用户报 OpenAI 数据不对。排查结论：账号一致（46920d71…）、重新登录后 OpenAI account/rateLimits/read 对 ProLite 仍恒报 primary.usedPercent=0（周窗口），服务端口径失真，CLI 无其他用量端点；顺带发现 rateLimitResetCredits 有 2 张可用重置券。改进：id_token 过期检测（过期→卡片提示 codex login，防失真假数据）+ ProLite 恒 0 时口径说明（以 ChatGPT App 为准）。
- **v1.5.5 常驻验证（2026-10-10，全自动化）**：分布式通知 `local.quotabar.showMenu` 弹菜单 → AX 点「设置…」开窗 → `/tmp/axclick.swift`（AXUIElement 递归搜索 kAXTitle/kAXDescription 含"模型管理"的按钮并 kAXPressAction）切 tab → 截图 + Vision OCR 五项全命中（一键配置 / 复制 Pr… / "把 Prompt 发给你正在用的主力 agent…" / 胶囊 GLM / 胶囊 Kimi）。结论：一键配置卡片在五家凭证齐全时仍常驻显示，v1.5.5 行为符合预期。截图 `/tmp/setup-card.png`。附带沉淀：SwiftUI 深层嵌套下 AppleScript entire contents 枚举为空，需 AXUIElement 递归；⌘, 快捷键在无 key window 的 app 上不可达，开设置窗走菜单路径最稳。
- **v1.5.4/v1.5.5**：一键配置卡片 v1.5.4 曾改为仅缺配置时显示，用户要求常驻，v1.5.5 恢复无条件显示；均已发布并装机。
- **v1.5.3**：彻底移除窗口接力（WindowKeeper/ClaudeArmer/设置区块/测试全删，二进制 strings 验证 0 残留，defaults 残留键手动清理）；新增模型管理「一键配置」卡片——按各家凭证就绪状态（五枚胶囊）动态生成 Prompt，一键复制发给主力 agent 自动完成安装+配置（含安全约束）。
- **v1.5.2**：面板刷新按钮旁加 lastRefresh 相对时间（Text style .relative）；菜单栏百分比来源可设置（StatusPercentSource：none/auto/五家，设置→通用，装机已设 none，AX 描述从 menu bar item 11% 变纯图标证实生效）。
- **v1.5.1 最终形态**：彻底移除常驻浮窗（FloatingPanel/ContentView/⌥⌘Q/布局设置全删），只保留 左键=纵向额度 popover、右键=标准菜单、左键 Dock=popover；菜单栏图标改为代码绘制三环（StatusRingIcon，与 Dock 图标同参数，template 自动适配深浅、低额度变橙）；fork 为主仓库（用户明确保留 fork 关系），zycFrancis/quota-bar main=glm-provider，v1.5.0/v1.5.1 已发。另一会话的窗口接力（WindowKeeper/ClaudeArmer）已合入并修复周几解析 bug。
- **v1.4.8 状态栏与菜单观感修复**：新增 menuBarDisplayMode .icon（gauge 图标+最优单一百分比，装机 defaults 已切 icon）；右键菜单删 5 行灰色 provider 行成标准小菜单；switch 补 exhaustive 分支（CI 曾挂）。教训：菜单栏截图验证在自动隐藏菜单栏+无视觉模型下不可行，像素测量误把暗背景当内容，勿重蹈。
- **2026-10-10 全面 review + v1.4.6**：审查全部改动（977+/187-），修复两处：设置窗 level .floating→.normal（正常窗口层级）、已开设置窗时点卡片"管理"现在会重建并切到对应 tab。CI swift test 37 项全过，装机验证 6×200+1×304 零失败。记录项（不改）：GLM limits 空数组防御分支为死代码（parseResponse 保证非空）；GlmCredentialStore memo 为进程级缓存（改凭证需重启）。
- **remote 坑**：standalone remote 曾误指旧 fork zycFrancis/quota-bar（fork 删除因缺 delete_repo scope 未成功，仍占 quota-bar 名），导致 v1.4.6 一度推错仓库、dispatch 跑了旧 main；已改指 coding-quota-bar 并修正。**待办：用户授权 `gh auth refresh -h github.com -s delete_repo` 后删 fork，再 `gh repo rename quota-bar`，并同步 Updater.repo/README 引用后发一版**。
- **独立公开仓库**：[zycFrancis/quota-bar](https://github.com/zycFrancis/quota-bar)（main=glm-provider 全历史，v1.4.5 release 已建，Actions 已启用）；Updater.repo 已改指新仓库（待下次发版生效）。旧 fork zycFrancis/quota-bar 保留用于 rebase 上游。

- fork `zycFrancis/quota-bar`，分支 `glm-provider`，新增 **GLM Coding Plan** provider，发布 v1.4.1；随后修复 Kimi 安装判定（v1.4.2）；v1.4.3 新增右键下拉面板与透明度/宽度设置；v1.4.4 左键改为打开独立设置窗口；v1.4.5 修复 GLM 重置时间解析。
- 本机 `/Applications/Quota Bar.app`（**v1.4.5 当前版**）运行中，五家剩余额度全部可见：Codex、Claude、Kimi、GLM、DeepSeek。
- 当前交互：**左键=独立设置弹窗**（NSWindow，浮于图标下方，不再挂在浮窗上，`openSettingsWindow`）；**右键=纵向额度下拉面板**（NSPopover transient）；原 NSMenu 在下拉面板"…"按钮；浮窗开关=⌥⌘Q 或菜单 toggle 项。设置内容 `SettingsPanelContent`（原 SettingsOverlay 改造，自带深色背景+透明度跟随）。
- v1.4.2 修复：`collectKimi` 原本只认 `~/.kimi-code/bin/kimi` CLI 二进制，本机没装 CLI 导致 Kimi 永远"未发现"；现凭证文件存在即视为已安装。验证：`~/.quotabar/kimi-usage.json` 落盘（plan Allegro，5h 100/100）。
- v1.4.5 修复：GLM 官方接口 `nextResetTime` 是 Unix 毫秒时间戳（非 ISO 字符串），`GlmUsageClient.resetDate` 兼容两种形态；dsh 插件 `quota-providers.js` 同步修复。教训：解析验证必须用线上真实响应，手造样本会掩盖类型差异。
- v1.4.3 交互改造：右键状态栏图标 → NSPopover 纵向额度列表（transient，点外自动收起）；原右键 NSMenu 移到面板"…"按钮（保留退出/更新检查等唯一入口）；新增偏好 `panelOpacity`（0.35–1.0，作用于浮窗+下拉面板背景，含 VisualEffectBackground alphaValue）与 `popoverWidth`（260–560pt），设置 → 通用 有滑杆；浮窗尺寸仍靠拖拽边缘。

## 关键改动

| 文件 | 内容 |
|---|---|
| `Sources/QuotaBar/GlmUsageClient.swift` | 新增：GLM 凭证发现（env → `~/.dsh/.credentials.yaml` refs → `~/.zai/`）+ `open.bigmodel.cn/api/monitor/usage/quota/limit` 拉取解析（5h/weekly/MCP monthly） |
| `Sources/QuotaBar/Models.swift` | ProviderID 加 `.glm`（title/symbol/accentHex） |
| `Sources/QuotaBar/LocalCollectors.swift` | bundle 加 `collectGlm`（有凭证即 installed） |
| `Sources/QuotaBar/AppModel.swift` | 刷新接入 + `glmError` 文案 |
| `Sources/QuotaBar/BrandLogos.swift` | GLM logo（蓝底白 N） |
| `Sources/QuotaBar/Updater.swift` | 更新源指向本 fork，防上游发版覆盖 GLM 版 |
| `Tests/QuotaBarTests/QuotaBarTests.swift` | 断言加入 glm |
| `.github/workflows/release.yml` | checkout `fetch-depth: 0`；Build 后 upload-artifact 兜底；Publish `continue-on-error` |

## 本机凭证链（零弹窗）

- GLM：`~/.dsh/.credentials.yaml` → `refs.ZAI_CODING_CN_API_KEY`
- Kimi：`~/.kimi-code/credentials/kimi-code.json`（access_token 字段填 API key，expires_at 远期）
- DeepSeek：`~/.deepseek/credentials.json`（api_key 字段）

## 坑

1. 本地 CLT 只有 macOS 27 SDK，SwiftUI `@State` 已宏化而 CLT 缺 `libSwiftUIMacros.dylib`，本地无法编译；**只能走 GitHub Actions（macos-15 runner）构建**。
2. actions/checkout 对 tag 事件 + `fetch-tags: true` 冲突（"Cannot fetch both … and refs/tags/…"），用 `fetch-depth: 0` 替代。
3. workflow 的 Publish 步骤在该 fork 上静默 exit 1（0.07s 无输出，未定位到具体命令），已 `continue-on-error` + artifact 兜底；release 可事后手动 `gh release create` 补建。
4. 升级安装会把"新增 provider"自动隐藏：安装前已 `defaults write local.quotabar.app knownProviders -array … glm …` + `hiddenProviders` 不含 glm。

## 未完成 / 下一步

- 上游若发布 v1.4.2+，`git fetch origin && git rebase origin/main` 重放 glm-provider 分支，bump 版本重新打 tag 走 CI。
- GLM 国际版端点（api.z.ai）未接，目前硬编码 open.bigmodel.cn。
