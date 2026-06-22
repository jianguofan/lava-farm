/// Broker 部署模式
///
/// lava-farm 统一使用 Docker 部署 Mosquitto Broker。
/// 不再维护内嵌子进程模式（已被 DockerBrokerManager 替代）。

/// Docker Mosquitto Broker 状态
enum DockerBrokerState {
  /// Docker 不可用（未安装或未启动）
  unavailable,

  /// Broker 容器未创建（首次启动）
  notInitialized,

  /// Broker 容器已停止
  stopped,

  /// Broker 容器正在启动
  starting,

  /// Broker 容器运行中
  running,

  /// Broker 容器异常
  error,
}
