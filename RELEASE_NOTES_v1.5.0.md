# Quota Bar v1.5.0

首个正式发布版。相对上游 [pumpkinpieuncle/quota-bar](https://github.com/pumpkinpieuncle/quota-bar) v1.4.0 的全部改动：

## 核心能力

- **GLM Coding Plan 支持**：5 小时 / 每周 / MCP 月度额度与重置倒计时（上游无此功能），凭证自动发现（环境变量 / `~/.dsh/.credentials.yaml` / `~/.zai/`）。
- **Kimi 免 CLI**：凭证文件存在即可拉取官方额度，无需安装 Kimi Code CLI。

## 应用形态与交互

- 常规应用：Dock 图标、启动台、`⌘Q` 退出、`⌘,` 设置；三环活动表盘应用图标（`scripts/make-icon.swift` 程序化生成）。
- 左键状态栏图标：纵向额度下拉面板（点外自动收起）。
- 右键状态栏图标：标准系统菜单（设置 / 刷新 / 额度窗口 / 更新 / 退出），无灰色死行。
- 状态栏"小图标"模式：图标 + 最优套餐百分比，不再平铺超宽摘要。
- 面板透明度（35%–100%）与下拉面板宽度（260–560pt）可调。
- 自动化入口：分布式通知 `local.quotabar.showMenu` 可触发菜单（AppleScript / 测试驱动）。

## 工程与质量

- GitHub Actions 构建（本地 CommandLineTools 无法编译宏化的 SwiftUI，见 README）。
- 37 项单元测试全绿；安装包 SHA-256 校验。
- 应用内检查更新指向本仓库。
