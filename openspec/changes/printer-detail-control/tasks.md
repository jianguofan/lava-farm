# Tasks: 单设备详情与控制

- [x] 梳理 `PrinterDetailPage` 现有布局。
- [x] 增强设备状态、进度、温度展示。
- [x] 增加 30 分钟温度曲线。（`FarmPrinterState.tempHistory` 5s 节流采样 + `_TemperatureChartPainter` CustomPaint 曲线；`temperature_history_test.dart` 覆盖采样/节流/裁剪）
- [x] 接入暂停/继续/停止/温度/G-code 控制。
- [x] 增加任务日志时间线。
- [x] 增加耗材余量和低余量提示。（`_FilamentSection` 按 mm→g 换算消耗量，匹配产品估算余量，<10% 触发"耗材不足"红框警示）
- [x] 整合摄像头占位或现有 camera view。
- [ ] 验证单设备远程操作 P99 ≤ 3 秒。（需真实设备手工压测）
