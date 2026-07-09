# Tasks: 全屏控制面板

## 1. 主界面布局

- [x] 在 `FarmDashboardPage` 增加"设备信息 / 产品信息"导航入口。
- [x] 保持 `StatsBar`、筛选器、`PrinterGrid` 作为设备信息主视图。
- [x] 调整布局以匹配参考图的全屏控制面板密度。

## 2. 批量控制抽屉

- [x] 新增 `BatchControlDrawer`。
- [x] 从 `BatchToolbar` 或设备选择状态打开右侧抽屉。
- [x] 展示操作类型卡片、参数输入、已选设备表。
- [x] 提交时调用 `BatchOperator` 并显示结果。

## 3. 批量命令补齐

- [x] 补齐 `BatchAction.resume`。
- [x] 补齐 `BatchAction.setBedTemp` / `setNozzleTemp` 的区分。
- [x] 在 `BatchOperator` 中确认或新增 `batchSetBedTemp`。
- [x] 定义"停止并清盘"的设备命令策略。

## 4. 验证

- [x] `flutter analyze`（无新增 error/warning，仅遗留 info 级提示）
- [x] `flutter test`（87 项全部通过）
- [ ] 手工选择多台设备，验证抽屉提交和失败汇总。
