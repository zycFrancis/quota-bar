# HANDOVER — quota-bar（zycFrancis fork）

本轮日期：2026-10-08/09。上游 [pumpkinpieuncle/quota-bar](https://github.com/pumpkinpieuncle/quota-bar) v1.4.0。

## 本轮事实
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
