# Spec: 桌面控制中心

## ADDED Requirements

### Requirement: Desktop shell shall expose Broker connectivity

系统 SHALL 在桌面壳层中显示 Broker 连接状态，并提供 Broker 配置入口。

#### Scenario: Broker disconnects

- **WHEN** App 与 Broker 断开连接
- **THEN** 系统 SHALL 在 UI 中显示断连状态
- **AND** 系统 SHALL 提供重新配置或重连入口。
