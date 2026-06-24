/// Broker 连接状态 + FarmStore + MqttRouter Providers
///
/// App 是纯 MQTT 客户端。Broker 健康由 MQTT keepalive + PINGREQ/PINGRESP 检测，
/// BrokerConnectionManager 负责自动重连（指数退避）。
///
/// Riverpod Provider 层次:
///   farmStoreProvider            ── 核心状态 Store（单例）
///   mqttTransportFactory         ── MqttTransportAdapter 工厂
///   brokerConnMgrProvider        ── BrokerConnectionManager（注入 factory）
///   brokerStateProvider          ── Stream<BrokerConnState>（UI 绑定）
///   farmMqttRouterProvider       ── FarmMqttRouter（自动 start/stop）
///   farmCommandGatewayProvider   ── FarmCommandGateway（从 Router 提取）
///   cameraServiceProvider        ── CameraService（MQTT 发命令 + HTTP 轮询帧）

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/broker_connection_manager.dart';
import '../../data/farm_command_gateway.dart';
import '../../data/farm_connection_monitor.dart';
import '../../data/farm_mqtt_router.dart';
import '../../data/camera_service.dart';
import '../../data/farm_hub.dart';
import '../../data/farm_store.dart';
import '../../data/mqtt_transport_impl.dart';
import '../../data/printer_discovery.dart';
import '../../data/unified_request_tracker.dart';
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
    final notifier = ref.read(printerRegistryProvider.notifier);
    for (final printer in store.allPrinters) {
      // 必须创建副本：Riverpod 的 select() 用 == 比较，
      // 同一个对象引用会被视为未变更，导致 widget 不重建
      notifier.addPrinter(printer);
    }
  });

  ref.onDispose(() => store.dispose());

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

/// 活跃的 Router 实例缓存（避免重复创建）
/// 使用模块级变量而非 StateProvider — 避免 Provider build 期间修改其他 Provider 违反 Riverpod 规则
FarmMqttRouter? _activeRouter;

/// FarmMqttRouter — 连接后自动创建、start、订阅通配符 topic
///
/// 依赖 brokerStateProvider（Stream）感知连接/断开变化。
/// 连接建立时自动 start() + startProbing()，断开时自动 stop()。
final farmMqttRouterProvider = Provider<FarmMqttRouter?>((ref) {
  final brokerState = ref.watch(brokerStateProvider).valueOrNull;
  final isConnected = brokerState?.isConnected ?? false;

  final manager = ref.watch(brokerConnMgrProvider);
  final transport = manager.transport;

  // 未连接或无 transport → 清理旧 Router
  if (!isConnected || transport == null) {
    if (_activeRouter != null) {
      _activeRouter!.stop(); // fire-and-forget
      _activeRouter = null;
    }
    return null;
  }

  // 已有活跃 Router → 复用
  if (_activeRouter != null) return _activeRouter;

  // 创建新 Router 并自动启动
  final store = ref.watch(farmStoreProvider);
  final router = FarmMqttRouter(store: store, transport: transport);
  _activeRouter = router;

  // 异步启动（不阻塞 Provider 返回）
  Future.microtask(() async {
    await router.start();
    router.startProbing();
  });

  ref.onDispose(() {
    router.stop();
    _activeRouter = null;
  });

  return router;
});

/// UnifiedRequestTracker — 从 Router 提取，供 BatchOperator 等使用
final unifiedTrackerProvider = Provider<UnifiedRequestTracker?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  return router?.tracker;
});

/// FarmCommandGateway — 从 Router 提取，供 BatchOperator 等使用
final farmCommandGatewayProvider = Provider<FarmCommandGateway?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  return router?.gateway;
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

/// FarmHub Provider — 群控总入口（入网/发现/生命周期）
final farmHubProvider = Provider<FarmHub>((ref) {
  final store = ref.watch(farmStoreProvider);
  final brokerConnMgr = ref.watch(brokerConnMgrProvider);
  final credentialStore = ref.watch(credentialStoreProvider);
  return FarmHub(
    store: store,
    brokerConnMgr: brokerConnMgr,
    discovery: PrinterDiscovery(),
    credentialStore: credentialStore,
  );
});
