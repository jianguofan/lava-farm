/// FarmMqttRouter — MQTT 消息路由器
///
/// 职责:
/// - 连接到 Broker 后订阅通配符 topic (+/status, +/notification)
/// - 解析收到的消息并路由到 FarmStore
/// - 接收侧: _onMessage() 将 response 消息分派给 UnifiedRequestTracker.complete()
/// - 发送侧: 委托 FarmCommandGateway.sendToOne() / sendToMany()
/// - 主动探活：周期性发送 server.info 确认设备在线
///
/// 架构:
///   FarmMqttRouter
///     ├── UnifiedRequestTracker   (共享 — 发收双方的桥梁)
///     │     ├── track()           (发送侧调用)
///     │     └── complete()        (接收侧调用)
///     └── FarmCommandGateway      (发送侧 — sendToOne / sendToMany)
///
/// 数据流:
///   MQTT +/status        → _handleStatus(sn, payload)    → FarmStore.onMqttStatus
///   MQTT +/notification  → _handleNotification(sn, data) → FarmStore.onMqttNotification
///   MQTT {SN}/response   → _tracker.complete(sn, json)

import 'dart:async';
import 'dart:convert';

import 'broker_connection_manager.dart';
import 'farm_command_gateway.dart';
import 'farm_printer_state.dart';
import 'farm_store.dart';
import 'printer_info.dart';
import 'unified_request_tracker.dart';

/// MQTT 消息路由器
class FarmMqttRouter {
  final FarmStore _store;
  final MqttTransportAdapter _transport;

  /// 统一请求追踪器（发收双方共享）
  final UnifiedRequestTracker _tracker;

  /// 指令网关（发送侧）
  late final FarmCommandGateway _gateway;

  /// 主动探活定时器
  Timer? _probeTimer;
  /// 元数据刷新间隔（心跳由 FarmConnectionMonitor 通过 +/status 流驱动）
  static const _probeInterval = Duration(minutes: 10);

  /// 防重入：start() 只能调用一次
  bool _started = false;

  /// MQTT 消息流订阅（stop 时取消，防止断连重连后重复监听）
  StreamSubscription<MqttMessage>? _messageSub;

  FarmMqttRouter({
    required FarmStore store,
    required MqttTransportAdapter transport,
  })  : _store = store,
        _transport = transport,
        _tracker = UnifiedRequestTracker() {
    _gateway = FarmCommandGateway(
      tracker: _tracker,
      transport: transport,
    );
  }

  /// 暴露 gateway 供外部使用（BatchOperator 等需要 sendToMany）
  FarmCommandGateway get gateway => _gateway;

  /// 暴露 tracker 供外部查询
  UnifiedRequestTracker get tracker => _tracker;

  // ═══════════════════════════════════════════════════════════
  // 启动 / 停止
  // ═══════════════════════════════════════════════════════════

  /// 订阅通配符 topic，开始接收所有设备消息
  ///
  /// 防重入：多次调用只有第一次生效，避免消息重复处理。
  Future<void> start() async {
    if (_started) return;
    _started = true;

    // 监听所有消息（保存订阅句柄，stop 时取消）
    _messageSub = _transport.messageStream.listen(_onMessage);

    // 通配符订阅 — 一条订阅覆盖全部设备
    await _transport.subscribe('+/status', qos: 1);
    await _transport.subscribe('+/notification', qos: 1);
  }

  /// 启动元数据定期刷新
  ///
  /// 心跳检测已由 FarmConnectionMonitor（被动监听 +/status 流）承担。
  /// 此方法仅负责刷新低频变化的元数据（版本号、主机名、IP 等）。
  /// 首次连接时立即刷新一次，后续每 10 分钟刷新。
  void startProbing() {
    _probeTimer?.cancel();
    _probeAll();
    _probeTimer = Timer.periodic(_probeInterval, (_) => _probeAll());
  }

