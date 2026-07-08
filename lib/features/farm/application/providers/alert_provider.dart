/// 告警 Provider
///
/// 管理农场告警状态，连接 AlertEngine 与 UI。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/alert_engine.dart';
import '../../domain/models/farm_alert.dart';

/// 告警引擎单例
final alertEngineProvider = Provider<AlertEngine>((ref) {
  final engine = AlertEngine();
  ref.onDispose(() => engine.dispose());
  return engine;
});

/// 可见告警列表（置顶展示用）
final pinnedAlertsProvider = Provider<List<FarmAlert>>((ref) {
  final engine = ref.watch(alertEngineProvider);
  return engine.visibleAlerts;
});

/// 未解决告警总数
final unresolvedAlertCountProvider = Provider<int>((ref) {
  final engine = ref.watch(alertEngineProvider);
  return engine.unresolvedAlerts.length;
});

/// 某台设备的告警
final printerAlertsProvider = Provider.family<List<FarmAlert>, String>(
  (ref, sn) {
    final engine = ref.watch(alertEngineProvider);
    return engine.alertsForPrinter(sn);
  },
);

/// 某台设备是否有活跃告警
final printerHasAlertProvider = Provider.family<bool, String>(
  (ref, sn) {
    final engine = ref.watch(alertEngineProvider);
    return engine.hasActiveAlert(sn);
  },
);

/// 告警流（用于监听变化）
final alertDeltaProvider = StreamProvider<AlertDelta>((ref) {
  final engine = ref.watch(alertEngineProvider);
  return engine.alertStream;
});

/// 告警操作 Notifier
class AlertActions extends Notifier<void> {
  @override
  void build() {}

  AlertEngine get _engine => ref.read(alertEngineProvider);

  /// 确认单条告警
  void acknowledge(String alertId) {
    _engine.acknowledge(alertId);
  }

  /// 确认某台设备所有告警
  void acknowledgeAll(String printerSn) {
    _engine.acknowledgeAll(printerSn);
  }

  /// 静音告警
  void mute(String alertId, {Duration duration = const Duration(minutes: 30)}) {
    _engine.mute(alertId, duration: duration);
  }

  /// 过期静音检查
  void expireMuted() {
    _engine.expireMuted();
  }
}

final alertActionsProvider = NotifierProvider<AlertActions, void>(
  AlertActions.new,
);
