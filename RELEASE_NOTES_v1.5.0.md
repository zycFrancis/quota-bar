# Quota Bar v1.5.0 — 窗口接力（Auto Re-arm）

5 小时用量窗口的重置是“从首次调用开始计时”的滚动窗口：刷新后若无人调用，新窗口不会开始。
本版新增**窗口接力**：窗口一刷新就自动发一个最小请求（约 16 token），把新窗口立刻点着，
让 GLM / Kimi / Claude 三家的 5 小时窗口保持连续滚动——你回到电脑前的等待时间始终最短。

## 使用

设置 → 常规 → 窗口接力：总开关（默认关闭）+ 三家分开关 + 点火模型（可改）+ 立即点火按钮。
开启后卡片脚注会显示「接力 · HH:mm 点火」；失败连续两次以上发 macOS 通知。

## 供应商与点火方式

| 服务 | 点火请求 | 重置时间来源 |
|---|---|---|
| GLM Coding Plan | `open.bigmodel.cn/api/anthropic/v1/messages`（默认 `glm-4.5-air`） | 官方 monitor 接口 `nextResetTime` |
| Kimi For Coding | `api.kimi.com/coding/v1/messages`（默认 `kimi-k2-turbo-preview`，复用 kimi-code 凭据） | 官方 `/coding/v1/usages` `limit_5h.reset_time` |
| Claude（订阅） | 清洗环境变量的 `claude -p hi --model haiku`（强制官方 OAuth，cc-switch 切到第三方端点时自动跳过并提示） | 被限流时解析 CLI 输出中的 `resets` 时刻 |

## 安全与稳健

- 保险丝：任意两次点火尝试至少间隔 10 分钟，状态机异常也不会刷请求。
- 失败退避 30s/2m/10m；GLM/Kimi 点火后回读官方接口采用服务端权威重置时间。
- 睡眠唤醒后自动补上错过的点火；Claude 被限流（非错误）时按解析出的重置时刻等待。
- 查询侧依旧零模型调用；接力开启后每次窗口刷新产生 1 个约 16 token 的请求。
- 公开仓库默认关闭该功能，升级不会自动开始点火。

## 其他

- 修复：release workflow 的 Publish 步骤现在仅在 tag 触发时执行，workflow_dispatch 分支验证构建只产出 artifact。