  /// 停止路由
  Future<void> stop() async {
    _started = false;
    _probeTimer?.cancel();
    _probeTimer = null;
    _messageSub?.cancel();
    _messageSub = null;
    _tracker.cancelAll();
    _seenTopics.clear();
  }

  // ═══════════════════════════════════════════════════════════
  // 单控 — 委托给 FarmCommandGateway
  // ═══════════════════════════════════════════════════════════

  /// 向指定打印机发送 JSON-RPC 命令（MQTT 通道）
  ///
  /// 返回 [CommandResult]，超时或失败时 success=false。
  Future<CommandResult> sendCommand(
    String sn,
    String method, [
    Map<String, dynamic>? params,
  ]) {
    return _gateway.sendToOne(
      sn: sn,
      method: method,
      params: params,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 群控 — 委托给 FarmCommandGateway
  // ═══════════════════════════════════════════════════════════

  /// 向多台打印机发送同一条命令
  ///
  /// 返回 [BatchHandle]，支持实时进度流和等待全部结果。
  BatchHandle sendToMany({
    required List<String> sns,
    required String method,
    Map<String, dynamic>? params,
    Duration timeout = defaultRequestTimeout,
    int maxConcurrency = 20,
  }) {
    return _gateway.sendToMany(
      sns: sns,
      method: method,
      params: params,
      timeout: timeout,
      maxConcurrency: maxConcurrency,
    );
  }

  // ═══════════════════════════════════════════════════════════
  // 主动探活
  // ═══════════════════════════════════════════════════════════

  /// 对所有已知设备发送 server.info 查询确认在线状态
  Future<void> _probeAll() async {
    final devices = _store.allPrinters;
    if (devices.isEmpty) return;

    for (final device in devices) {
      // 不阻塞，逐个异步探测
      _probeDevice(device.sn);
    }
  }

  /// 启动时仅获取 LAN IP（轻量探测）
  ///
  /// 全量状态（printer.objects.query）在用户点击详情时按需拉取。
  /// 心跳由 FarmConnectionMonitor 通过被动监听 +/status 消息流驱动。
  Future<void> _probeDevice(String sn) async {
    try {
      final sysInfo = await sendCommand(sn, 'machine.system_info');
      if (sysInfo.success && sysInfo.data != null) {
        _extractAndUpdateIp(sn, sysInfo.data!);
      }
    } catch (_) {
      // 探测失败不处理
    }
  }

  /// 按需拉取单台设备全量状态（点击详情时调用）
  ///
  /// 发送 printer.objects.query 获取完整 Moonraker 对象树，
  /// 同时拉取 server.info + printer.info 元数据。
  Future<void> fetchFullState(String sn) async {
    try {
      // ── 1. printer.objects.query → 全量基线状态 ──
      final fullState = await sendCommand(sn, 'printer.objects.query');
      if (fullState.success && fullState.data != null) {
        final data = fullState.data!;
        final status = data['status'] as Map<String, dynamic>?;
        DateTime? eventTime;
        if (data['eventtime'] is num) {
          eventTime = DateTime.fromMillisecondsSinceEpoch(
            ((data['eventtime'] as num) * 1000).toInt(),
          );
        }

        if (status != null) {
          final expanded = <String, dynamic>{};
          _expandMap(status, '', expanded);

          _store.updatePrinter(sn, (p) {
            p.updateTelemetry(expanded, eventTime: eventTime);
            p.markFresh(Source.mqtt);
            p.connectionState = FarmConnectionState.online;
            p.lastStatusTime = DateTime.now();
            p.addRawMessage(data);
            p.updateRawStateSnapshot(expanded);
            return p;
          });

          _store.notifyImmediately();
        }
      }

      // ── 2. server.info → Moonraker 版本、klippy 状态 ──
      final serverInfo = await sendCommand(sn, 'server.info');
      if (serverInfo.success && serverInfo.data != null) {
        final data = serverInfo.data!;
        _store.updatePrinter(sn, (p) {
          p.updateDeviceInfo(
            klippyState: data['klippy_state']?.toString(),
            moonrakerVersion: data['moonraker_version']?.toString(),
            apiVersionString: data['api_version_string']?.toString(),
          );
          p.addSnapshot(FarmSnapshot(
            timestamp: DateTime.now(),
            reason: '设备信息更新',
            context: 'Moonraker ${data['moonraker_version'] ?? "?"} · Klippy ${data['klippy_state'] ?? "?"}',
            data: data,
          ));
          return p;
        });
      }

      // ── 3. printer.info → 主机名、软件版本、CPU ──
      final printerInfo = await sendCommand(sn, 'printer.info');
      if (printerInfo.success && printerInfo.data != null) {
        final data = printerInfo.data!;
        _store.updatePrinter(sn, (p) {
          p.hostname = data['hostname']?.toString() ?? p.hostname;
          p.softwareVersion = data['software_version']?.toString() ?? p.softwareVersion;
          p.cpuInfo = data['cpu_info']?.toString() ?? p.cpuInfo;
          if (p.displayName == null || p.displayName!.startsWith(p.sn.substring(p.sn.length - 6))) {
            p.displayName = data['hostname']?.toString() ?? p.displayName;
          }
          return p;
        });
      }
    } catch (_) {
      // 拉取失败不影响已有状态
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 消息处理（接收侧）
  // ═══════════════════════════════════════════════════════════

  /// 活跃 topic 前缀集合（用于诊断哪些设备在发消息）
  final Set<String> _seenTopics = {};
  DateTime _lastTopicReport = DateTime.now();

  void _onMessage(MqttMessage msg) {
    final topic = msg.topic;
    final sn = _extractSn(topic);
    final raw = utf8.decode(msg.payload);

    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;

      if (topic.endsWith('/status')) {
        // 首次见到某个 SN 的 status 消息时打印
        if (_seenTopics.add(sn)) {
          print('[Router] 📡 首次收到设备消息: $sn (topic: $topic)');
          print('[Router]     已注册设备: ${_store.allPrinters.map((p) => p.sn).toList()}');
        }
        // 每 30 秒汇总一次
        final now = DateTime.now();
        if (now.difference(_lastTopicReport).inSeconds >= 30) {
          print('[Router] 📊 活跃设备 (${_seenTopics.length}): ${_seenTopics.toList().take(10).join(", ")}${_seenTopics.length > 10 ? "..." : ""}');
          _lastTopicReport = now;
        }
        _handleStatus(sn, json);
      } else if (topic.endsWith('/notification')) {
        _handleNotification(sn, json);
      } else if (topic.endsWith('/response')) {
        _tracker.complete(sn, json);
      }
    } catch (e) {
      print('[Router] ❌ 消息处理失败: topic=$topic sn=$sn error=$e');
      print('[Router]     payload 前 200 字符: ${raw.length > 200 ? raw.substring(0, 200) : raw}');
    }
  }

  /// 处理状态推送
  ///
  /// Moonraker notify_status_update 格式:
  ///   {"jsonrpc":"2.0", "method":"notify_status_update",
  ///    "params":[{"extruder":{"temperature":210.5},...}, 1718700000.0]}
  void _handleStatus(String sn, Map<String, dynamic> json) {
    // 提取状态数据
    Map<String, dynamic>? status;
    DateTime? eventTime;

    if (json['params'] is List && (json['params'] as List).isNotEmpty) {
      status = (json['params'] as List)[0] as Map<String, dynamic>?;
    }

    // 提取 eventtime（UNIX 时间戳，秒）
    if (json['params'] is List && (json['params'] as List).length >= 2) {
      final rawTime = (json['params'] as List)[1];
      if (rawTime is num) {
        eventTime = DateTime.fromMillisecondsSinceEpoch(
          (rawTime * 1000).toInt(),
        );
      }
    }

    if (status == null) return;

    // 展开嵌套字段: {"extruder": {"temperature": 210.5}}
    // 变为: {"extruder.temperature": 210.5}
    final expanded = <String, dynamic>{};
    _expandMap(status, '', expanded);

    _store.onMqttStatus(sn, expanded, eventTime: eventTime);

    // 收集原始消息和完整状态快照（用于调试/分析）
    _store.updatePrinter(sn, (p) {
      p.addRawMessage(json);
      p.updateRawStateSnapshot(expanded);
      return p;
    });

    // MQTT 自动发现的设备没有真实 IP → 后台子网扫描解析
    final printer = _store.getPrinter(sn);
    if (printer != null && printer.ip == 'MQTT') {
      _resolveIpInBackground(sn);
    }
  }

  /// 后台通过 MQTT machine.system_info 解析打印机真实 LAN IP
  ///
  /// MQTT 通道已通，直接问设备要网络信息，无需子网扫描。
  /// 异步执行，防止对同一台设备重复请求。
  final Set<String> _resolvingSns = {};

  void _resolveIpInBackground(String sn) {
    if (_resolvingSns.contains(sn)) return;
    _resolvingSns.add(sn);

    Future.microtask(() async {
      try {
        final result = await sendCommand(sn, 'machine.system_info');
        if (result.success && result.data != null) {
          _extractAndUpdateIp(sn, result.data!);
        }
      } catch (_) {} finally {
        _resolvingSns.remove(sn);
      }
    });
  }

  /// 从 machine.system_info 响应中提取 IP 并更新到打印机状态
  ///
  /// 响应格式:
  ///   {"system_info": {"network": {"eth0": {"ip_addresses": [
  ///     {"family": "ipv4", "address": "172.18.0.150", "is_link_local": false}
  ///   ]}}}}
  void _extractAndUpdateIp(String sn, Map<String, dynamic> data) {
    final sysInfo = data['system_info'] as Map<String, dynamic>?;
    if (sysInfo == null) return;

    final network = sysInfo['network'] as Map<String, dynamic>?;
    if (network == null) return;

    // 遍历所有网络接口（eth0 / wlan0 / ...），找第一个非 link-local 的 IPv4
    for (final entry in network.entries) {
      final iface = entry.value as Map<String, dynamic>?;
      if (iface == null) continue;
      final addresses = iface['ip_addresses'] as List?;
      if (addresses == null) continue;

      for (final addr in addresses) {
        if (addr is Map<String, dynamic> &&
            addr['family'] == 'ipv4' &&
            addr['is_link_local'] != true) {
          final ip = addr['address'] as String?;
          if (ip != null && ip != '127.0.0.1') {
            _store.updatePrinter(sn, (p) {
              p.ip = ip;
              return p;
            });
            return; // 找到第一个有效 IP 即停止
          }
        }
      }
    }
  }

  /// 处理通知（Last Will 遗嘱消息）
  ///
  /// 格式: {"server":"online"} 或 {"server":"offline"}
  void _handleNotification(String sn, Map<String, dynamic> json) {
    _store.onMqttNotification(sn, json);
  }

  // ═══════════════════════════════════════════════════════════
  // 工具方法
  // ═══════════════════════════════════════════════════════════

  /// 从 topic 提取 SN（topic 格式: "SN/type" 或 "+/type"）
  String _extractSn(String topic) {
    final parts = topic.split('/');
    return parts.first;
  }

  /// 展开嵌套 Map: {"a":{"b":1}} → {"a.b":1}
  void _expandMap(Map<String, dynamic> source, String prefix,
      Map<String, dynamic> target) {
    for (final entry in source.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        _expandMap(entry.value as Map<String, dynamic>, key, target);
      } else {
        target[key] = entry.value;
      }
    }
  }
}
