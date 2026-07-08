/// 告警引擎
///
/// 从 FarmStore 中的设备状态变化中生成、合并、更新异常告警。
/// 核心逻辑：
/// - 监控每台设备的 online/offline 切换
/// - 监控 printState 的 error 状态
/// - 监控温度异常
/// - 合并同设备同类型告警（counter + lastSeenAt）
/// - 自动 resolve 问题消失的告警

import 'dart:async';

import '../domain/models/farm_alert.dart';
import 'farm_printer_state.dart';

/// 告警变更事件
class AlertDelta {
  /// 新增或更新的告警
  final List<FarmAlert> updated;

  /// 已解决的告警 ID 列表
  final List<String> resolved;

  const AlertDelta({this.updated = const [], this.resolved = const []});

  bool get isEmpty => updated.isEmpty && resolved.isEmpty;
}

class AlertEngine {
  /// 当前活跃告警（包括 acknowledged）
  final List<FarmAlert> _alerts = [];

  /// 告警变更流
  final _alertController = StreamController<AlertDelta>.broadcast();
  Stream<AlertDelta> get alertStream => _alertController.stream;

  List<FarmAlert> get alerts => List.unmodifiable(_alerts);

  /// 可见告警（排除已解决和已静音）
  List<FarmAlert> get visibleAlerts =>
      _alerts.where((a) => a.isVisible && !a.isMuted).toList()
        ..sort(_alertSort);

  /// 所有未解决告警
  List<FarmAlert> get unresolvedAlerts =>
      _alerts.where((a) => a.status != FarmAlertStatus.resolved).toList()
        ..sort(_alertSort);

  /// 某台设备的当前告警
  List<FarmAlert> alertsForPrinter(String sn) =>
      _alerts.where((a) => a.printerSn == sn && a.status != FarmAlertStatus.resolved).toList();

  /// 某台设备是否有活跃告警
  bool hasActiveAlert(String sn) =>
      _alerts.any((a) => a.printerSn == sn && a.status == FarmAlertStatus.active);

  /// 处理设备状态变化，生成告警 delta
  ///
  /// [oldState] 变化前的状态（可为 null 表示首次出现）
  /// [newState] 变化后的状态
  AlertDelta processStateChange(FarmPrinterState? oldState, FarmPrinterState newState) {
    final updated = <FarmAlert>[];
    final resolved = <String>[];

    final sn = newState.sn;
    final name = newState.displayName ?? sn;

    // ── 离线检测 ──
    final wasOnline = oldState?.isOnline ?? false;
    if (wasOnline && !newState.isOnline) {
      // 设备从在线变为离线
      updated.add(_upsert(FarmAlert.create(
        printerSn: sn,
        printerName: name,
        type: FarmAlertType.offline,
        title: '$name 已离线',
        detail: '设备断开连接，最后在线时间: ${_formatTime(newState.lastStatusTime)}',
      )));
    } else if (!wasOnline && newState.isOnline) {
      // 设备从离线恢复 → resolve offline alert
      resolved.addAll(_resolveByType(sn, FarmAlertType.offline));
    }

    // ── 打印错误检测 ──
    final printState = newState.printState?.value;
    final oldPrintState = oldState?.printState?.value;
    if (printState == 'error' && oldPrintState != 'error') {
      final msg = newState.printMessage?.value;
      updated.add(_upsert(FarmAlert.create(
        printerSn: sn,
        printerName: name,
        type: FarmAlertType.printError,
        severity: FarmAlertSeverity.critical,
        title: '$name 打印错误',
        detail: msg ?? 'Klipper 报告错误状态',
      )));
    } else if (oldPrintState == 'error' && printState != 'error' && printState != null) {
      resolved.addAll(_resolveByType(sn, FarmAlertType.printError));
    }

    // ── 温度异常检测 ──
    _checkTemperatureAnomaly(oldState, newState, sn, name, updated, resolved);

    // ── 心跳超时检测 ──
    if (newState.isOnline && oldState != null) {
      final lastData = newState.lastDataTimestamp;
      if (lastData != null) {
        final gap = DateTime.now().difference(lastData);
        if (gap.inSeconds > 120) {
          updated.add(_upsert(FarmAlert.create(
            printerSn: sn,
            printerName: name,
            type: FarmAlertType.heartbeatTimeout,
            title: '$name 数据超时',
            detail: '超过 ${gap.inMinutes} 分钟未收到遥测数据',
          )));
        } else if (gap.inSeconds < 30) {
          // 数据恢复 → resolve heartbeat alert
          resolved.addAll(_resolveByType(sn, FarmAlertType.heartbeatTimeout));
        }
      }
    }

    // ── HTTP 降级检测 ──
    if (newState.isHttp && newState.isOnline) {
      updated.add(_upsert(FarmAlert.create(
        printerSn: sn,
        printerName: name,
        type: FarmAlertType.httpDegraded,
        title: '$name 连接降级',
        detail: '当前使用 HTTP 轮询模式，延迟较高',
      )));
    } else if (newState.isMqtt) {
      resolved.addAll(_resolveByType(sn, FarmAlertType.httpDegraded));
    }

    if (updated.isNotEmpty || resolved.isNotEmpty) {
      final delta = AlertDelta(updated: updated, resolved: resolved);
      _alertController.add(delta);
      return delta;
    }
    return const AlertDelta();
  }

