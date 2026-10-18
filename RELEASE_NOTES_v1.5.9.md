# Quota Bar v1.5.9

## 修复

- 发布流水线可观测性：publish 步骤加 `set -x` 并移除 `continue-on-error`。此前该步骤出现零输出即退出的静默失败（run 显示绿色但 Release 未创建，v1.5.8 即靠 artifact 手动补发），现在失败会让 run 变红，且逐命令回显可直接定位到出错命令。
- 发布失败根因修复：publish 步骤查找的 notes 文件名公式 `RELEASE_NOTES_$version.md` 缺 v 前缀，与仓库 v1.4.1 以来的 `RELEASE_NOTES_v*.md` 命名不符，导致每次发版的 publish 必挂；本轮经 set -x 定位后已改为 `RELEASE_NOTES_v$version.md`。

本版无功能变更，功能面与 v1.5.8（Devin 额度 provider）一致。
