# Quota Bar v1.5.6

## 修复（Codex 数据可信度）

- **登录过期检测**：`~/.codex/auth.json` 的 id_token 过期时，Codex 卡片明确显示"Codex 登录已过期，请运行 codex login"——过期凭证下官方接口可能返回失真数据（如恒 0%），不再静默展示。
- **ProLite 口径说明**：OpenAI 官方接口对 ProLite 套餐不提供已用百分比（恒报 0%）。检测到此情况时卡片注明"实际额度以 ChatGPT App 内为准"，不再伪装成"剩 100%"。

## 背景

实测（2026-10-11）：账号一致、重度使用、token 刷新后，`account/rateLimits/read` 对 ProLite 仍返回 primary.usedPercent=0——服务端口径如此，非本应用可修复。
