/// Broker 连接管理器
///
/// T1.3: 管理到外部 Mosquitto Broker 的 MQTT 连接
///
/// 职责:
/// - 连接/断开外部 Broker（使用 MqttTransport）
/// - 自动重连（指数退避: 2s → 4s → 8s → ... → 30s max）
/// - 连接状态流 (BrokerConnState)
/// - 配合 BrokerHealthMonitor 做假活检测
///
/// 与旧版 MqttBrokerManager 的差异:
///   旧版: 管理 Mosquitto 子进程（Process.start / kill）
///   新版: 连接已有的外部 Broker（MqttTransport.connect / disconnect）

import 'dart:async';
import 'dart:math';

import 'credential_store.dart';

/// Broker 连接状态
enum BrokerConnState {
  /// 未连接
  disconnected,

  /// 正在连接中
  connecting,

  /// 已连接
  connected,

  /// 降级（Broker 可达但响应异常，如 PING 超时）
  degraded,

  /// 错误（连接被拒绝、认证失败等不可恢复的错误）
  error,
}

/// 扩展
extension BrokerConnStateDisplay on BrokerConnState {
  bool get isConnected => this == BrokerConnState.connected;
  bool get isDegraded => this == BrokerConnState.degraded;
  bool get isError => this == BrokerConnState.error;

  String get label {
    switch (this) {
      case BrokerConnState.disconnected: return '断开';
      case BrokerConnState.connecting:   return '连接中';
      case BrokerConnState.connected:    return '已连接';
      case BrokerConnState.degraded:     return '降级';
      case BrokerConnState.error:        return '错误';
    }
  }
}

/// Broker 连接配置
class BrokerConfig {
  final String host;
  final int port;
  final String username;
  final String password;

  const BrokerConfig({
    required this.host,
    this.port = 1883,
    required this.username,
    required this.password,
  });
}

/// Broker 连接管理器
///
/// 使用示例:
/// ```dart
/// final manager = BrokerConnectionManager(
///   credentialStore: credentialStore,
///   mqttTransportFactory: (config) => MqttTransport(config),
/// );
///
/// // 监听状态
/// manager.stateStream.listen((state) => print('Broker: ${state.label}'));
///
/// // 连接
/// await manager.connect(
///   host: '192.168.1.100',
///   port: 1883,
///   username: 'lava_app',
///   password: '...',
/// );
/// ```
class BrokerConnectionManager {
  final CredentialStore _credentialStore;

  /// MQTT Transport 工厂（由调用方注入，避免直接依赖 lava_device_sdk）
  final Future<MqttTransportAdapter> Function(BrokerConfig config) _mqttFactory;

  MqttTransportAdapter? _transport;
  Timer? _reconnectTimer;
  Timer? _healthCheckTimer;
  int _reconnectAttempt = 0;
  BrokerConfig? _lastConfig;

  // ── 状态管理 ──
  // broadcast + onListen replay：新订阅者通过 microtask 立即收到当前状态
  late final StreamController<BrokerConnState> _stateController;
  Stream<BrokerConnState> get stateStream => _stateController.stream;
  BrokerConnState _state = BrokerConnState.disconnected;
  BrokerConnState get state => _state;

  BrokerConnectionManager({
    required CredentialStore credentialStore,
    required Future<MqttTransportAdapter> Function(BrokerConfig config) mqttFactory,
  })  : _credentialStore = credentialStore,
        _mqttFactory = mqttFactory {
    _stateController = StreamController<BrokerConnState>.broadcast(
      onListen: () {
        final currentState = _state;
        // microtask 延迟：避免在 listen() 回调中同步 add 导致 Riverpod 重入
        Future.microtask(() {
          if (!_stateController.isClosed) {
            _stateController.add(currentState);
          }
        });
      },
    );
  }

  /// 是否已连接
  bool get isConnected => _state == BrokerConnState.connected;

  /// 当前 Broker 连接配置（用于入网时生成打印机 MQTT 配置）
  BrokerConfig? get currentConfig => _lastConfig;

  /// 当前 Transport（连接成功后可用，用于 FarmMqttRouter 订阅 topic）
  MqttTransportAdapter? get transport => _transport;

  // ═══════════════════════════════════════════════════════════
  // 公共 API
  // ═══════════════════════════════════════════════════════════

  /// 连接到外部 Broker
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    print('[ConnMgr] connect() 开始: $host:$port user=$username passLen=${password.length}');
    _updateState(BrokerConnState.connecting);
    _lastConfig = BrokerConfig(
      host: host, port: port, username: username, password: password,
    );
    _reconnectAttempt = 0;

