/// 核心 Providers: FarmStore、Broker、MQTT Router、Command Gateway
///
/// Provider 层次:
///   farmStoreProvider            ── 核心状态 Store（单例）+ 版本号驱动 UI
///   farmStoreVersionProvider     ── 版本号（UI watch 此值触发重建）
///   mqttTransportFactoryProvider ── MqttTransportAdapter 工厂
///   brokerConnMgrProvider        ── BrokerConnectionManager
///   brokerStateProvider          ── Stream<BrokerConnState>
///   farmMqttRouterProvider       ── FarmMqttRouter（自动 start/stop）
///   farmCommandGatewayProvider   ── FarmCommandGateway
///   cameraServiceProvider        ── CameraService
///   farmHubProvider              ── FarmHub（群控总入口）
///   batchPrintCoordinatorProvider── BatchPrintCoordinator

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/batch_print_coordinator.dart';
import '../../data/batch_operator.dart';
import '../../data/broker_connection_manager.dart';
import '../../data/farm_logger.dart';
import '../../data/farm_command_gateway.dart';
import '../../data/farm_connection_monitor.dart';
import '../../data/farm_mqtt_router.dart';
import '../../data/camera_service.dart';
import '../../data/thumbnail_service.dart';
import '../services/farm_hub.dart';
import '../../data/farm_store.dart';
import '../../data/mqtt_transport_impl.dart';
import '../../data/printer_discovery.dart';
import '../../data/unified_request_tracker.dart';
import 'credential_store_provider.dart';

// ═══════════════════════════════════════════════════════════
// MQTT Transport
// ═══════════════════════════════════════════════════════════

final mqttTransportFactoryProvider =
    Provider<Future<MqttTransportAdapter> Function(BrokerConfig config)>((ref) {
  final factory = MqttTransportFactory();
  return (config) => factory.create(config);
});

// ═══════════════════════════════════════════════════════════
// FarmStore — 唯一状态存储（单例）
// ═══════════════════════════════════════════════════════════

/// FarmStore 实例 Provider（长生命周期单例）
final farmStoreProvider = Provider<FarmStore>((ref) {
  final store = FarmStore();

  // FarmStore 变更 → 触发 farmStoreVersionProvider 自增，驱动 UI 重建
  store.onVersionChanged = () {
    // 安全读取：Provider 销毁后不更新
    try {
      ref.read(farmStoreVersionProvider.notifier).state++;
    } catch (_) {
      // Provider 已被 dispose，忽略
    }
  };

  ref.onDispose(() {
    store.dispose();
    FarmLogger.instance.dispose();
  });

  return store;
});

/// 版本号 Provider — UI 通过 watch 此值感知 FarmStore 变更
///
/// 使用方式:
/// ```dart
/// // 派生 Provider 中
/// ref.watch(farmStoreVersionProvider);        // 感知任何打印机变化
/// final store = ref.read(farmStoreProvider);  // 读取具体数据
/// ```
final farmStoreVersionProvider = StateProvider<int>((ref) => 0);

// ═══════════════════════════════════════════════════════════
// Broker 连接
// ═══════════════════════════════════════════════════════════

final brokerConnMgrProvider = Provider<BrokerConnectionManager>((ref) {
  final credentialStore = ref.watch(credentialStoreProvider);
  final mqttFactory = ref.watch(mqttTransportFactoryProvider);
  return BrokerConnectionManager(
    credentialStore: credentialStore,
    mqttFactory: mqttFactory,
  );
});

final brokerStateProvider = StreamProvider<BrokerConnState>((ref) {
  final manager = ref.watch(brokerConnMgrProvider);
  return manager.stateStream;
});

final isBrokerConnectedProvider = Provider<bool>((ref) {
  final state = ref.watch(brokerStateProvider).valueOrNull;
  return state?.isConnected ?? false;
});

// ═══════════════════════════════════════════════════════════
// MQTT Router（自动 start/stop）
// ═══════════════════════════════════════════════════════════

