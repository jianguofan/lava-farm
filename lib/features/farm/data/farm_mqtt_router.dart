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

import 'broker_connection_manager.dart';
import 'farm_command_gateway.dart';
import 'farm_logger.dart';
import 'farm_printer_state.dart';
import 'farm_store.dart';
import 'mqtt_message_processor.dart';
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

  /// IP 解析定时器 — 对在线但无有效 IP 的打印机定期重试
  Timer? _ipResolveTimer;
  static const _ipResolveInterval = Duration(seconds: 30);

  /// SN → 最后已知有效 IP 缓存（IP 解析成功自动写入，供离线/降级场景查询）
  final Map<String, String> ipCache = {};

  /// IP 解析连续失败计数（SN → 失败次数），达到 _maxIpFailures 后暂停重试
  final Map<String, int> _ipFailures = {};
  static const int _maxIpFailures = 3;

  /// 防重入：start() 只能调用一次
  bool _started = false;

  /// MQTT 消息后台处理器（persistent isolate：UTF-8解码 + JSON解析 + Map展平）
  late final MqttMessageProcessor _processor;

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
    _processor = MqttMessageProcessor(
      onBatchProcessed: _onBatchProcessed,
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
    await _transport.subscribe('+/status', qos: 0); // 状态幂等，丢了下一秒还会来，省 PUBACK 开销
    await _transport.subscribe('+/notification', qos: 1);

    // 对已注册设备发送 printer.objects.subscribe 激活状态推送
    // Snapmaker 的 status_interval 配置已让打印机自动推送大部分状态，
    // 但 subscribe 确保所有需要的对象都被推送
    for (final device in _store.allPrinters) {
      _subscribeDeviceObjects(device.sn);
    }
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

    // 启动 IP 解析定时器：每 30s 对在线但无有效 IP 的打印机重试
    _ipResolveTimer?.cancel();
    resolveIpsForUnknownDevices();
    _ipResolveTimer = Timer.periodic(_ipResolveInterval, (_) => resolveIpsForUnknownDevices());
  }

  /// 停止路由
  Future<void> stop() async {
    _started = false;
    _probeTimer?.cancel();
    _probeTimer = null;
    _ipResolveTimer?.cancel();
    _ipResolveTimer = null;
    _messageSub?.cancel();
    _messageSub = null;
    _processor.dispose();
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
    // 已有有效 IP、设备不在线、或连续失败达上限则跳过
    final printer = _store.allPrinters.where((p) => p.sn == sn).firstOrNull;
    if (printer == null || !printer.isOnline || printer.hasValidIp) return;
    if ((_ipFailures[sn] ?? 0) >= _maxIpFailures) return;

    try {
      final sysInfo = await sendCommand(sn, 'machine.system_info');
      if (sysInfo.success && sysInfo.data != null) {
        _ipFailures.remove(sn);
        _extractAndUpdateIp(sn, sysInfo.data!);
      } else {
        _ipFailures[sn] = (_ipFailures[sn] ?? 0) + 1;
      }
    } catch (_) {
      _ipFailures[sn] = (_ipFailures[sn] ?? 0) + 1;
    }
  }

  /// 按需拉取单台设备全量状态（点击详情时调用）
  ///
  /// 发送 printer.objects.query 获取完整 Moonraker 对象树，
  /// 同时拉取 server.info + printer.info 元数据。
  Future<void> fetchFullState(String sn) async {
    print('[Router] 🔍 fetchFullState($sn) 开始...');
    try {
      // ── 1. printer.objects.query → 全量基线状态（13 核心对象） ──
      final fullState = await sendCommand(sn, 'printer.objects.query', {
        'objects': {
          'extruder': null,
          'heater_bed': null,
          'print_stats': null,
          'job': null,
          'virtual_sdcard': null,
          'toolhead': null,
          'fan': null,
          'display_status': null,
          'gcode_move': null,
          'idle_timeout': null,
          'file_metadata': null,
          'webhooks': null,
          'filament_detect': null,
        },
      });
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
          FarmMqttRouter.expandMap(status, '', expanded);

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

      // ── 2-4. 静态元数据（缓存 1 小时，首次必拉） ──
      final printer = _store.getPrinter(sn);
      final metaAge = printer?.serverInfoFetchedAt != null
          ? DateTime.now().difference(printer!.serverInfoFetchedAt!)
          : const Duration(hours: 999);
      final needMetaRefresh = metaAge > const Duration(hours: 1);

      if (needMetaRefresh) {
        // server.info → Moonraker 版本、klippy 状态
        final serverInfo = await sendCommand(sn, 'server.info');
        if (serverInfo.success && serverInfo.data != null) {
          final data = serverInfo.data!;
          _store.updatePrinter(sn, (p) {
            p.updateDeviceInfo(
              klippyState: data['klippy_state']?.toString(),
              moonrakerVersion: data['moonraker_version']?.toString(),
              apiVersionString: data['api_version_string']?.toString(),
            );
            return p;
          });
        }

        // printer.info → 主机名、软件版本、CPU
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

        // machine.system_info → LAN IP
        final sysInfo = await sendCommand(sn, 'machine.system_info');
        if (sysInfo.success && sysInfo.data != null) {
          _extractAndUpdateIp(sn, sysInfo.data!);
        }
      } else {
        print('[Router] ⏭️ $sn 元数据缓存命中（${metaAge.inMinutes}min ago），跳过 server/printer/system_info');
      }
      // ── 5. printer.objects.subscribe → 激活持续状态推送 ──
      await _subscribeDeviceObjects(sn);

      print('[Router] ✅ fetchFullState($sn) 完成');
    } catch (e) {
      print('[Router] ❌ fetchFullState($sn) 失败: $e');
    }
  }

  /// 向设备发送 printer.objects.subscribe，激活指定对象的状态推送
  ///
  /// Moonraker 的 subscribe 是幂等的 —— 再次调用会替换而非累积订阅列表。
  /// 因此始终发送，确保对象列表变更后打印机端立即生效。
  Future<void> _subscribeDeviceObjects(String sn) async {
    try {
      await sendCommand(sn, 'printer.objects.subscribe', {
        'objects': {
          // 核心 13 对象：去掉 motion_report（打印时高频）+ machine_state_manager（同高频）
          'extruder': null,
          'heater_bed': null,
          'print_stats': null,
          'job': null,
          'virtual_sdcard': null,
          'toolhead': null,
          'fan': null,
          'display_status': null,
          'gcode_move': null,
          'idle_timeout': null,
          'file_metadata': null,
          'webhooks': null,
          'filament_detect': null,
        },
      });
    } catch (_) {
      // subscribe 失败不阻塞
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

    // 诊断日志（轻量，仅 topic 前缀检查）
    if (topic.endsWith('/status')) {
      if (_seenTopics.add(sn)) {
        print('[Router] 📡 首次收到设备消息: $sn (topic: $topic)');
        print('[Router]     已注册设备: ${_store.allPrinters.map((p) => p.sn).toList()}');
      }
      final now = DateTime.now();
      if (now.difference(_lastTopicReport).inSeconds >= 30) {
        print('[Router] 📊 活跃设备 (${_seenTopics.length}): ${_seenTopics.toList().take(10).join(", ")}${_seenTopics.length > 10 ? "..." : ""}');
        _lastTopicReport = now;
      }
    }

    // 交给后台 isolate 异步处理（UTF-8解码 + JSON解析 + Map展平）
    _processor.enqueue(topic, msg.payload);

    // 响应消息需要低延迟 → 立即发送当前批次
    if (topic.endsWith('/response')) {
      _processor.flush();
    }
  }

  /// isolate 处理完毕后回调（在主 isolate 执行）
  void _onBatchProcessed(List<ProcessedMessage> batch) {
    // 诊断日志：确认 isolate → 主 isolate 数据流是否通畅
    if (_seenTopics.length <= 2) {
      print('[Router] 📦 收到 isolate 批次: ${batch.length} 条');
      for (final m in batch) {
        print('[Router]    topic=${m.topic} sn=${m.sn} hasExpanded=${m.expandedStatus != null}');
      }
    }
    for (final msg in batch) {
      try {
        if (msg.topic.endsWith('/status')) {
          _handleStatusProcessed(msg);
          FarmLogger.instance.logStatusReceived(msg.sn, msg.expandedStatus ?? {},
              eventTime: msg.eventTime);
        } else if (msg.topic.endsWith('/notification')) {
          _handleNotification(msg.sn, msg.rawJson);
          FarmLogger.instance.logNotificationReceived(msg.sn, msg.rawJson);
        } else if (msg.topic.endsWith('/response')) {
          _tracker.complete(msg.sn, msg.rawJson);
          FarmLogger.instance.logCommandResponse(msg.sn, msg.rawJson);
        }
      } catch (e) {
        print('[Router] ❌ 消息分发失败: topic=${msg.topic} sn=${msg.sn} error=$e');
      }
    }
  }

  /// 处理 isolate 预处理的状态推送（expandedStatus + eventTime 已在 isolate 中计算好）
  void _handleStatusProcessed(ProcessedMessage msg) {
    if (msg.expandedStatus == null) {
      print('[Router] ⚠️ status 消息无 expandedStatus: sn=${msg.sn} topic=${msg.topic}');
      return;
    }

    final isNewDevice = _store.getPrinter(msg.sn) == null;

    _store.onMqttStatus(msg.sn, msg.expandedStatus!, eventTime: msg.eventTime);

    // 收集原始消息和完整状态快照
    _store.updatePrinter(msg.sn, (p) {
      p.addRawMessage(msg.rawJson);
      p.updateRawStateSnapshot(msg.expandedStatus!);
      return p;
    });

    if (isNewDevice) {
      _subscribeDeviceObjects(msg.sn);
    }

    final printer = _store.getPrinter(msg.sn);
    if (printer != null && !printer.hasValidIp) {
      resolveIpInBackground(msg.sn);
    }
  }

  /// 定期对在线但无有效 IP 的打印机重试 IP 解析
  ///
  /// 对在线但无有效 IP 的打印机立即发起 machine.system_info 查询
  ///
  /// 目标：MQTT 自动发现的设备初始没有 IP，需要在打印机上线后
  /// 持续重试获取直到成功。UI 可在页面加载时主动调用以缩短等待时间。
  /// 内部有去重（同一 SN 同时只发一次请求），可安全重复调用。
  void resolveIpsForUnknownDevices() {
    for (final printer in _store.allPrinters) {
      final sn = printer.sn;
      if (!printer.isOnline) continue;
      if (printer.hasValidIp) continue; // 缓存命中：已有有效 IP，跳过
      if (_resolvingSns.contains(sn)) continue;
      if ((_ipFailures[sn] ?? 0) >= _maxIpFailures) continue; // 连续失败超限，跳过

      resolveIpInBackground(sn);
    }
  }

  /// 通过 MQTT machine.system_info 解析打印机真实 LAN IP
  ///
  /// MQTT 通道已通，直接问设备要网络信息，无需子网扫描。
  /// 异步 fire-and-forget，防止对同一台设备重复请求（_resolvingSns 去重）。
  final Set<String> _resolvingSns = {};

  void resolveIpInBackground(String sn) {
    if (_resolvingSns.contains(sn)) return;
    // 连续失败达上限则暂停重试
    if ((_ipFailures[sn] ?? 0) >= _maxIpFailures) return;
    _resolvingSns.add(sn);

    Future.microtask(() async {
      try {
        final result = await sendCommand(sn, 'machine.system_info');
        if (result.success && result.data != null) {
          _ipFailures.remove(sn); // 成功则清零
          _extractAndUpdateIp(sn, result.data!);
        } else {
          _ipFailures[sn] = (_ipFailures[sn] ?? 0) + 1;
        }
      } catch (_) {
        _ipFailures[sn] = (_ipFailures[sn] ?? 0) + 1;
      } finally {
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
            ipCache[sn] = ip; // 写入缓存
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

  /// 展开嵌套 Map（用于 fetchFullState 等低频路径，仍在主 isolate 执行）
  static void expandMap(Map<String, dynamic> source, String prefix,
      Map<String, dynamic> target) {
    for (final entry in source.entries) {
      final key = prefix.isEmpty ? entry.key : '$prefix.${entry.key}';
      if (entry.value is Map<String, dynamic>) {
        expandMap(entry.value as Map<String, dynamic>, key, target);
      } else {
        target[key] = entry.value;
      }
    }
  }
}
