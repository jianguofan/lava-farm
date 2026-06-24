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

/// 挤出机状态
class ExtruderState {
  final int index; // 1, 2, 3 ...
  Staleable<double>? temperature;
  Staleable<double>? target;

  ExtruderState({required this.index, this.temperature, this.target});

  double get currentTemp => temperature?.value ?? 0;
  double? get targetTemp => target?.value;
  bool get isStale => temperature?.isStale ?? true;
  bool get isHeating => targetTemp != null && (currentTemp - targetTemp!).abs() > 1.0;
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

  // ── Moonraker server.info / printer.info 元数据 ──
  String? hostname;         // printer.info.hostname
  String? softwareVersion;  // printer.info.software_version
  String? cpuInfo;          // printer.info.cpu_info
  String? klippyState;      // server.info.klippy_state
  String? moonrakerVersion; // server.info.moonraker_version
  String? apiVersionString; // server.info.api_version_string
  DateTime? serverInfoFetchedAt; // 最近一次成功获取 server.info 的时间

  // ── 通信模式 ──
  Source source;
  FarmConnectionState connectionState;

  // ── 实时遥测 (Staleable) ──
  /// 多挤出机（extruder1/2/3），index 从 1 开始
  final List<ExtruderState> extruders = [];
  Staleable<double>? bedTemp;
  Staleable<double>? bedTarget;

  /// 便捷访问：第一个挤出机（保持旧代码兼容）
  Staleable<double>? get nozzleTemp => extruders.isNotEmpty ? extruders.first.temperature : null;
  Staleable<double>? get nozzleTarget => extruders.isNotEmpty ? extruders.first.target : null;
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

  // ── 原始消息收集 ──
  /// 原始 MQTT 消息环形缓冲（最近 N 条）
  static const int maxRawMessages = 200;
  final List<Map<String, dynamic>> _rawMessages = [];

