# Spec: 单设备详情与控制

## ADDED Requirements

### Requirement: Printer detail shall support common remote operations

系统 SHALL 在单设备详情页提供暂停、继续、停止、设置温度和发送 G-code 操作。

#### Scenario: Pause one printer from detail page

- **GIVEN** 设备正在打印
- **WHEN** 操作员在详情页点击暂停
- **THEN** 系统 SHALL 向该设备下发暂停命令
- **AND** UI SHALL 展示命令结果。
