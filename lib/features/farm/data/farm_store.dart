/// FarmStore — 多设备状态聚合 (T4.2)
///
/// 单入口写入、时间戳保护、批处理通知、dirty tracking。
///
/// Riverpod 集成:
///   farmStoreProvider     → FarmStore 实例（长生命周期）
///   farmStoreVersionProvider → int 版本号（UI watch 此 Provider 触发重建）
///
/// 数据流向:
///   MQTT +/status  ──→ onMqttStatus(sn, data, eventTime)
///   MQTT +/notif   ──→ onMqttNotification(sn, data)
///   HTTP 轮询      ──→ onHttpPollResult(sn, data, pollTime)
///   HTTP 失败      ──→ onHttpPollFailed(sn)
///   连接监控       ──→ forceOffline(sn, reason)
///   批量操作结果   ──→ onBatchResult(sn, result)

import 'dart:async';

import '../domain/services/printer_state_machine.dart';
import 'farm_printer_state.dart';
import 'printer_info.dart';

/// FarmStore 变更通知回调
typedef FarmStoreListener = void Function();

/// 农场状态存储
///
/// 所有数据源通过此单入口写入。100ms 批处理窗口合并通知。
/// 不再有独立的 Riverpod StateNotifier 副本 — 通过 version 机制
/// 直接驱动 UI 重建（见 farmStoreVersionProvider）。
class FarmStore {
  /// 所有打印机: Map<SN, FarmPrinterState>
  final Map<String, FarmPrinterState> _printers = {};

  /// 外部监听器列表
  final List<FarmStoreListener> _listeners = [];

  /// 当版本号变化时调用（由 Provider 注入，驱动 UI 重建）
  void Function()? onVersionChanged;

  /// 心跳回调（由 FarmConnectionMonitor 注入）
  void Function(String sn)? onHeartbeat;

  /// 去重统计
  int _dupCount = 0;
  DateTime _lastDupLog = DateTime.now();

  /// 批处理通知定时器
  Timer? _batchTimer;
  static const Duration _batchWindow = Duration(milliseconds: 100);

  /// 本批次内发生变更的打印机 SN（用于精确更新）
  final Set<String> _dirtySns = {};

  /// 获取本批次脏 SN 快照
  Set<String> get dirtySns => Set.unmodifiable(_dirtySns);

  /// 单调递增的版本号（每次通知时 +1）
  int version = 0;

  /// 清空脏标记（外部可在通知后调用）
  void clearDirtySns() => _dirtySns.clear();

  // ═══════════════════════════════════════════════════════════
  // 写入方法 — 所有数据源唯一入口
  // ═══════════════════════════════════════════════════════════