    try {
      print('[ConnMgr] 调用 mqttFactory...');
      _transport = await _mqttFactory(_lastConfig!);
      print('[ConnMgr] Transport 创建成功, 调用 transport.connect()...');
      await _transport!.connect();
      print('[ConnMgr] transport.connect() 成功!');

      // 注入非预期断开回调：TCP 断开时立即感知并触发重连（不等 15s 健康检查）
      _transport!.onDisconnected = () {
        print('[ConnMgr] ⚠️ transport 非预期断开，立即触发重连');
        _updateState(BrokerConnState.disconnected);
        _scheduleReconnect();
      };

      _updateState(BrokerConnState.connected);
      _startHealthCheck();
    } catch (e, st) {
      print('[ConnMgr] ❌ 连接失败: $e');
      print('[ConnMgr] 异常类型: ${e.runtimeType}');
      print('[ConnMgr] isAuthError=${_isAuthError(e)}');
      _updateState(_isAuthError(e) ? BrokerConnState.error : BrokerConnState.disconnected);
      // 认证错误不重连
      if (!_isAuthError(e)) {
        _scheduleReconnect();
      }
      rethrow;
    }
  }

  /// 从安全存储加载凭据并连接
  Future<bool> connectFromSavedCredentials() async {
    final creds = await _credentialStore.loadBrokerCredentials();
    if (creds == null) return false;

    try {
      await connect(
        host: creds.host,
        port: creds.port,
        username: creds.username,
        password: creds.password,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 断开连接
  Future<void> disconnect() async {
    _cancelTimers();
    _reconnectAttempt = 0;

    try {
      await _transport?.disconnect();
    } catch (_) {
      // 断开失败不影响状态
    } finally {
      _transport = null;
    }

    _updateState(BrokerConnState.disconnected);
  }

  /// MQTT PING 检测（供 BrokerHealthMonitor 调用）
  Future<bool> ping() async {
    if (_transport == null) return false;
    try {
      await _transport!.ping();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 释放资源
  Future<void> dispose() async {
    await disconnect();
    await _stateController.close();
  }

  // ═══════════════════════════════════════════════════════════
  // 自动重连
  // ═══════════════════════════════════════════════════════════

  /// 调度自动重连（指数退避）
  void _scheduleReconnect() {
    if (_state == BrokerConnState.error) return; // 认证错误不重连
    if (_lastConfig == null) return;

    _cancelReconnect();
    final delay = _calculateBackoff(_reconnectAttempt);
    _reconnectTimer = Timer(delay, () async {
      if (_state == BrokerConnState.connected) return;
      _reconnectAttempt++;

      try {
        await connect(
          host: _lastConfig!.host,
          port: _lastConfig!.port,
          username: _lastConfig!.username,
          password: _lastConfig!.password,
        );
      } catch (_) {
        _scheduleReconnect(); // 继续重试
      }
    });
  }

  /// 指数退避: 2, 4, 8, 16, 30, 30, ... (max 30s)
  Duration _calculateBackoff(int attempt) {
    const maxSeconds = 30;
    const baseSeconds = 2;
    final seconds = min(baseSeconds * pow(2, attempt).toInt(), maxSeconds);
    return Duration(seconds: seconds);
  }

  void _cancelReconnect() {
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
  }

  // ═══════════════════════════════════════════════════════════
  // 健康检测
  // ═══════════════════════════════════════════════════════════

  void _startHealthCheck() {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => _performHealthCheck(),
    );
  }

  Future<void> _performHealthCheck() async {
    if (_state != BrokerConnState.connected) return;

    // 检查 1: 数据新鲜度 — 超过 30s 没收到任何消息，连接很可能已死
    final lastMsg = _transport?.lastMessageTime;
    if (lastMsg != null) {
      final staleness = DateTime.now().difference(lastMsg);
      if (staleness.inSeconds > 30) {
        print('[ConnMgr] ⚠️ 数据断流 ${staleness.inSeconds}s，标记 degraded 并触发重连');
        _updateState(BrokerConnState.degraded);
        _scheduleReconnect();
        return;
      }
    }

    // 检查 2: 主动 ping — 验证底层 MQTT 连接状态
    final pong = await ping();
    if (!pong) {
      _updateState(BrokerConnState.degraded);
      _scheduleReconnect();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 内部
  // ═══════════════════════════════════════════════════════════

  void _updateState(BrokerConnState newState) {
    if (_state == newState) return;
    _state = newState;
    if (!_stateController.isClosed) {
      _stateController.add(newState);
    }
  }

  void _cancelTimers() {
    _cancelReconnect();
    _healthCheckTimer?.cancel();
    _healthCheckTimer = null;
  }

  /// 判断是否为认证错误（不可恢复，不触发重连）
  bool _isAuthError(Object e) {
    final msg = e.toString().toLowerCase();
    return msg.contains('not authorised') ||
        msg.contains('bad username') ||
        msg.contains('access denied') ||
        msg.contains('auth');
  }
}

/// MQTT Transport 适配器接口
///
/// 解耦 BrokerConnectionManager 与具体 MQTT 实现。
/// 实际实现由 lava_device_sdk 的 MqttTransport 提供。
abstract class MqttTransportAdapter {
  /// 连接到 Broker
  Future<void> connect();

  /// 断开连接
  Future<void> disconnect();

  /// MQTT PING 请求（实际网络往返检测，非仅状态查询）
  Future<void> ping();

  /// 订阅 topic
  Future<void> subscribe(String topic, {int qos = 1});

  /// 发布消息
  Future<void> publish(String topic, List<int> payload, {int qos = 1});

  /// 消息流
  Stream<MqttMessage> get messageStream;

  /// 底层 TCP 非预期断开回调（keepalive 超时 / TCP RST 等）
  /// BrokerConnectionManager 在 connect() 后注入，用于立即触发重连
  void Function()? onDisconnected;

  /// 最近一次收到消息的时间（由 _onUpdates 更新）
  DateTime? lastMessageTime;
}

/// MQTT 消息
class MqttMessage {
  final String topic;
  final List<int> payload;
  final int qos;
  final bool retain;

  const MqttMessage({
    required this.topic,
    required this.payload,
    this.qos = 1,
    this.retain = false,
  });
}
