# Spec: 全屏控制面板

## ADDED Requirements

### Requirement: Dashboard shall monitor farm status

系统 SHALL 在设备信息页展示总数、在线、运行中、空闲、完成等统计，并以卡片网格展示设备状态。

#### Scenario: Operator views 100 printers

- **WHEN** 系统存在 100 台设备
- **THEN** 控制面板 SHALL 在 3 秒内完成首屏渲染
- **AND** 设备状态刷新 P99 SHALL 不超过 2 秒。

### Requirement: Batch control drawer shall confirm operations

系统 SHALL 提供右侧批量控制抽屉，用于选择操作类型、填写参数、确认已选设备并提交。

#### Scenario: Set bed temperature for selected printers

- **GIVEN** 操作员已选择多台设备
- **WHEN** 操作员选择“设置热床温度”并输入温度
- **THEN** 系统 SHALL 显示已选设备表
- **AND** 提交后 SHALL 对每台设备下发设置命令
- **AND** 单台失败 SHALL 不阻塞其它设备。