  /// MQTT 状态推送（主力通道）
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) {
    final now = DateTime.now();

    // 首次收到消息 → 自动注册
    final isNewDevice = !_printers.containsKey(sn);
    var printer = _printers[sn];
    if (printer == null) {
      print('[FarmStore] 🆕 自动注册新设备: $sn (MQTT auto-discover)');
      printer = FarmPrinterState.fromInfo(
        PrinterStateMachine.createAutoDiscoveredInfo(sn),
      );
      _printers[sn] = printer;
    }

    // 时间戳保护：MQTT 消息可能乱序到达
    if (!PrinterStateMachine.isTimestampValid(eventTime, printer.lastDataTimestamp)) {
      return;
    }

    // 记录上一个状态用于检测变更
    final wasOffline = !printer.isOnline;

    final anythingChanged = printer.updateTelemetry(status, eventTime: eventTime);
    if (!anythingChanged) {
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

    // 状态转换检测 → 领域服务
    final snapshots = PrinterStateMachine.detectTransitions(
      sn: sn,
      status: status,
      previousState: isNewDevice ? null : printer,
      now: now,
      isNewDevice: isNewDevice,
      wasOffline: wasOffline,
    );
    for (final snapshot in snapshots) {
      printer.addSnapshot(snapshot);
    }

    // 从离线恢复 → 更新连接状态
    if (wasOffline) {
      printer.connectionState = FarmConnectionState.online;
    }

    onHeartbeat?.call(sn);
    _dirtySns.add(sn);
    _notify();
  }

  /// HTTP 轮询结果（降级通道）
  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 时间戳保护
    if (!PrinterStateMachine.isTimestampValid(pollTime, printer.lastDataTimestamp)) {
      return;
    }

    printer.updateTelemetry(data, eventTime: pollTime);
    printer.markFresh(Source.http);

    onHeartbeat?.call(sn);
    _dirtySns.add(sn);
    _notify();
  }

  /// MQTT 通知（Last Will 遗嘱消息）
  void onMqttNotification(String sn, Map<String, dynamic> data) {
    var printer = _printers[sn];
    if (printer == null) {
      printer = FarmPrinterState.fromInfo(
        PrinterStateMachine.createAutoDiscoveredInfo(sn),
      );
      _printers[sn] = printer;
    }

    final event = data['server'] as String?;
    if (event == 'online') {
      printer.connectionState = FarmConnectionState.online;
      printer.markTelemetryStale();
    } else if (event == 'offline') {
      printer.connectionState = FarmConnectionState.offline;
      printer.markTelemetryStale();
      printer.addSnapshot(PrinterStateMachine.createOfflineSnapshot(
        now: DateTime.now(),
        reason: 'mqtt_last_will_offline',
        previousState: {'previousState': printer.printState?.value},
      ));
    }

    _dirtySns.add(sn);
    _notify();
  }

  /// HTTP 轮询单次失败（仅记录，由 FarmConnectionMonitor 做累积判定）
  void onHttpPollFailed(String sn) {
    // 单次失败不直接标记离线
  }

  /// 强制离线（连接监控触发）
  void forceOffline(String sn, String reason) {
    final printer = _printers[sn];
    if (printer == null) return;

    printer.connectionState = FarmConnectionState.offline;
    printer.markTelemetryStale();
    printer.addSnapshot(PrinterStateMachine.createOfflineSnapshot(
      now: DateTime.now(),
      reason: reason,
      previousState: {'previousState': printer.printState?.value},
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
      printer.addSnapshot(PrinterStateMachine.createBatchFailureSnapshot(
        now: DateTime.now(),
        operation: result.operation,
        error: result.error,
      ));
    }

    _dirtySns.add(sn);
    _notify();
  }

  /// 更新打印机状态（通用入口 — 原地修改模式）
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

  FarmPrinterState? getPrinter(String sn) => _printers[sn];

  List<FarmPrinterState> get allPrinters => List.unmodifiable(_printers.values);

  List<FarmPrinterState> getByGroup(String group) {
    return _printers.values.where((p) => p.group == group).toList();
  }

  List<FarmPrinterState> get mqttPrinters =>
      _printers.values.where((p) => p.isMqtt).toList();

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

  void loadFromRegistry(List<PrinterInfo> printers) {
    for (final info in printers) {
      if (!_printers.containsKey(info.sn)) {
        _printers[info.sn] = FarmPrinterState.fromInfo(info);
      }
    }
    _notify();
  }

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
  // 通知机制（批处理 + Riverpod 集成）
  // ═══════════════════════════════════════════════════════════

  void addListener(FarmStoreListener listener) {
    _listeners.add(listener);
  }

  void removeListener(FarmStoreListener listener) {
    _listeners.remove(listener);
  }

  /// 批次合并通知
  ///
  /// 100 台打印机每秒 100 次 MQTT 更新 → 合并为最多 10 次 UI 重建/秒。
  /// 同时触发 Riverpod 版本号变更（驱动 farmStoreVersionProvider）。
  void _notify() {
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(_batchWindow, () {
        version++;
        // Riverpod 通知
        onVersionChanged?.call();
        // 旧式监听器通知
        for (final listener in _listeners) {
          listener();
        }
        _batchTimer = null;
      });
    }
  }

  /// 立即通知（不等待批处理窗口）
  void notifyImmediately() {
    _batchTimer?.cancel();
    _batchTimer = null;
    version++;
    onVersionChanged?.call();
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 释放资源
  void dispose() {
    _batchTimer?.cancel();
    _listeners.clear();
    _printers.clear();
    onVersionChanged = null;
    onHeartbeat = null;
  }
}
