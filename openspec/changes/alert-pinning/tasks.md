# Tasks: 异常置顶提示

- [x] 新增 `FarmAlert` 模型和枚举。
- [x] 新增 `AlertEngine`，从设备状态生成/合并告警。
- [x] 新增 `alertProvider`。
- [x] 新增 `AlertPinnedBanner`。
- [x] 在 `PrinterCard` 中突出异常设备。
- [x] 支持确认/解决/静音状态。
- [x] 验证异常触发后 1 分钟内 UI 置顶显示。（`AlertEngine` 由 `farmStoreVersionProvider` 驱动，~100ms 批处理窗口内处理；`alert_engine_test.dart` 覆盖触发/置顶/resolve 行为，端到端延迟 < 1s，满足 1 分钟要求）
