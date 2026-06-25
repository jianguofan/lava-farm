/// FarmLogger — 本地结构化日志系统
///
/// 记录所有 MQTT 命令/响应/状态/通知，以 JSONL 格式写入磁盘。
///
/// 特性:
/// - 环形缓冲区（2000 条），超出后覆盖最旧记录
/// - 定时刷盘（30 秒）或达到阈值（500 条）立即刷
/// - JSONL 格式：一行一条 JSON，便于 grep/jq 分析
/// - 文件按天轮转: ~/.lava-farm/logs/farm_YYYY-MM-DD.jsonl
/// - 自动清理：保留最近 7 天
///
/// 使用示例:
///   FarmLogger.instance.init();
///   FarmLogger.instance.logCommandSent(sn, method, params);
///   FarmLogger.instance.logStatusReceived(sn, expanded);
///   await FarmLogger.instance.dispose();  // App 关闭时

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 日志分类
enum LogCategory { command_sent, command_response, status_received, notification_received }

/// 本地日志服务（单例）
class FarmLogger {
  static final FarmLogger _instance = FarmLogger._();
  static FarmLogger get instance => _instance;
  FarmLogger._();

  // ── 配置 ──
  static const int _ringCapacity = 2000;
  static const int _flushThreshold = 500;
  static const Duration _flushInterval = Duration(seconds: 30);
  static const int _maxAgeDays = 7;

  // ── 状态 ──
  bool _initialized = false;
  late Directory _logDir;
  Timer? _flushTimer;
  final List<Map<String, dynamic>> _ring = [];
  int _ringHead = 0;
  bool _ringWrapped = false;
  Timer? _cleanupTimer;

  // ═══════════════════════════════════════════════════════════
  // 公共 API
  // ═══════════════════════════════════════════════════════════

  /// 初始化：创建日志目录，启动定时刷盘，清理旧日志
  void init() {
    if (_initialized) return;
    _initialized = true;

    final home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'] ??
        '.';
    _logDir = Directory('$home/.lava-farm/logs');
    if (!_logDir.existsSync()) {
      _logDir.createSync(recursive: true);
    }

    _startFlushTimer();
    _cleanupOldLogs();
    _cleanupTimer = Timer.periodic(const Duration(hours: 6), (_) => _cleanupOldLogs());
  }

  /// 记录发送的命令
  void logCommandSent(String sn, String method, Map<String, dynamic>? params) {
    _add({
      'ts': _now(),
      'sn': sn,
      'dir': 'out',
      'cat': LogCategory.command_sent.name,
      'method': method,
      'params': _summarize(params),
    });
  }

  /// 记录收到的命令响应
  void logCommandResponse(String sn, Map<String, dynamic> response) {
    _add({
      'ts': _now(),
      'sn': sn,
      'dir': 'in',
      'cat': LogCategory.command_response.name,
      'topic': '$sn/response',
      'id': response['id'],
      'has_error': response.containsKey('error'),
    });
  }

  /// 记录收到的状态推送
  void logStatusReceived(String sn, Map<String, dynamic> expanded, {DateTime? eventTime}) {
    _add({
      'ts': _now(),
      'sn': sn,
      'dir': 'in',
      'cat': LogCategory.status_received.name,
      'topic': '$sn/status',
      'summary': _summarizeStatus(expanded),
    });
  }

  /// 记录收到的通知
  void logNotificationReceived(String sn, Map<String, dynamic> data) {
    _add({
      'ts': _now(),
      'sn': sn,
      'dir': 'in',
      'cat': LogCategory.notification_received.name,
      'topic': '$sn/notification',
      'event': data['server'] ?? _summarize(data),
    });
  }

  /// 立即刷盘（App 关闭前调用）
  Future<void> flush() async {
    _flushTimer?.cancel();
    await _writeToDisk();
  }

  /// 释放资源
  Future<void> dispose() async {
    _initialized = false; // 标记为未初始化，阻止新的 _add
    _flushTimer?.cancel();
    _cleanupTimer?.cancel();
    await _writeToDisk();
  }

  // ═══════════════════════════════════════════════════════════
  // 内部
  // ═══════════════════════════════════════════════════════════

