# Quota Bar v1.5.7

## 修复

- Codex 登录过期检测改用 access_token（约 10 天寿命）：此前误用 1 小时寿命的 id_token，正常登录状态下也会常年误报"登录已过期"。仅 access_token 真正过期时才提示 `codex login`。
