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

  // ── Snapmaker 扩展遥测 ──
  Staleable<double>? fanSpeed;        // fan.speed (0.0~1.0)
  Staleable<double>? fanRpm;          // fan.rpm
  Staleable<List<double>>? toolheadPosition; // toolhead.position [x, y]
  Staleable<String>? homedAxes;       // toolhead.homed_axes
  Staleable<double>? printDuration;   // print_stats.print_duration (秒)
  Staleable<String>? printMessage;    // print_stats.message
  Staleable<int>? fileSize;           // virtual_sdcard.file_size
  Staleable<int>? filePosition;       // virtual_sdcard.file_position
  Staleable<bool>? isFileActive;      // virtual_sdcard.is_active
  Staleable<int>? purifierMode;       // purifier.mode
  Staleable<double>? purifierPowerDetValue; // purifier.power_det_value
  Staleable<bool>? purifierPowerDetected;   // purifier.power_detected
  Staleable<double>? bedPower;        // heater_bed.power
  Staleable<double>? maxAccel;        // toolhead.max_accel
  Staleable<double>? maxVelocity;     // toolhead.max_velocity
  Staleable<double>? extruderPower;   // extruder.power
  Staleable<double>? moveSpeed;       // gcode_move.speed
  Staleable<double>? printingTime;    // idle_timeout.printing_time (已打印秒数)

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

  /// IP 是否为有效 LAN 地址（非占位符）
  bool get hasValidIp => ip.isNotEmpty && ip != 'MQTT' && ip != '—' && ip != 'Unknown';

  /// 是否正在打印（以 printState 为主，其他信号仅作缺失时的 fallback）
  bool get isPrinting {
    final state = printState?.value;
    // 明确非打印状态 → 直接返回 false
    if (state != null && state != 'printing') return false;
    // 明确打印中
    if (state == 'printing') return true;
    // printState 缺失时，用 isFileActive 辅助判断
    if (isFileActive?.value == true) return true;
    // printState 缺失时，用 print_duration > 0 辅助判断（重启后首次状态推送通常不含 state）
    final pd = printDuration?.value;
    if (pd != null && pd > 0) return true;
    return false;
  }

  bool get isPaused => printState?.value == 'paused';

  /// 是否有打印任务（打印中或暂停中），用于显示打印控制面板
  bool get hasPrintJob {
    if (isPrinting || isPaused) return true;
    // 只在 printState 缺失时用其他信号
    if (printState?.value == null) {
      return isFileActive?.value == true || currentFile != null;
    }
    return false;
  }
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

    // 过滤 null 值：MQTT 消息中 JSON null 字段无遥测意义，
    // 且会导致下方 data[key] as String/num 类型转换崩溃。
    data.removeWhere((_, v) => v == null);

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

    // 打印状态 & 文件
    if (data.containsKey('print_stats.state')) {
      final newState = data['print_stats.state'] as String;
      final oldState = printState?.value;
      printState = Staleable(newState);

      // 打印结束 → 清理残留的打印相关字段，避免 isPrinting 误判
      if (newState != 'printing' && newState != 'paused') {
        if (oldState == 'printing' || oldState == 'paused') {
          progress = null;
          currentFile = null;
          isFileActive = null;
          fileSize = null;
          filePosition = null;
          layerNum = null;
          totalLayers = null;
          printDuration = null;
          printMessage = null;
        }
      }
    }
    if (data.containsKey('virtual_sdcard.progress')) {
      progress = Staleable((data['virtual_sdcard.progress'] as num).toDouble());
    } else if (data.containsKey('virtual_sdcard.file_position') && data.containsKey('virtual_sdcard.file_size')) {
      // Snapmaker: 用 file_position/file_size 算进度
      final pos = (data['virtual_sdcard.file_position'] as num).toDouble();
      final size = (data['virtual_sdcard.file_size'] as num).toDouble();
      if (size > 0) progress = Staleable(pos / size);
    }
    if (data.containsKey('print_stats.filename')) {
      currentFile = Staleable(data['print_stats.filename'] as String);
    } else if (data.containsKey('virtual_sdcard.file_path')) {
      final path = data['virtual_sdcard.file_path'] as String;
      currentFile = Staleable(path.split('/').last);
    }

    // 层数（Snapmaker: print_stats.info.current_layer）
    if (data.containsKey('print_stats.info.layer_num')) {
      layerNum = Staleable((data['print_stats.info.layer_num'] as num).toInt());
    } else if (data.containsKey('print_stats.info.current_layer')) {
      layerNum = Staleable((data['print_stats.info.current_layer'] as num).toInt());
    }
    if (data.containsKey('print_stats.info.total_layer')) {
      totalLayers = Staleable((data['print_stats.info.total_layer'] as num).toInt());
    }

    // 打印耗时
    if (data.containsKey('print_stats.print_duration')) {
      printDuration = Staleable((data['print_stats.print_duration'] as num).toDouble());
    }
    if (data.containsKey('print_stats.message')) {
      printMessage = Staleable(data['print_stats.message'] as String);
    }

    // 文件信息
    if (data.containsKey('virtual_sdcard.file_size')) {
      fileSize = Staleable((data['virtual_sdcard.file_size'] as num).toInt());
    }
    if (data.containsKey('virtual_sdcard.file_position')) {
      filePosition = Staleable((data['virtual_sdcard.file_position'] as num).toInt());
    }
    if (data.containsKey('virtual_sdcard.is_active')) {
      isFileActive = Staleable(data['virtual_sdcard.is_active'] as bool);
    }

    // 风扇
    if (data.containsKey('fan.speed')) {
      fanSpeed = Staleable((data['fan.speed'] as num).toDouble());
    }
    if (data.containsKey('fan.rpm')) {
      fanRpm = Staleable((data['fan.rpm'] as num).toDouble());
    }

    // 工具头
    if (data.containsKey('toolhead.position')) {
      final pos = data['toolhead.position'] as List;
      toolheadPosition = Staleable(pos.map((e) => (e as num).toDouble()).toList());
    }
    if (data.containsKey('toolhead.homed_axes')) {
      homedAxes = Staleable(data['toolhead.homed_axes'] as String);
    }
    if (data.containsKey('toolhead.max_accel')) {
      maxAccel = Staleable((data['toolhead.max_accel'] as num).toDouble());
    }
    if (data.containsKey('toolhead.max_velocity')) {
      maxVelocity = Staleable((data['toolhead.max_velocity'] as num).toDouble());
    }

    // 净化器
    if (data.containsKey('purifier.mode')) {
      purifierMode = Staleable((data['purifier.mode'] as num).toInt());
    }
    if (data.containsKey('purifier.power_det_value')) {
      purifierPowerDetValue = Staleable((data['purifier.power_det_value'] as num).toDouble());
    }
    if (data.containsKey('purifier.power_detected')) {
      purifierPowerDetected = Staleable(data['purifier.power_detected'] as bool);
    }

    // 热床功率（Snapmaker 可能只上报 power，无 temperature）
    if (data.containsKey('heater_bed.power')) {
      bedPower = Staleable((data['heater_bed.power'] as num).toDouble());
    }

    // display_status.progress → 打印进度（Snapmaker 特有）
    if (data.containsKey('display_status.progress')) {
      final dp = (data['display_status.progress'] as num).toDouble();
      progress = Staleable(dp.clamp(0.0, 1.0));
    }

    // 挤出机功率
    if (data.containsKey('extruder.power')) {
      extruderPower = Staleable((data['extruder.power'] as num).toDouble());
    }

    // 移动速度
    if (data.containsKey('gcode_move.speed')) {
      moveSpeed = Staleable((data['gcode_move.speed'] as num).toDouble());
    }

    // 已打印时间
    if (data.containsKey('idle_timeout.printing_time')) {
      printingTime = Staleable((data['idle_timeout.printing_time'] as num).toDouble());
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

    // 推断打印状态：如果本次更新未包含 print_stats.state，
    // 但 print_duration 或 filament_used 有正值，则推断为 printing。
    // 解决重启后首次 MQTT 推送只含增量数据（不含 state）的问题。
    if (!data.containsKey('print_stats.state')) {
      final pd = printDuration?.value ?? 0;
      final fu = filamentUsed ?? 0;
      if (pd > 0 || fu > 0) {
        // 仅在 state 缺失时推断，不覆盖已有明确状态
        if (printState == null) {
          printState = Staleable('printing');
        }
      }
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
    fanSpeed = fanSpeed?.markStale();
    fanRpm = fanRpm?.markStale();
    toolheadPosition = toolheadPosition?.markStale();
    homedAxes = homedAxes?.markStale();
    printDuration = printDuration?.markStale();
    printMessage = printMessage?.markStale();
    fileSize = fileSize?.markStale();
    filePosition = filePosition?.markStale();
    isFileActive = isFileActive?.markStale();
    purifierMode = purifierMode?.markStale();
    purifierPowerDetValue = purifierPowerDetValue?.markStale();
    purifierPowerDetected = purifierPowerDetected?.markStale();
    bedPower = bedPower?.markStale();
    maxAccel = maxAccel?.markStale();
    maxVelocity = maxVelocity?.markStale();
    extruderPower = extruderPower?.markStale();
    moveSpeed = moveSpeed?.markStale();
    printingTime = printingTime?.markStale();
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
