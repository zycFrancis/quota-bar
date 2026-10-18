# Quota Bar v1.5.9

## 修复

- 发布流水线可观测性：publish 步骤加 `set -x` 并移除 `continue-on-error`。此前该步骤曾出现零输出即退出的静默失败（run 显示绿色但 Release 未创建，v1.5.8 即靠 artifact 手动补发），现在失败会让 run 变红，且逐命令回显可直接定位到出错命令。

本版无功能变更，功能面与 v1.5.8（Devin 额度 provider）一致。
