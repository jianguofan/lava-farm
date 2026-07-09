# Tasks: 桌面控制中心

- [x] 明确生产/评估模式入口和提示。（`BrokerMode`、`DeploymentModeBanner` 已实现）
- [x] 完善 Broker 设置页连接测试。（`BrokerSetupPage` 已实现）
- [x] 完善 Broker 状态指示和错误提示。（`BrokerStatusIndicator` 已实现）
- [ ] 规划系统托盘、窗口管理、开机自启实现。
- [ ] 规划 Windows/macOS/Linux 安装包。
- [x] 确认日志页覆盖关键诊断信息。（`LogViewerPage` + `FarmLogger` 已实现）
- [x] 验证 App 重启后可恢复 Broker 连接和设备列表。（`farm_store_test` 覆盖 `exportToRegistry → loadFromRegistry` 恢复打印机列表；`broker_connection_manager_test` 覆盖 `connectFromSavedCredentials` 凭据恢复连接）
