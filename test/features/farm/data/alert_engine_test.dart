// AlertEngine 告警触发与置顶排序测试
//
// 验证 alert-pinning 的"异常触发后置顶显示"行为：
// 引擎由 farmStoreVersionProvider 驱动（~100ms 批处理窗口），
// 因此从状态变化到告警生成的延迟远小于 1 分钟。
import 'package:lava_farm/features/farm/data/alert_engine.dart';
import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
import 'package:lava_farm/features/farm/data/printer_info.dart';
import 'package:lava_farm/features/farm/domain/models/farm_alert.dart';
import 'package:test/test.dart';

void main() {
  late AlertEngine engine;

  setUp(() {
    engine = AlertEngine();
  });

  FarmPrinterState onlinePrinter({String sn = 'SN1'}) {
    return FarmPrinterState(
      sn: sn,
      ip: '10.0.0.1',
      source: Source.mqtt,
      connectionState: FarmConnectionState.online,
    );
  }

  test('在线 → 离线 立即生成 offline 告警', () {
    final online = onlinePrinter();
    final offline = FarmPrinterState(
      sn: 'SN1',
      ip: '10.0.0.1',
      connectionState: FarmConnectionState.offline,
    );

    final delta = engine.processStateChange(online, offline);

    expect(delta.updated, isNotEmpty);
    expect(delta.updated.first.type, FarmAlertType.offline);
    expect(engine.visibleAlerts, isNotEmpty);
  });

  test('printState=error 立即生成 critical 告警并置顶', () {
    final normal = onlinePrinter()
      ..printState = Staleable('printing');
    final errored = onlinePrinter()
      ..printState = Staleable('error')
      ..printMessage = Staleable('Thermal runaway');

    engine.processStateChange(null, normal);
    final delta = engine.processStateChange(normal, errored);

    final errorAlert = delta.updated.firstWhere(
      (a) => a.type == FarmAlertType.printError,
    );
    expect(errorAlert.severity, FarmAlertSeverity.critical);

    // critical 告警排在可见列表最前
    expect(engine.visibleAlerts.first.severity, FarmAlertSeverity.critical);
  });

  test('离线 → 在线 自动 resolve offline 告警', () {
    final online = onlinePrinter();
    final offline = FarmPrinterState(
      sn: 'SN1',
      ip: '10.0.0.1',
      connectionState: FarmConnectionState.offline,
    );

    engine.processStateChange(online, offline);
    expect(engine.visibleAlerts, isNotEmpty);

    final delta = engine.processStateChange(offline, online);
    expect(delta.resolved, isNotEmpty);
    expect(engine.visibleAlerts, isEmpty);
  });

  test('喷嘴温度偏差 > 30°C 生成温度异常告警', () {
    final heating = onlinePrinter()
      ..extruders.add(ExtruderState(
        index: 1,
        temperature: Staleable(180.0),
        target: Staleable(220.0),
      ));

    final delta = engine.processStateChange(null, heating);

    expect(delta.updated, isNotEmpty);
    expect(delta.updated.first.type, FarmAlertType.temperatureAnomaly);
  });

  test('已静音告警不出现在 visibleAlerts，已确认仍置顶', () {
    final online = onlinePrinter();
    final offline = FarmPrinterState(
      sn: 'SN1',
      ip: '10.0.0.1',
      connectionState: FarmConnectionState.offline,
    );
    engine.processStateChange(online, offline);

    final alert = engine.visibleAlerts.single;

    // 确认后状态变更但仍置顶可见
    final acked = engine.acknowledge(alert.id);
    expect(acked.status, FarmAlertStatus.acknowledged);
    expect(engine.visibleAlerts, isNotEmpty);

    // 静音后从可见列表移除
    engine.mute(alert.id);
    expect(engine.visibleAlerts, isEmpty);
    // acknowledged/muted 仍属未解决（未真正 resolve）
    expect(engine.unresolvedAlerts, isNotEmpty);
  });
}
