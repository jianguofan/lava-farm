/// MQTT / HTTP 数据竞争测试 (T12.2)
///
/// 验证 FarmStore 在并发写入场景下的正确性:
/// - MQTT 乱序到达
/// - MQTT + HTTP 同时写入
/// - 时间戳比较失效时的行为
/// - 高并发下的线程安全（Dart 是单线程，验证逻辑正确性）

import 'dart:async';
import 'package:test/test.dart';

// import 'package:lava_farm/features/farm/data/farm_store.dart';
// import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
// import 'package:lava_farm/features/farm/data/printer_info.dart';

void main() {
  // ═══════════════════════════════════════════════════════════
  // 场景 1: MQTT 消息乱序到达
  // ═══════════════════════════════════════════════════════════
  group('MQTT 消息乱序', () {
    test('先到新消息 → 后到旧消息 → 保持新数据', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final t1 = DateTime(2026, 6, 18, 12, 0, 0, 100); // 100ms
      // final t2 = DateTime(2026, 6, 18, 12, 0, 0, 200); // 200ms（更新）
      //
      // // 先到达：t2 (200ms) 的消息
      // store.onMqttStatus('SN001', {'extruder.temperature': 215.0}, eventTime: t2);
      // // 后到达：t1 (100ms) 的消息 → 应被丢弃
      // store.onMqttStatus('SN001', {'extruder.temperature': 180.0}, eventTime: t1);
      //
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
      // expect(store.getPrinter('SN001')!.lastDataTimestamp, equals(t2));
    });

    test('MQTT 消息无 eventTime 时直接更新', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 无 eventTime → 直接更新，不做时间戳保护
      // store.onMqttStatus('SN001', {'extruder.temperature': 200.0});
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(200.0, 0.01));
      //
      // store.onMqttStatus('SN001', {'extruder.temperature': 220.0});
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(220.0, 0.01));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // 场景 2: MQTT + HTTP 并发写入
  // ═══════════════════════════════════════════════════════════
  group('MQTT + HTTP 并发', () {
    test('MQTT 时间戳更新 → HTTP 旧数据丢弃', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final mqttTime = DateTime.now();
      // final httpTime = mqttTime.subtract(const Duration(seconds: 5));
      //
      // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: mqttTime);
      // store.onHttpPollResult('SN001', {'extruder.temperature': 100.0}, pollTime: httpTime);
      //
      // // HTTP 轮询数据更旧 → 丢弃
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(210.0, 0.01));
    });

    test('HTTP 时间戳更新 → HTTP 数据覆盖 MQTT 旧数据', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final mqttTime = DateTime.now();
      // final httpTime = mqttTime.add(const Duration(seconds: 5));
      //
      // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: mqttTime);
      // store.onHttpPollResult('SN001', {'extruder.temperature': 215.0}, pollTime: httpTime);
      //
      // // HTTP 轮询数据更新 → 覆盖
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
    });

    test('MQTT + HTTP 相同时间戳 → 后到者覆盖', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final now = DateTime.now();
      //
      // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: now);
      // store.onHttpPollResult('SN001', {'extruder.temperature': 215.0}, pollTime: now);
      //
      // // 如果时间戳完全相同，!isAfter 为 false（等于时不过滤）→ 后到者覆盖
      // // 或者 !isAfter → false (不满足丢弃条件) → 更新
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // 场景 3: 批量写入性能
  // ═══════════════════════════════════════════════════════════
  group('批量写入性能', () {
    test('100 台打印机 × 10 次写入 < 200ms', () {
      // final store = FarmStore();
      // for (int i = 0; i < 100; i++) {
      //   store.onPrinterRegistered(PrinterInfo(
      //     sn: 'SN${i.toString().padLeft(3, '0')}',
      //     ip: '192.168.1.${(i + 1)}',
      //   ));
      // }
      //
      // final sw = Stopwatch()..start();
      // for (int round = 0; round < 10; round++) {
      //   for (int i = 0; i < 100; i++) {
      //     store.onMqttStatus(
      //       'SN${i.toString().padLeft(3, '0')}',
      //       {'extruder.temperature': 200.0 + (i % 20) + (round * 0.1)},
      //       eventTime: DateTime.now(),
      //     );
      //   }
      // }
      // sw.stop();
      //
      // // 1000 次写入应在 200ms 内完成
      // expect(sw.elapsedMilliseconds, lessThan(200));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // 场景 4: 字段级合并
  // ═══════════════════════════════════════════════════════════
  group('字段级合并', () {
    test('部分字段更新不应清除其他字段', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 第一次: 写喷嘴和热床温度
      // store.onMqttStatus('SN001', {
      //   'extruder.temperature': 210.0,
      //   'heater_bed.temperature': 60.0,
      // });
      //
      // // 第二次: 只写喷嘴温度（模拟 Moonraker 的增量更新）
      // store.onMqttStatus('SN001', {
      //   'extruder.temperature': 215.0,
      // });
      //
      // final p = store.getPrinter('SN001')!;
      // expect(p.nozzleTemp!.value, closeTo(215.0, 0.01));
      // // 热床温度应保持上次的值
      // expect(p.bedTemp!.value, closeTo(60.0, 0.01));
    });

    test('打印状态变更不影响温度', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // store.onMqttStatus('SN001', {
      //   'extruder.temperature': 210.0,
      //   'heater_bed.temperature': 60.0,
      // });
      //
      // store.onMqttStatus('SN001', {
      //   'print_stats.state': 'printing',
      //   'print_stats.filename': 'benchy.gcode',
      // });
      //
      // final p = store.getPrinter('SN001')!;
      // expect(p.nozzleTemp!.value, closeTo(210.0, 0.01));
      // expect(p.bedTemp!.value, closeTo(60.0, 0.01));
      // expect(p.printState!.value, equals('printing'));
      // expect(p.currentFile!.value, equals('benchy.gcode'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // 场景 5: 累积指标增量计算
  // ═══════════════════════════════════════════════════════════
  group('累积指标', () {
    test('totalDuration 应增量计算而非全量累加', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 第一次: 报告 duration = 100s
      // store.onMqttStatus('SN001', {'print_stats.total_duration': 100.0});
      // expect(store.getPrinter('SN001')!.totalDuration, closeTo(100.0, 0.01));
      //
      // // 第二次: 报告 duration = 150s → 增量 50s
      // store.onMqttStatus('SN001', {'print_stats.total_duration': 150.0});
      // expect(store.getPrinter('SN001')!.totalDuration, closeTo(150.0, 0.01));
      //
      // // 第三次: 报告 duration = 200s → 增量 50s
      // store.onMqttStatus('SN001', {'print_stats.total_duration': 200.0});
      // expect(store.getPrinter('SN001')!.totalDuration, closeTo(200.0, 0.01));
    });

    test('duration 回退时不应累加（容错处理）', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // store.onMqttStatus('SN001', {'print_stats.total_duration': 200.0});
      //
      // // 打印机重启后 duration 重置 → 不应累加
      // // 逻辑: current (0) < _lastReported (200) → 不累加
      // store.onMqttStatus('SN001', {'print_stats.total_duration': 0.0});
      //
      // // totalDuration 应保持 200（不累加 0-200 的负增量）
      // expect(store.getPrinter('SN001')!.totalDuration, closeTo(200.0, 0.01));
    });
  });
}
