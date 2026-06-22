/// 农场打印机状态模型 (T4.1)
///
/// 完整实现 FarmPrinterState，包含:
/// - 身份信息
/// - 通信模式（MQTT / HTTP）
/// - 实时遥测 (Staleable 新鲜度标记)
/// - 累积指标（增量计算）
/// - 数据版本（时间戳保护）
/// - 批量操作结果
/// - 快照历史

import 'printer_info.dart';

/// 带新鲜度标记的值包装器
///
/// 当打印机断连时，所有遥测标记为 stale，
/// UI 可据此显示灰色数值或 "(过期)" 标识。
class Staleable<T> {
  final T value;
  final bool isStale;
  final DateTime? staleSince;

  const Staleable(this.value, {this.isStale = false, this.staleSince});

  /// 标记为过期
  Staleable<T> markStale() => Staleable<T>(value,
      isStale: true, staleSince: staleSince ?? DateTime.now());

  /// 更新值（重置过期标记）
  Staleable<T> update(T newValue) =>
      Staleable<T>(newValue, isStale: false, staleSince: null);

  @override
  String toString() => 'Staleable($value, stale: $isStale)';
}

/// 批量操作结果
class BatchResult {
  final String printerSn;
  final bool success;
  final String operation; // "pause", "cancel", "emergency_stop", "gcode", etc.
  final Duration duration;
  final String? error;

  const BatchResult({
    required this.printerSn,
    required this.success,
    required this.operation,
    required this.duration,
    this.error,
  });
}

/// 农场快照（用于问题排查）
class FarmSnapshot {
  final DateTime timestamp;
  final String reason;
  final String? context;
  final Map<String, dynamic> data;

  const FarmSnapshot({
    required this.timestamp,
    required this.reason,
    this.context,
    required this.data,
  });
}

/// 农场打印机状态
class FarmPrinterState {
  // ── 身份 (永不清) ──
  final String sn;
  String? displayName;
  String ip;
  int port;
  String? group;
  String? model;
  String? firmwareVersion;

  // ── 通信模式 ──
  Source source;
  FarmConnectionState connectionState;

  // ── 实时遥测 (Staleable) ──
  Staleable<double>? nozzleTemp;
  Staleable<double>? nozzleTarget;
  Staleable<double>? bedTemp;
  Staleable<double>? bedTarget;
  Staleable<String>? printState;     // "standby" | "printing" | "paused" | "complete" | "error"
  Staleable<double>? progress;       // 0.0 ~ 1.0
  Staleable<String>? currentFile;
  Staleable<int>? layerNum;
  Staleable<int>? totalLayers;
  Staleable<double>? estimatedTime;  // 预估剩余时间 (秒)

  // ── 累积指标（增量累加） ──
  double? totalDuration;
  double? filamentUsed;
  double? _lastReportedDuration;

  // ── 数据版本（保护 MQTT/HTTP 竞争） ──
  DateTime? lastDataTimestamp;
  DateTime lastStatusTime;

  // ── 批量操作 ──
  BatchResult? lastBatchResult;

  // ── 快照 (环形缓冲) ──
  static const int maxSnapshots = 50;
  final List<FarmSnapshot> _snapshots = [];

  FarmPrinterState({
    required this.sn,
    this.displayName,
    required this.ip,
    this.port = 7125,
    this.group,
    this.source = Source.http,
    this.connectionState = FarmConnectionState.offline,
    this.model,
    this.firmwareVersion,
    this.nozzleTemp,
    this.nozzleTarget,
    this.bedTemp,
    this.bedTarget,
    this.printState,
    this.progress,
    this.currentFile,
    this.layerNum,
    this.totalLayers,
    this.estimatedTime,
    this.totalDuration,
    this.filamentUsed,
    this.lastDataTimestamp,
    DateTime? lastStatusTime,
  }) : lastStatusTime = lastStatusTime ?? DateTime.now();

  // ── 派生属性 ──

  bool get isOnline => connectionState == FarmConnectionState.online;
  bool get isPrinting => printState?.value == 'printing';
  bool get isPaused => printState?.value == 'paused';
  bool get isMqtt => source == Source.mqtt;
  bool get isHttp => source == Source.http;

  /// 快照列表（只读）
  List<FarmSnapshot> get snapshots => List.unmodifiable(_snapshots);

  // ═══════════════════════════════════════════════════════════
  // 状态更新
  // ═══════════════════════════════════════════════════════════

