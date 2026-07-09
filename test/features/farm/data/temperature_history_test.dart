// 温度历史缓冲测试（30 分钟曲线数据源）
import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
import 'package:test/test.dart';

void main() {
  FarmPrinterState newPrinter() =>
      FarmPrinterState(sn: 'SN1', ip: '10.0.0.1');

  test('温度更新会记录到历史', () {
    final p = newPrinter();
    p.updateTelemetry({
      'extruder.temperature': 200.0,
      'extruder.target': 210.0,
      'heater_bed.temperature': 60.0,
      'heater_bed.target': 65.0,
    });
    expect(p.tempHistory.length, 1);
    final s = p.tempHistory.single;
    expect(s.nozzleTemp, 200.0);
    expect(s.nozzleTarget, 210.0);
    expect(s.bedTemp, 60.0);
    expect(s.bedTarget, 65.0);
  });

  test('非温度字段更新不记录历史', () {
    final p = newPrinter();
    p.updateTelemetry({'print_stats.state': 'printing'});
    expect(p.tempHistory, isEmpty);
  });

  test('5 秒内的连续温度更新被节流为单条', () {
    final p = newPrinter();
    p.updateTelemetry({'extruder.temperature': 100.0});
    p.updateTelemetry({'extruder.temperature': 150.0});
    p.updateTelemetry({'extruder.temperature': 180.0});
    p.updateTelemetry({'extruder.temperature': 200.0});
    // 4 次连续更新（间隔 < 5s）只记录首条
    expect(p.tempHistory.length, 1);
    expect(p.tempHistory.single.nozzleTemp, 100.0);
  });

  test('时间戳保护丢弃旧数据时也不记录历史', () {
    final p = newPrinter();
    p.updateTelemetry({'extruder.temperature': 200.0}, eventTime: DateTime(2026, 7, 9, 10));
    // 更旧的时间戳 → 被丢弃，return false，不记录
    p.updateTelemetry({'extruder.temperature': 210.0}, eventTime: DateTime(2026, 7, 9, 9));
    expect(p.tempHistory.length, 1);
    expect(p.tempHistory.single.nozzleTemp, 200.0);
  });

  test('仅热床温度变化也会记录', () {
    final p = newPrinter();
    p.updateTelemetry({'heater_bed.temperature': 50.0});
    expect(p.tempHistory.length, 1);
    expect(p.tempHistory.single.bedTemp, 50.0);
    expect(p.tempHistory.single.nozzleTemp, 0.0);
  });
}