  /// 最近一次完整状态快照（所有展平键值对，不限于 updateTelemetry 提取的字段）
  Map<String, dynamic>? rawStateSnapshot;
  DateTime? rawStateSnapshotTime;

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
    this.hostname,
    this.softwareVersion,
    this.cpuInfo,
    this.klippyState,
    this.moonrakerVersion,
    this.apiVersionString,
    this.serverInfoFetchedAt,
    List<ExtruderState>? extruders,
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
  }) : lastStatusTime = lastStatusTime ?? DateTime.now() {
    if (extruders != null) this.extruders.addAll(extruders);
  }

  // ── 派生属性 ──

  bool get isOnline => connectionState == FarmConnectionState.online;
  bool get isPrinting => printState?.value == 'printing';
  bool get isPaused => printState?.value == 'paused';
  bool get isMqtt => source == Source.mqtt;
  bool get isHttp => source == Source.http;

  /// 快照列表（只读）
  List<FarmSnapshot> get snapshots => List.unmodifiable(_snapshots);

  /// 原始消息列表（只读，最近 maxRawMessages 条）
  List<Map<String, dynamic>> get rawMessages => List.unmodifiable(_rawMessages);

  // ═══════════════════════════════════════════════════════════
  // 状态更新
  // ═══════════════════════════════════════════════════════════

  /// 更新遥测数据（含时间戳保护 + 值去重）
  ///
  /// [data] 展开后的键值对，键格式如 "extruder.temperature"、"print_stats.state"
  /// [eventTime] 数据产生的时间戳（MQTT eventtime 或 HTTP pollTime）
  /// 返回 true 表示有实际数据变更，false 表示全部字段值未变（可跳过通知）
  bool updateTelemetry(Map<String, dynamic> data, {DateTime? eventTime}) {
    // 时间戳保护：忽略比已有数据更旧的更新
    if (eventTime != null && lastDataTimestamp != null) {
      if (!eventTime.isAfter(lastDataTimestamp!)) return false;
    }

    // 值去重：如果所有字段值与已有快照相同，跳过
    if (rawStateSnapshot != null) {
      bool anyChanged = false;
      for (final entry in data.entries) {
        if (rawStateSnapshot![entry.key] != entry.value) {
          anyChanged = true;
          break;
        }
      }
      if (!anyChanged) return false;
    }

    // 多挤出机温度（extruder1 / extruder2 / extruder3 ...）
    for (int i = 1; i <= 9; i++) {
      final tempKey = 'extruder$i.temperature';
      final targetKey = 'extruder$i.target';
      if (data.containsKey(tempKey) || data.containsKey(targetKey)) {
        _ensureExtruder(i);
        final ext = extruders[i - 1];
        if (data.containsKey(tempKey)) {
          ext.temperature = ext.temperature?.update(
                (data[tempKey] as num).toDouble()) ??
              Staleable((data[tempKey] as num).toDouble());
        }
        if (data.containsKey(targetKey)) {
          ext.target = ext.target?.update(
                (data[targetKey] as num).toDouble()) ??
              Staleable((data[targetKey] as num).toDouble());
        }
      }
    }
    // 兼容旧格式: extruder.temperature（无编号 = extruder1）
    if (data.containsKey('extruder.temperature')) {
      _ensureExtruder(1);
      extruders[0].temperature = extruders[0].temperature?.update(
            (data['extruder.temperature'] as num).toDouble()) ??
          Staleable((data['extruder.temperature'] as num).toDouble());
    }
    if (data.containsKey('extruder.target')) {
      _ensureExtruder(1);
      extruders[0].target = extruders[0].target?.update(
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
    return true;
  }

  /// 标记来源（MQTT 或 HTTP）
  void markFresh(Source src) {
    source = src;
  }

  /// 确保存在第 index 个挤出机（1-based）
  void _ensureExtruder(int index) {
    while (extruders.length < index) {
      extruders.add(ExtruderState(index: extruders.length + 1));
    }
  }

  /// 标记所有遥测为过期
  void markTelemetryStale() {
    for (final ext in extruders) {
      ext.temperature = ext.temperature?.markStale();
      ext.target = ext.target?.markStale();
    }
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

  /// 添加原始 MQTT 消息到环形缓冲
  ///
  /// [message] 解析后的 JSON-RPC 消息 Map（含 jsonrpc/method/params）
  void addRawMessage(Map<String, dynamic> message) {
    _rawMessages.add(message);
    if (_rawMessages.length > maxRawMessages) {
      _rawMessages.removeAt(0);
    }
  }

  /// 更新最近一次完整状态快照（合并模式）
  ///
  /// MQTT notify_status_update 只推送变化字段，因此需要合并而非替换。
  /// printer.objects.query 全量拉取时 snapshot 包含所有字段，后续增量消息逐步合并。
  ///
  /// [snapshot] 展平后的键值对（如 "extruder.temperature" → 210.5）
  void updateRawStateSnapshot(Map<String, dynamic> snapshot) {
    rawStateSnapshot ??= {};
    // 合并：新值覆盖旧值，旧值保留
    rawStateSnapshot!.addAll(snapshot);
    rawStateSnapshotTime = DateTime.now();
  }

  /// 更新设备元数据（从 server.info / printer.info 响应）
  void updateDeviceInfo({
    String? hostname,
    String? softwareVersion,
    String? cpuInfo,
    String? klippyState,
    String? moonrakerVersion,
    String? apiVersionString,
  }) {
    if (hostname != null) this.hostname = hostname;
    if (softwareVersion != null) this.softwareVersion = softwareVersion;
    if (cpuInfo != null) this.cpuInfo = cpuInfo;
    if (klippyState != null) this.klippyState = klippyState;
    if (moonrakerVersion != null) this.moonrakerVersion = moonrakerVersion;
    if (apiVersionString != null) this.apiVersionString = apiVersionString;
    serverInfoFetchedAt = DateTime.now();
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
