/// FarmStore — 多设备状态聚合 (T4.2)
///
/// 设计原则:
/// - 单入口写入: 所有数据源只能往 FarmStore 写
/// - 时间戳保护: 解决 MQTT/HTTP 同时写入的竞争
/// - 中间件集中: 校验、合并、staleness、快照全在 FarmStore 内
/// - 批处理通知: 100ms 窗口合并通知，100 台打印机最多 10 次/秒 UI 重建
///
/// 数据流向:
///   MQTT +/status  ──→ onMqttStatus(sn, data, eventTime)
///   MQTT +/notif   ──→ onMqttNotification(sn, data)
///   HTTP 轮询      ──→ onHttpPollResult(sn, data, pollTime)
///   HTTP 失败      ──→ onHttpPollFailed(sn)
///   连接监控       ──→ forceOffline(sn, reason)
///   批量操作结果   ──→ onBatchResult(sn, result)

import 'dart:async';

import 'farm_printer_state.dart';
import 'printer_info.dart';

/// FarmStore 变更通知回调
typedef FarmStoreListener = void Function();

/// 农场状态存储
class FarmStore {
  /// 所有打印机: Map<SN, FarmPrinterState>
  final Map<String, FarmPrinterState> _printers = {};

  /// 外部监听器列表
  final List<FarmStoreListener> _listeners = [];

  /// 心跳回调（由 FarmConnectionMonitor 注入，用于被动心跳监测）
  void Function(String sn)? onHeartbeat;

  /// 去重统计
  int _dupCount = 0;
  DateTime _lastDupLog = DateTime.now();

  /// 批处理通知定时器
  Timer? _batchTimer;
  static const Duration _batchWindow = Duration(milliseconds: 100);

  /// 本批次内发生变更的打印机 SN（用于 Bridge 精确通知）
  final Set<String> _dirtySns = {};

  /// 获取本批次脏 SN 快照（Bridge 用它遍历而非 allPrinters）
  Set<String> get dirtySns => Set.unmodifiable(_dirtySns);

  /// 清空脏标记（Bridge 通知完毕后调用）
  void clearDirtySns() => _dirtySns.clear();

  // ═══════════════════════════════════════════════════════════
  // 写入方法 — 所有数据源唯一入口
  // ═══════════════════════════════════════════════════════════

