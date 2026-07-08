# Spec: 异常置顶提示

## ADDED Requirements

### Requirement: Active alerts shall be pinned

系统 SHALL 将未解决的重要异常置顶显示在控制面板顶部。

#### Scenario: Printer enters error state

- **WHEN** 某设备状态变为错误
- **THEN** 系统 SHALL 在 1 分钟内生成告警
- **AND** 控制面板 SHALL 置顶显示该告警
- **AND** 对应设备卡片 SHALL 明显突出。
