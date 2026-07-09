# Tasks: 预打印配置页

- [x] 将 `BatchPrintPage` 改为四步流程。
- [x] 接入 `ProductDefinition` 作为 Step1。
- [x] 实现颜色/耗材确认 Step2。
- [x] 复用 `printerListProvider` 实现设备过滤与多选 Step3。
- [x] 复用 `BatchPrintCoordinator`、`FileUploader`、`BatchOperator` 执行 Step4。
- [x] 增加结果面板和投产历史持久化。（`ProductionRecord` + `ProductionHistoryRepository` JSON 持久化 + 结果面板 + 投产历史弹窗，重试复用同一记录 id）
- [ ] 验证：选择产品 → 选择设备 → 批量投产 → 查看结果。（需手工联调真实设备）