  /// MQTT 状态推送（主力通道）
  ///
  /// [sn] 打印机序列号
  /// [status] 展开后的遥测数据
  /// [eventTime] 来自 Moonraker eventtime 字段的数据时间戳
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) {
    final now = DateTime.now();

    // 首次收到消息 → 自动注册（无需预先入网）
    final isNewDevice = !_printers.containsKey(sn);
    var printer = _printers[sn];
    if (printer == null) {
      print('[FarmStore] 🆕 自动注册新设备: $sn (MQTT auto-discover)');
      printer = FarmPrinterState.fromInfo(PrinterInfo(
        sn: sn,
        displayName: sn.substring(sn.length - 6), // 用 SN 后 6 位作为显示名
        ip: 'MQTT',
        port: 7125, // Moonraker HTTP API 端口，非 MQTT Broker 1883
        source: Source.mqtt,
      ));
      _printers[sn] = printer;
    }

    // 时间戳保护：MQTT 消息可能乱序到达
    if (eventTime != null && printer.lastDataTimestamp != null) {
      if (!eventTime.isAfter(printer.lastDataTimestamp!)) return;
    }

    // 记录上一个打印状态用于检测变更
    final previousPrintState = printer.printState?.value;
    final wasOffline = !printer.isOnline;

    final anythingChanged = printer.updateTelemetry(status, eventTime: eventTime);
    if (!anythingChanged) {
      // 值去重：设备每秒推但内容没变（正常行为，不是代码重复拿）
      _dupCount++;
      final now2 = DateTime.now();
      if (now2.difference(_lastDupLog).inSeconds >= 10) {
        print('[FarmStore] 🔁 10s 内去重 $_dupCount 条重复消息（值未变，设备持续推送）');
        _dupCount = 0;
        _lastDupLog = now2;
      }
      return;
    }

    printer.markFresh(Source.mqtt);

    // 新设备首次出现 → 快照
    if (isNewDevice) {
      printer.addSnapshot(FarmSnapshot(
        timestamp: now,
        reason: '设备自动发现',
        context: '首次通过 MQTT 状态消息发现设备',
        data: {'sn': sn},
      ));
    }

    // 从离线恢复 → 快照
    if (wasOffline) {
      printer.connectionState = FarmConnectionState.online;
      printer.addSnapshot(FarmSnapshot(
        timestamp: now,
        reason: '设备上线',
        context: 'MQTT 状态消息到达，设备恢复在线',
        data: {'sn': sn},
      ));
    }

    // 打印状态变更 → 快照
    final currentPrintState = printer.printState?.value;
    if (previousPrintState != null &&
        currentPrintState != null &&
        previousPrintState != currentPrintState) {
      printer.addSnapshot(FarmSnapshot(
        timestamp: now,
        reason: '打印状态变更',
        context: '$previousPrintState → $currentPrintState',
        data: {
          'from': previousPrintState,
          'to': currentPrintState,
        },
      ));
    }

    onHeartbeat?.call(sn); // 被动心跳：收到任何 MQTT 消息即证明在线
    _dirtySns.add(sn);
    _notify();
  }
  /// HTTP 轮询结果（降级通道）
  ///
  /// [pollTime] App 本地时钟的轮询时间，用于时间戳比较
  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 时间戳保护：HTTP 数据可能晚于 MQTT 数据
    if (printer.lastDataTimestamp != null && !pollTime.isAfter(printer.lastDataTimestamp!)) {
      return; // 丢弃比已有数据更旧的数据
    }

    printer.updateTelemetry(data, eventTime: pollTime);
    printer.markFresh(Source.http);

    onHeartbeat?.call(sn);
    _dirtySns.add(sn);
    _notify();
  }

  /// MQTT 通知（Last Will 遗嘱消息）
  void onMqttNotification(String sn, Map<String, dynamic> data) {
    // 首次收到消息 → 自动注册
    var printer = _printers[sn];
    if (printer == null) {
      printer = FarmPrinterState.fromInfo(PrinterInfo(
        sn: sn,
        displayName: sn.substring(sn.length - 6),
        ip: 'MQTT',
        port: 7125, // Moonraker HTTP API 端口，非 MQTT Broker 1883
        source: Source.mqtt,
      ));
      _printers[sn] = printer;
    }

    final event = data['server'] as String?;
    if (event == 'online') {
      printer.connectionState = FarmConnectionState.online;
      printer.markTelemetryStale(); // 等下一次状态推送刷新
    } else if (event == 'offline') {
      printer.connectionState = FarmConnectionState.offline;
      printer.markTelemetryStale();
      printer.addSnapshot(FarmSnapshot(
        timestamp: DateTime.now(),
        reason: 'mqtt_last_will_offline',
        data: data,
      ));
    }

    _dirtySns.add(sn);
    _dirtySns.add(sn);
    _notify();
  }

  /// HTTP 轮询单次失败
  ///
  /// 不直接改变状态 — 由 FarmConnectionMonitor 做累积判定。
  /// 单次失败可能是瞬时网络波动，不应立即标记离线。
  void onHttpPollFailed(String sn) {
    // 仅记录，由 FarmConnectionMonitor 累积判定
    // 可在未来添加连续失败计数器
  }

  /// 强制离线（连接监控触发）
  ///
  /// [reason] 离线原因: "heartbeat_timeout_65s" / "last_will_offline" 等
  void forceOffline(String sn, String reason) {
    final printer = _printers[sn];
    if (printer == null) return;

    printer.connectionState = FarmConnectionState.offline;
    printer.markTelemetryStale();
    printer.addSnapshot(FarmSnapshot(
      timestamp: DateTime.now(),
      reason: reason,
      data: {'previousState': printer.printState?.value},
    ));

    _dirtySns.add(sn);
    _notify();
  }

  /// 打印机注册
  void onPrinterRegistered(PrinterInfo info) {
    _printers[info.sn] = FarmPrinterState.fromInfo(info);
    _dirtySns.add(info.sn);
    _notify();
  }

  /// 打印机移除
  void onPrinterRemoved(String sn) {
    _printers.remove(sn);
    _dirtySns.add(sn);
    _notify();
  }

  /// 批量操作结果
  void onBatchResult(String sn, BatchResult result) {
    final printer = _printers[sn];
    if (printer == null) return;

    printer.lastBatchResult = result;
    if (!result.success) {
      printer.addSnapshot(FarmSnapshot(
        timestamp: DateTime.now(),
        reason: 'batch_${result.operation}_failed',
        context: result.error,
        data: {'operation': result.operation},
      ));
    }

    _dirtySns.add(sn);
    _notify();
  }

  /// 更新打印机状态（通用入口）
  void updatePrinter(String sn, FarmPrinterState Function(FarmPrinterState) updateFn) {
    final printer = _printers[sn];
    if (printer != null) {
      updateFn(printer);
      _dirtySns.add(sn);
      _notify();
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 读取方法
  // ═══════════════════════════════════════════════════════════

  /// 获取单台打印机状态
  FarmPrinterState? getPrinter(String sn) => _printers[sn];

  /// 所有打印机
  List<FarmPrinterState> get allPrinters => List.unmodifiable(_printers.values);

  /// 按群组筛选
  List<FarmPrinterState> getByGroup(String group) {
    return _printers.values.where((p) => p.group == group).toList();
  }

  /// MQTT 打印机
  List<FarmPrinterState> get mqttPrinters =>
      _printers.values.where((p) => p.isMqtt).toList();

  /// HTTP 降级打印机
  List<FarmPrinterState> get httpFallbackPrinters =>
      _printers.values.where((p) => p.isHttp).toList();

  // ═══════════════════════════════════════════════════════════
  // 统计
  // ═══════════════════════════════════════════════════════════

  int get count => _printers.length;
  int get onlineCount => _printers.values.where((p) => p.isOnline).length;
  int get printingCount => _printers.values.where((p) => p.isPrinting).length;
  int get mqttCount => _printers.values.where((p) => p.isMqtt).length;
  int get httpCount => _printers.values.where((p) => p.isHttp).length;
  int get httpPrintingCount =>
      _printers.values.where((p) => p.isHttp && p.isPrinting).length;

  // ═══════════════════════════════════════════════════════════
  // 持久化支持
  // ═══════════════════════════════════════════════════════════

  /// 从持久化存储加载打印机注册信息
  void loadFromRegistry(List<PrinterInfo> printers) {
    for (final info in printers) {
      if (!_printers.containsKey(info.sn)) {
        _printers[info.sn] = FarmPrinterState.fromInfo(info);
      }
    }
    _notify();
  }

  /// 导出当前所有打印机的注册信息（用于持久化）
  List<PrinterInfo> exportToRegistry() {
    return _printers.values.map((p) => PrinterInfo(
      sn: p.sn,
      displayName: p.displayName,
      ip: p.ip,
      port: p.port,
      group: p.group,
      source: p.source,
      model: p.model,
      firmwareVersion: p.firmwareVersion,
    )).toList();
  }

  // ═══════════════════════════════════════════════════════════
  // 通知机制（批处理）
  // ═══════════════════════════════════════════════════════════

  /// 添加监听器
  void addListener(FarmStoreListener listener) {
    _listeners.add(listener);
  }

  /// 移除监听器
  void removeListener(FarmStoreListener listener) {
    _listeners.remove(listener);
  }

  /// 批次合并通知
  ///
  /// 100 台打印机每秒 100 次 MQTT 更新 → 合并为最多 10 次 UI 重建/秒
  void _notify() {
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(_batchWindow, () {
        for (final listener in _listeners) {
          listener();
        }
        _batchTimer = null;
      });
    }
  }

  /// 立即通知（不等待批处理窗口，用于关键状态变更如离线、入网）
  void notifyImmediately() {
    _batchTimer?.cancel();
    _batchTimer = null;
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 释放资源
  void dispose() {
    _batchTimer?.cancel();
    _listeners.clear();
    _printers.clear();
  }
}
