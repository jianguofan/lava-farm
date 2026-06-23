/// Broker 连接状态 + FarmStore + MqttRouter Providers
///
/// App 是纯 MQTT 客户端。Broker 健康由 MQTT keepalive + PINGREQ/PINGRESP 检测，
/// BrokerConnectionManager 负责自动重连（指数退避）。
///
/// Riverpod Provider 层次:
///   farmStoreProvider         ── 核心状态 Store（单例）
///   mqttTransportFactory      ── MqttTransportAdapter 工厂
///   brokerConnMgrProvider     ── BrokerConnectionManager（注入 factory）
///   brokerStateProvider       ── Stream<BrokerConnState>（UI 绑定）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/broker_connection_manager.dart';
import '../../data/farm_connection_monitor.dart';
import '../../data/farm_mqtt_router.dart';
import '../../data/camera_service.dart';
import '../../data/farm_store.dart';
import '../../data/mqtt_transport_impl.dart';
import 'credential_store_provider.dart';
import 'printer_list_provider.dart';

/// MQTT Transport 工厂
final mqttTransportFactoryProvider =
    Provider<Future<MqttTransportAdapter> Function(BrokerConfig config)>((ref) {
  final factory = MqttTransportFactory();
  return (config) => factory.create(config);
});

/// FarmStore — 多设备状态聚合（单例）
final farmStoreProvider = Provider<FarmStore>((ref) {
  final store = FarmStore();

  // 桥接: FarmStore 变更 → 更新 PrinterRegistryNotifier（触发 UI 重建）
  store.addListener(() {
    // 从 FarmStore 同步所有打印机状态到 Riverpod StateNotifier
    final notifier = ref.read(printerRegistryProvider.notifier);
    // 有打印机的直接写入（不做全量 diff，FarmStore 的批处理通知已控制频率）
    for (final printer in store.allPrinters) {
      notifier.addPrinter(printer);
    }
  });

  return store;
});

/// BrokerConnectionManager 单例 Provider
final brokerConnMgrProvider = Provider<BrokerConnectionManager>((ref) {
  final credentialStore = ref.watch(credentialStoreProvider);
  final mqttFactory = ref.watch(mqttTransportFactoryProvider);
  return BrokerConnectionManager(
    credentialStore: credentialStore,
    mqttFactory: mqttFactory,
  );
});

/// FarmMqttRouter — 连接后创建，订阅通配符 topic，消息路由到 FarmStore
final farmMqttRouterProvider = Provider<FarmMqttRouter?>((ref) {
  final manager = ref.watch(brokerConnMgrProvider);
  final transport = manager.transport;
  if (!manager.isConnected || transport == null) return null;

  final store = ref.watch(farmStoreProvider);
  return FarmMqttRouter(store: store, transport: transport);
});

/// Broker 连接状态流 Provider
final brokerStateProvider = StreamProvider<BrokerConnState>((ref) {
  final manager = ref.watch(brokerConnMgrProvider);
  return manager.stateStream;
});

/// 便捷：是否已连接
final isBrokerConnectedProvider = Provider<bool>((ref) {
  final state = ref.watch(brokerStateProvider).valueOrNull;
  return state?.isConnected ?? false;
});

/// BrokerHealthMonitor Provider
final brokerHealthMonitorProvider = Provider<BrokerHealthMonitor>((ref) {
  final manager = ref.watch(brokerConnMgrProvider);
  return BrokerHealthMonitor(
    pingFn: () => manager.ping(),
    onUnhealthy: () {},
    onFailure: (_) {},
  );
});

/// Broker 健康状态 Provider
final brokerHealthStateProvider = Provider<BrokerHealthState>((ref) {
  final monitor = ref.watch(brokerHealthMonitorProvider);
  final failures = monitor.consecutiveFailures;
  if (!monitor.isHealthy && failures >= 3) return BrokerHealthState.unhealthy;
  if (failures > 0) return BrokerHealthState.degraded;
  return BrokerHealthState.healthy;
});

/// HTTP 降级打印机数量
final httpFallbackCountProvider = StateProvider<int>((ref) => 0);

/// CameraService Provider — MQTT 发命令 + HTTP 轮询帧画面
final cameraServiceProvider = Provider<CameraService?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  if (router == null) return null;
  return CameraService(router: router);
});