  /// 更新遥测数据（含时间戳保护）
  ///
  /// [data] 展开后的键值对，键格式如 "extruder.temperature"、"print_stats.state"
  /// [eventTime] 数据产生的时间戳（MQTT eventtime 或 HTTP pollTime）
  void updateTelemetry(Map<String, dynamic> data, {DateTime? eventTime}) {
    // 时间戳保护：忽略比已有数据更旧的更新
    if (eventTime != null && lastDataTimestamp != null) {
      if (!eventTime.isAfter(lastDataTimestamp!)) return;
    }

    // 喷嘴温度
    if (data.containsKey('extruder.temperature')) {
      nozzleTemp = nozzleTemp?.update(
            (data['extruder.temperature'] as num).toDouble()) ??
          Staleable((data['extruder.temperature'] as num).toDouble());
    }
    if (data.containsKey('extruder.target')) {
      nozzleTarget = nozzleTarget?.update(
            (data['extruder.target'] as num).toDouble()) ??
          Staleable((data['extruder.target'] as num).toDouble());
    }

    // 热床温度
    if (data.containsKey('heater_bed.temperature')) {
      bedTemp = bedTemp?.update(
            (data['heater_bed.temperature'] as num).toDouble()) ??
          Staleable((data['heater_bed.temperature'] as num).toDouble());
    }
    if (data.containsKey('heater_bed.target')) {
      bedTarget = bedTarget?.update(
            (data['heater_bed.target'] as num).toDouble()) ??
          Staleable((data['heater_bed.target'] as num).toDouble());
    }

    // 打印状态
    if (data.containsKey('print_stats.state')) {
      printState = Staleable(data['print_stats.state'] as String);
    }
    if (data.containsKey('virtual_sdcard.progress')) {
      progress = Staleable((data['virtual_sdcard.progress'] as num).toDouble());
    }
    if (data.containsKey('print_stats.filename')) {
      currentFile = Staleable(data['print_stats.filename'] as String);
    }

    // 层数
    if (data.containsKey('print_stats.info.layer_num')) {
      layerNum = Staleable(data['print_stats.info.layer_num'] as int);
    }
    if (data.containsKey('print_stats.info.total_layer')) {
      totalLayers = Staleable(data['print_stats.info.total_layer'] as int);
    }

    // 累积指标：增量计算
    if (data.containsKey('print_stats.total_duration')) {
      final current = (data['print_stats.total_duration'] as num).toDouble();
      if (_lastReportedDuration != null && current > _lastReportedDuration!) {
        totalDuration = (totalDuration ?? 0) + (current - _lastReportedDuration!);
      } else if (_lastReportedDuration == null) {
        totalDuration = current;
      }
      _lastReportedDuration = current;
    }
    if (data.containsKey('print_stats.filament_used')) {
      filamentUsed = (data['print_stats.filament_used'] as num).toDouble();
    }

    if (eventTime != null) {
      lastDataTimestamp = eventTime;
    }
    lastStatusTime = DateTime.now();
  }

  /// 标记来源（MQTT 或 HTTP）
  void markFresh(Source src) {
    source = src;
  }

  /// 标记所有遥测为过期
  void markTelemetryStale() {
    nozzleTemp = nozzleTemp?.markStale();
    nozzleTarget = nozzleTarget?.markStale();
    bedTemp = bedTemp?.markStale();
    bedTarget = bedTarget?.markStale();
    printState = printState?.markStale();
    progress = progress?.markStale();
    currentFile = currentFile?.markStale();
    layerNum = layerNum?.markStale();
    totalLayers = totalLayers?.markStale();
    estimatedTime = estimatedTime?.markStale();
  }

  /// 添加快照（环形缓冲，超出则移除最旧的）
  void addSnapshot(FarmSnapshot snapshot) {
    _snapshots.add(snapshot);
    if (_snapshots.length > maxSnapshots) {
      _snapshots.removeAt(0);
    }
  }

  /// 从 PrinterInfo 创建初始状态
  factory FarmPrinterState.fromInfo(PrinterInfo info) {
    return FarmPrinterState(
      sn: info.sn,
      displayName: info.displayName,
      ip: info.ip,
      port: info.port,
      group: info.group,
      source: info.source,
      model: info.model,
      firmwareVersion: info.firmwareVersion,
      connectionState: FarmConnectionState.offline,
    );
  }
}
