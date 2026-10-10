# Quota Bar

macOS 菜单栏 AI 编码额度监控——**Codex、Claude、Kimi、GLM（智谱）、DeepSeek 五家剩余额度一屏尽览**。

基于开源项目 [pumpkinpieuncle/quota-bar](https://github.com/pumpkinpieuncle/quota-bar) 改造：新增 GLM Coding Plan 支持、右键纵向下拉面板、独立设置窗口、透明度调节。上游不含 GLM 且交互形态不同，故维护此独立分支。上游原版说明见 [README.upstream.md](README.upstream.md)。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-Silver) ![Apple Silicon](https://img.shields.io/badge/arch-Apple%20Silicon-blue) ![License MIT](https://img.shields.io/badge/license-MIT-green)

## 功能

- **五家额度同屏**：Codex（5h/7d/Credits）、Claude（5h/7d）、Kimi（5h/周）、GLM Coding Plan（5h/周/MCP 月度）、DeepSeek（账户余额），各自显示剩余百分比、已用量与重置倒计时。
- **左键额度面板**：左键状态栏图标（或点 Dock 图标），图标下方弹出纵向额度列表，点面板外任意位置自动收起。
- **右键标准菜单**：设置、额度窗口切换、刷新、更新检查、退出。
- **透明度与尺寸**：面板透明度 35%–100% 可调（浮窗、下拉面板、设置窗统一生效）；下拉面板宽度 260–560pt 可调；浮窗拖拽边缘改宽高。
- **零模型调用**：所有查询只走各家官方额度/余额接口，不产生任何模型推理消耗。
- **零弹窗凭证**：凭证全部走本地文件，不碰 macOS 钥匙串，不会反复要求授权。
- 其余继承上游：HUD 外接屏（手机/ESP32 镜像）、低额度变色提醒、中英双语、开机自启、应用内检查更新（指向本仓库）。

## 安装

1. 从 [Releases](https://github.com/zycFrancis/quota-bar/releases) 下载最新 DMG，校验同目录 `SHA256SUMS.txt`；
2. 将 `Quota Bar.app` 拖入"应用程序"；
3. 首次打开若提示"无法验证开发者"：系统设置 → 隐私与安全性 → 仍要打开（本应用为 ad-hoc 签名，未做 Apple 公证）。

## 凭证配置

各服务凭证的发现顺序与格式（全部为纯文件读取）：

| 服务 | 来源（按优先级） | 说明 |
|---|---|---|
| Codex | `~/.codex/auth.json` 自动发现 | 无需配置 |
| Claude | Claude Desktop 本地用量历史 / Claude Code status line | 卡片上点"启用零额度采集"按引导配置 |
| Kimi | ① 环境变量 `KIMI_API_KEY` ② `~/.kimi-code/credentials/kimi-code.json` | 无 Kimi Code CLI 也能用：写 `{"access_token": "<你的 API Key>", "expires_at": 1900000000}` |
| GLM | ① 环境变量 `ZAI_CODING_CN_API_KEY` / `GLM_API_KEY` ② `~/.dsh/.credentials.yaml` 的 `refs.ZAI_CODING_CN_API_KEY` ③ `~/.zai/credentials.json` | 智谱 Coding Plan 的 API Key |
| DeepSeek | ① 钥匙串（应用内输入）② 环境变量 `DEEPSEEK_API_KEY` ③ `~/.dsh/.credentials.yaml` ④ `~/.deepseek/credentials.json` | 任意一层命中即可 |

## 使用

| 操作 | 行为 |
|---|---|
| 左键状态栏图标 / 点击 Dock 图标 | 纵向额度下拉面板（自动收起） |
| 右键状态栏图标 | 标准菜单：设置…、额度窗口、刷新、更新、退出 |
| `⌘,` | 打开设置 |
| `⌘Q` | 退出 |

设置 → 通用：界面语言、开机自启、刷新频率、5h/周/月窗口偏好、低额度阈值、面板透明度、下拉面板宽度。

## 从源码构建

```bash
git clone https://github.com/zycFrancis/quota-bar.git
cd quota-bar-glm
./scripts/build-app.sh
```

注意：本仓库只验证过 GitHub Actions（macos-15 runner）构建。纯 CommandLineTools 环境编译会失败——macOS 26/27 SDK 将 SwiftUI `@State` 宏化，而 CLT 缺 `libSwiftUIMacros` 插件。推送 `v*` tag 即可触发 CI 出包（见 `.github/workflows/release.yml`，含 artifact 兜底）。

## 与上游的差异

| 项 | 上游 v1.4.0 | 本分支 |
|---|---|---|
| GLM Coding Plan | 不支持 | 支持（5h/周/MCP 月度 + 重置倒计时，毫秒时间戳解析） |
| Kimi 无 CLI | 不显示 | 凭证文件存在即显示 |
| 右键图标 | 文字菜单 | 纵向额度下拉面板（菜单移入"…"） |
| 左键图标 | 开关浮窗 | 打开独立设置窗口 |
| 透明度 | 无 | 35%–100% 可调，三处窗口统一生效 |
| 应用内更新 | 指向上游 | 指向本仓库 |

## 致谢与许可

- 上游项目 [pumpkinpieuncle/quota-bar](https://github.com/pumpkinpieuncle/quota-bar)（MIT），本项目在其基础上改造并保持同一许可。
- 额度接口解析参考 [CyBerKitTen0009/dsh-quota-dashboard](https://github.com/CyBerKitTen0009/dsh-quota-dashboard)（MIT）对 GLM/Kimi 端点的整理。

[MIT](LICENSE)