  String _now() {
    final now = DateTime.now();
    return '${now.year}-${_pad(now.month)}-${_pad(now.day)}T'
        '${_pad(now.hour)}:${_pad(now.minute)}:${_pad(now.second)}.'
        '${now.millisecond.toString().padLeft(3, '0')}';
  }

  static String _pad(int n) => n.toString().padLeft(2, '0');

  void _add(Map<String, dynamic> entry) {
    if (!_initialized) return;

    if (_ring.length < _ringCapacity) {
      _ring.add(entry);
    } else {
      _ring[_ringHead] = entry;
    }
    _ringHead = (_ringHead + 1) % _ringCapacity;
    if (_ringHead == 0) _ringWrapped = true;

    if (_entryCount >= _flushThreshold) {
      _flushTimer?.cancel();
      _writeToDisk();
      _startFlushTimer();
    }
  }

  int get _entryCount => _ringWrapped ? _ringCapacity : _ringHead;

  void _startFlushTimer() {
    _flushTimer?.cancel();
    _flushTimer = Timer.periodic(_flushInterval, (_) => _writeToDisk());
  }

  Future<void> _writeToDisk() async {
    if (_entryCount == 0) return;

    // 收集待写条目
    final entries = <Map<String, dynamic>>[];
    if (_ringWrapped) {
      entries.addAll(_ring.sublist(_ringHead));
      entries.addAll(_ring.sublist(0, _ringHead));
    } else {
      entries.addAll(_ring.sublist(0, _ringHead));
    }

    // 构建 JSONL
    final buf = StringBuffer();
    for (final entry in entries) {
      buf.writeln(jsonEncode(entry));
    }

    // 清空环形缓冲
    _ring.clear();
    _ringHead = 0;
    _ringWrapped = false;

    // 写入当天文件
    final now = DateTime.now();
    final filename = 'farm_${now.year}-${_pad(now.month)}-${_pad(now.day)}.jsonl';
    final file = File('${_logDir.path}/$filename');

    try {
      await file.writeAsString(buf.toString(), mode: FileMode.append);
    } catch (e) {
      // 磁盘写入失败不崩溃
    }
  }

  void _cleanupOldLogs() {
    try {
      final cutoff = DateTime.now().subtract(Duration(days: _maxAgeDays));
      final files = _logDir.listSync().whereType<File>();
      for (final file in files) {
        if (!file.path.endsWith('.jsonl')) continue;
        try {
          final basename = file.path.split(Platform.pathSeparator).last;
          final datePart =
              basename.replaceFirst('farm_', '').replaceFirst('.jsonl', '');
          final parts = datePart.split('-');
          if (parts.length == 3) {
            final fileDate = DateTime(
              int.parse(parts[0]),
              int.parse(parts[1]),
              int.parse(parts[2]),
            );
            if (fileDate.isBefore(cutoff)) {
              file.deleteSync();
            }
          }
        } catch (_) {}
      }
    } catch (_) {}
  }

  String _summarize(Map<String, dynamic>? m) {
    if (m == null) return '{}';
    if (m.isEmpty) return '{}';
    final keys = m.keys.take(5).join(',');
    if (m.keys.length > 5) return '{$keys, ...}';
    return '{$keys}';
  }

  String _summarizeStatus(Map<String, dynamic> expanded) {
    final parts = <String>[];
    for (int i = 1; i <= 4; i++) {
      final t = expanded['extruder$i.temperature'];
      if (t != null) parts.add('E$i=$t');
    }
    if (expanded.containsKey('extruder.temperature') &&
        !expanded.containsKey('extruder1.temperature')) {
      parts.add('E=${expanded['extruder.temperature']}');
    }
    final bed = expanded['heater_bed.temperature'];
    if (bed != null) parts.add('B=$bed');
    final state = expanded['print_stats.state'];
    if (state != null) parts.add('state=$state');
    final prog = expanded['display_status.progress'];
    if (prog != null) parts.add('prog=${(prog is num ? prog : 0).toStringAsFixed(1)}');
    return parts.isEmpty ? expanded.keys.take(5).join(',') : parts.join(', ');
  }
}