  /// 检查温度异常
  void _checkTemperatureAnomaly(
    FarmPrinterState? oldState,
    FarmPrinterState newState,
    String sn,
    String name,
    List<FarmAlert> updated,
    List<String> resolved,
  ) {
    // 检查喷嘴温度（仅在线且有数据）
    if (!newState.isOnline) return;

    for (final ext in newState.extruders) {
      final temp = ext.currentTemp;
      final target = ext.targetTemp;
      if (target != null && target > 0) {
        // 加热超时：目标温度与实际温度差距过大持续
        final diff = (temp - target).abs();
        if (diff > 30 && !ext.isStale) {
          updated.add(_upsert(FarmAlert.create(
            printerSn: sn,
            printerName: name,
            type: FarmAlertType.temperatureAnomaly,
            severity: diff > 50 ? FarmAlertSeverity.critical : FarmAlertSeverity.warning,
            title: '$name 温度异常',
            detail: '挤出机 ${ext.index} 温度偏差 ${diff.toStringAsFixed(1)}°C (目标 ${target.toStringAsFixed(0)}°C, 当前 ${temp.toStringAsFixed(1)}°C)',
          )));
          return;
        }
      }
    }

    // 温度正常 → resolve
    final hasActiveTempAlert = _alerts.any(
      (a) => a.printerSn == sn &&
          a.type == FarmAlertType.temperatureAnomaly &&
          a.status != FarmAlertStatus.resolved,
    );
    if (hasActiveTempAlert) {
      // 确认所有挤出机温度正常
      bool allNormal = true;
      for (final ext in newState.extruders) {
        final temp = ext.currentTemp;
        final target = ext.targetTemp;
        if (target != null && target > 0 && (temp - target).abs() > 30) {
          allNormal = false;
          break;
        }
      }
      if (allNormal) {
        resolved.addAll(_resolveByType(sn, FarmAlertType.temperatureAnomaly));
      }
    }
  }

  /// 插入或合并告警
  FarmAlert _upsert(FarmAlert alert) {
    final existingIdx = _alerts.indexWhere(
      (a) => a.printerSn == alert.printerSn &&
          a.type == alert.type &&
          a.status != FarmAlertStatus.resolved,
    );
    if (existingIdx >= 0) {
      _alerts[existingIdx] = _alerts[existingIdx].merge(alert);
      return _alerts[existingIdx];
    } else {
      _alerts.add(alert);
      return alert;
    }
  }

  /// 按类型 resolve 告警
  List<String> _resolveByType(String sn, FarmAlertType type) {
    final ids = <String>[];
    for (var i = 0; i < _alerts.length; i++) {
      final a = _alerts[i];
      if (a.printerSn == sn &&
          a.type == type &&
          a.status != FarmAlertStatus.resolved) {
        _alerts[i] = a.copyWith(
          status: FarmAlertStatus.resolved,
          resolvedAt: DateTime.now(),
        );
        ids.add(a.id);
      }
    }
    return ids;
  }

  /// 确认告警
  FarmAlert acknowledge(String alertId) {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx < 0) throw StateError('Alert not found: $alertId');
    _alerts[idx] = _alerts[idx].copyWith(
      status: FarmAlertStatus.acknowledged,
      acknowledgedAt: DateTime.now(),
    );
    _alertController.add(AlertDelta(updated: [_alerts[idx]]));
    return _alerts[idx];
  }

  /// 确认某台设备所有活跃告警
  List<FarmAlert> acknowledgeAll(String printerSn) {
    final result = <FarmAlert>[];
    for (var i = 0; i < _alerts.length; i++) {
      if (_alerts[i].printerSn == printerSn &&
          _alerts[i].status == FarmAlertStatus.active) {
        _alerts[i] = _alerts[i].copyWith(
          status: FarmAlertStatus.acknowledged,
          acknowledgedAt: DateTime.now(),
        );
        result.add(_alerts[i]);
      }
    }
    if (result.isNotEmpty) {
      _alertController.add(AlertDelta(updated: result));
    }
    return result;
  }

  /// 静音告警（指定时长）
  FarmAlert mute(String alertId, {Duration duration = const Duration(minutes: 30)}) {
    final idx = _alerts.indexWhere((a) => a.id == alertId);
    if (idx < 0) throw StateError('Alert not found: $alertId');
    _alerts[idx] = _alerts[idx].copyWith(
      status: FarmAlertStatus.muted,
      mutedUntil: DateTime.now().add(duration),
    );
    _alertController.add(AlertDelta(updated: [_alerts[idx]]));
    return _alerts[idx];
  }

  /// 静音结束后恢复
  void expireMuted() {
    final now = DateTime.now();
    final restored = <FarmAlert>[];
    for (var i = 0; i < _alerts.length; i++) {
      if (_alerts[i].status == FarmAlertStatus.muted &&
          _alerts[i].mutedUntil != null &&
          !_alerts[i].mutedUntil!.isAfter(now)) {
        _alerts[i] = _alerts[i].copyWith(
          status: FarmAlertStatus.active,
          mutedUntil: null,
        );
        restored.add(_alerts[i]);
      }
    }
    if (restored.isNotEmpty) {
      _alertController.add(AlertDelta(updated: restored));
    }
  }

  /// 清理已解决告警（超过保留时间）
  void purgeResolved({Duration ttl = const Duration(hours: 24)}) {
    final cutoff = DateTime.now().subtract(ttl);
    _alerts.removeWhere((a) =>
        a.status == FarmAlertStatus.resolved &&
        (a.resolvedAt?.isBefore(cutoff) ?? true));
  }

  void dispose() {
    _alertController.close();
  }

  static int _alertSort(FarmAlert a, FarmAlert b) {
    final severityCmp = a.severity.rank.compareTo(b.severity.rank);
    if (severityCmp != 0) return severityCmp;
    return b.lastSeenAt.compareTo(a.lastSeenAt);
  }

  static String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}';
  }
}