/// 活跃 Router 缓存（Provider 重建时复用同一实例，避免重复创建）
/// 模块级变量是此处正确的选择：
///   - Provider.create 内不能修改其他 Provider 的状态
///   - Router 生命周期与 Broker 连接生命周期一致（单例语义）
FarmMqttRouter? _activeRouter;

final farmMqttRouterProvider = Provider<FarmMqttRouter?>((ref) {
  final brokerState = ref.watch(brokerStateProvider).valueOrNull;
  final isConnected = brokerState?.isConnected ?? false;

  final manager = ref.watch(brokerConnMgrProvider);
  final transport = manager.transport;

  // 未连接或无 transport → 清理旧 Router
  if (!isConnected || transport == null) {
    if (_activeRouter != null) {
      _activeRouter!.stop();
      _activeRouter = null;
    }
    return null;
  }

  // 已有活跃 Router → 复用
  if (_activeRouter != null) return _activeRouter;

  // 创建新 Router
  final store = ref.read(farmStoreProvider);
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

// ═══════════════════════════════════════════════════════════
// 命令网关 & 请求追踪
// ═══════════════════════════════════════════════════════════

final unifiedTrackerProvider = Provider<UnifiedRequestTracker?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  return router?.tracker;
});

final farmCommandGatewayProvider = Provider<FarmCommandGateway?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  return router?.gateway;
});

// ═══════════════════════════════════════════════════════════
// Broker 健康监控
// ═══════════════════════════════════════════════════════════

final brokerHealthMonitorProvider = Provider<BrokerHealthMonitor>((ref) {
  final manager = ref.watch(brokerConnMgrProvider);
  return BrokerHealthMonitor(
    pingFn: () => manager.ping(),
    onUnhealthy: () {},
    onFailure: (_) {},
  );
});

final brokerHealthStateProvider = Provider<BrokerHealthState>((ref) {
  final monitor = ref.watch(brokerHealthMonitorProvider);
  final failures = monitor.consecutiveFailures;
  if (!monitor.isHealthy && failures >= 3) return BrokerHealthState.unhealthy;
  if (failures > 0) return BrokerHealthState.degraded;
  return BrokerHealthState.healthy;
});

// ═══════════════════════════════════════════════════════════
// HTTP 降级计数
// ═══════════════════════════════════════════════════════════

final httpFallbackCountProvider = StateProvider<int>((ref) => 0);

// ═══════════════════════════════════════════════════════════
// Camera Service
// ═══════════════════════════════════════════════════════════

final cameraServiceProvider = Provider<CameraService?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  if (router == null) return null;
  return CameraService(router: router);
});

// ═══════════════════════════════════════════════════════════
// Thumbnail Service
// ═══════════════════════════════════════════════════════════

final thumbnailServiceProvider = Provider<ThumbnailService?>((ref) {
  final router = ref.watch(farmMqttRouterProvider);
  if (router == null) return null;
  return ThumbnailService(router: router);
});

// ═══════════════════════════════════════════════════════════
// FarmHub — 群控总入口
// ═══════════════════════════════════════════════════════════

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

// ═══════════════════════════════════════════════════════════
// BatchPrintCoordinator
// ═══════════════════════════════════════════════════════════

final batchPrintCoordinatorProvider = Provider<BatchPrintCoordinator>((ref) {
  final gateway = ref.watch(farmCommandGatewayProvider);
  return BatchPrintCoordinator(gateway: gateway);
});

// ═══════════════════════════════════════════════════════════
// BatchOperator — 批量操作引擎（暂停/取消/急停/GCode/温度）
// ═══════════════════════════════════════════════════════════

final batchOperatorProvider = Provider<BatchOperator>((ref) {
  final store = ref.watch(farmStoreProvider);
  final gateway = ref.watch(farmCommandGatewayProvider);
  return BatchOperator(store: store, gateway: gateway);
});
