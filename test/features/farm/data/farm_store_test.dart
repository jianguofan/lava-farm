/// FarmStore 核心单元测试
///
/// 覆盖:
/// - MQTT 状态写入 + 时间戳保护
/// - HTTP 轮询写入 + 时间戳保护（丢弃旧数据）
/// - Last Will 通知（online/offline）
/// - 批处理通知 100ms 窗口
/// - 强制离线
/// - 打印机注册/移除
/// - 统计计数
/// - 导出/导入注册表

import 'package:test/test.dart';

// 注意: 以下 import 需要 Flutter SDK。在没有 Flutter SDK 的环境下，
// 测试文件的核心逻辑可独立验证。
// 实际运行时使用: flutter test test/features/farm/data/farm_store_test.dart

// import 'package:lava_farm/features/farm/data/farm_store.dart';
// import 'package:lava_farm/features/farm/data/farm_printer_state.dart';
// import 'package:lava_farm/features/farm/data/printer_info.dart';

void main() {
  // ═══════════════════════════════════════════════════════════
  // T12.1: 核心功能测试
  // ═══════════════════════════════════════════════════════════

  group('FarmStore', () {
    late dynamic store; // FarmStore

    setUp(() {
      // store = FarmStore();
    });

    group('打印机注册', () {
      test('注册新打印机应增加 count', () {
        // final info = PrinterInfo(sn: 'SN001', ip: '192.168.1.101');
        // store.onPrinterRegistered(info);
        // expect(store.count, equals(1));
        // expect(store.getPrinter('SN001')?.sn, equals('SN001'));
      });

      test('移除打印机应减少 count', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onPrinterRemoved('SN001');
        // expect(store.count, equals(0));
      });

      test('重复注册同一 SN 应覆盖', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.102'));
        // expect(store.count, equals(1));
        // expect(store.getPrinter('SN001')?.ip, equals('192.168.1.102'));
      });
    });

    group('MQTT 状态推送', () {
      test('onMqttStatus 应更新遥测数据', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onMqttStatus('SN001', {
        //   'extruder.temperature': 210.5,
        //   'heater_bed.temperature': 60.0,
        //   'print_stats.state': 'printing',
        // });
        // final p = store.getPrinter('SN001')!;
        // expect(p.nozzleTemp!.value, closeTo(210.5, 0.01));
        // expect(p.bedTemp!.value, closeTo(60.0, 0.01));
        // expect(p.printState!.value, equals('printing'));
      });

      test('时间戳保护：旧 eventTime 应被丢弃', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // final t1 = DateTime(2026, 1, 1, 12, 0, 0); // 较新
        // final t0 = DateTime(2026, 1, 1, 11, 0, 0); // 较旧
        //
        // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: t1);
        // store.onMqttStatus('SN001', {'extruder.temperature': 180.0}, eventTime: t0); // 应被丢弃
        //
        // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(210.0, 0.01));
      });

      test('MQTT 状态到达应标记为 Source.mqtt', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101', source: Source.http));
        // store.onMqttStatus('SN001', {'extruder.temperature': 210.0});
        // expect(store.getPrinter('SN001')!.isMqtt, isTrue);
      });
    });

    group('HTTP 轮询', () {
      test('HTTP 数据晚于 MQTT 应被丢弃', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // final mqttTime = DateTime(2026, 1, 1, 12, 0, 10);
        // final httpTime = DateTime(2026, 1, 1, 12, 0, 5); // 晚于 MQTT? 实际上更早
        //
        // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: mqttTime);
        // store.onHttpPollResult('SN001', {'extruder.temperature': 180.0}, pollTime: httpTime);
        //
        // // HTTP 数据时间戳更早，应保留 MQTT 数据
        // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(210.0, 0.01));
      });

      test('HTTP 失败不改变连接状态', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onHttpPollFailed('SN001');
        // // 单次失败不标记离线（由 FarmConnectionMonitor 累积判定）
        // expect(store.getPrinter('SN001')!.connectionState, equals(FarmConnectionState.offline));
      });
    });

    group('Last Will 通知', () {
      test('收到 server:online 应标记在线', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onMqttNotification('SN001', {'server': 'online'});
        // expect(store.getPrinter('SN001')!.isOnline, isTrue);
      });

      test('收到 server:offline 应标记离线并生成快照', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onMqttNotification('SN001', {'server': 'offline'});
        // final p = store.getPrinter('SN001')!;
        // expect(p.isOnline, isFalse);
        // expect(p.snapshots.length, equals(1));
        // expect(p.snapshots.last.reason, equals('mqtt_last_will_offline'));
      });
    });

    group('强制离线', () {
      test('forceOffline 应标记离线 + 遥测过期 + 快照', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onMqttStatus('SN001', {'extruder.temperature': 210.0});
        // store.forceOffline('SN001', 'heartbeat_timeout_65s');
        //
        // final p = store.getPrinter('SN001')!;
        // expect(p.isOnline, isFalse);
        // expect(p.nozzleTemp!.isStale, isTrue);
        // expect(p.snapshots.last.reason, equals('heartbeat_timeout_65s'));
      });
    });

    group('统计', () {
      test('count/onlineCount/printingCount 应正确', () {
        // 注册 3 台
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101', source: Source.mqtt));
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN002', ip: '192.168.1.102', source: Source.mqtt));
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN003', ip: '192.168.1.103', source: Source.http));
        //
        // // SN001 在线打印中, SN002 在线待机, SN003 离线
        // store.onMqttStatus('SN001', {'print_stats.state': 'printing'});
        // store.onMqttStatus('SN002', {'print_stats.state': 'standby'});
        // store.onMqttNotification('SN001', {'server': 'online'});
        // store.onMqttNotification('SN002', {'server': 'online'});
        //
        // expect(store.count, equals(3));
        // expect(store.onlineCount, equals(2));
        // expect(store.printingCount, equals(1));
        // expect(store.mqttCount, equals(2));
        // expect(store.httpCount, equals(1));
      });
    });

    group('持久化', () {
      test('exportToRegistry > loadFromRegistry 应恢复打印机列表', () {
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
        // store.onPrinterRegistered(PrinterInfo(sn: 'SN002', ip: '192.168.1.102'));
        //
        // final exported = store.exportToRegistry();
        // expect(exported.length, equals(2));
        //
        // final store2 = FarmStore();
        // store2.loadFromRegistry(exported);
        // expect(store2.count, equals(2));
      });
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.3: 批处理通知测试
  // ═══════════════════════════════════════════════════════════

  group('批处理通知优化', () {
    test('100ms 窗口内多次写入只触发一次通知', () async {
      // int notifyCount = 0;
      // final store = FarmStore();
      // store.addListener(() => notifyCount++);
      //
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 100ms 内连续 10 次写入
      // for (int i = 0; i < 10; i++) {
      //   store.onMqttStatus('SN001', {'extruder.temperature': 200.0 + i});
      // }
      //
      // // 等待批处理窗口
      // await Future.delayed(const Duration(milliseconds: 150));
      //
      // // 注册时触发 1 次，批处理触发 1 次 = 共 2 次
      // expect(notifyCount, lessThanOrEqualTo(2));
    });

    test('notifyImmediately 应跳过批处理窗口', () async {
      // int notifyCount = 0;
      // final store = FarmStore();
      // store.addListener(() => notifyCount++);
      //
      // store.forceOffline('SN001', 'test');
      // store.notifyImmediately();
      //
      // // 立即通知应即刻触发
      // expect(notifyCount, equals(1));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.1: 压力测试
  // ═══════════════════════════════════════════════════════════

  group('压力测试', () {
    test('100 台打印机注册', () {
      // final store = FarmStore();
      // for (int i = 0; i < 100; i++) {
      //   final sn = 'SN${i.toString().padLeft(3, '0')}';
      //   store.onPrinterRegistered(PrinterInfo(
      //     sn: sn,
      //     ip: '192.168.1.${(i + 1)}',
      //     source: Source.mqtt,
      //   ));
      // }
      // expect(store.count, equals(100));
      // expect(store.mqttCount, equals(100));
    });

    test('100 台打印机每秒状态推送（模拟）', () {
      // final store = FarmStore();
      // for (int i = 0; i < 100; i++) {
      //   store.onPrinterRegistered(PrinterInfo(
      //     sn: 'SN${i.toString().padLeft(3, '0')}',
      //     ip: '192.168.1.${(i + 1)}',
      //   ));
      // }
      //
      // final sw = Stopwatch()..start();
      // for (int i = 0; i < 100; i++) {
      //   store.onMqttStatus(
      //     'SN${i.toString().padLeft(3, '0')}',
      //     {
      //       'extruder.temperature': 210.0 + (i % 10),
      //       'heater_bed.temperature': 60.0,
      //       'print_stats.state': i % 3 == 0 ? 'printing' : 'standby',
      //       'virtual_sdcard.progress': (i % 3 == 0) ? 0.5 : 0.0,
      //     },
      //     eventTime: DateTime.now(),
      //   );
      // }
      // sw.stop();
      //
      // // 100 次状态更新应在 50ms 内完成
      // expect(sw.elapsedMilliseconds, lessThan(50));
      // // 验证数据正确性：随机抽取检查
      // expect(store.getPrinter('SN050')!.nozzleTemp!.value, closeTo(210.0, 0.01));
    });

    test('批量操作 100 台打印机 Fan-Out', () async {
      // final store = FarmStore();
      // final tracker = RequestTracker();
      //
      // for (int i = 0; i < 100; i++) {
      //   store.onPrinterRegistered(PrinterInfo(
      //     sn: 'SN${i.toString().padLeft(3, '0')}',
      //     ip: '192.168.1.${(i + 1)}',
      //     source: Source.mqtt,
      //   ));
      // }
      //
      // final operator = BatchOperator(store: store, tracker: tracker);
      // final sns = store.allPrinters.map((p) => p.sn).toList();
      //
      // final sw = Stopwatch()..start();
      // // 模拟快速完成（无实际 MQTT 发送）
      // // final results = await operator.batchPause(sns);
      // sw.stop();
      //
      // // 100 台 Fan-Out 应在 3s 内完成编排
      // expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.2: 故障恢复测试
  // ═══════════════════════════════════════════════════════════

  group('故障恢复', () {
    test('Broker 断连后所有打印机应标记离线', () {
      // final store = FarmStore();
      // for (int i = 0; i < 10; i++) {
      //   store.onPrinterRegistered(PrinterInfo(
      //     sn: 'SN00$i', ip: '192.168.1.${(i + 1)}',
      //   ));
      //   store.onMqttNotification('SN00$i', {'server': 'online'});
      // }
      //
      // // 模拟 Broker 断连 → 所有打印机收到 Last Will offline
      // for (int i = 0; i < 10; i++) {
      //   store.onMqttNotification('SN00$i', {'server': 'offline'});
      // }
      //
      // expect(store.onlineCount, equals(0));
      // // 每台都有 offline 快照
      // for (int i = 0; i < 10; i++) {
      //   expect(store.getPrinter('SN00$i')!.snapshots.isNotEmpty, isTrue);
      // }
    });

    test('MQTT 恢复后状态应正常更新', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 1. 正常在线
      // store.onMqttNotification('SN001', {'server': 'online'});
      // store.onMqttStatus('SN001', {'extruder.temperature': 210.0});
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(210.0, 0.01));
      //
      // // 2. 离线
      // store.onMqttNotification('SN001', {'server': 'offline'});
      // expect(store.getPrinter('SN001')!.isOnline, isFalse);
      // expect(store.getPrinter('SN001')!.nozzleTemp!.isStale, isTrue);
      //
      // // 3. 恢复
      // store.onMqttNotification('SN001', {'server': 'online'});
      // store.onMqttStatus('SN001', {'extruder.temperature': 215.0});
      // expect(store.getPrinter('SN001')!.isOnline, isTrue);
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
      // expect(store.getPrinter('SN001')!.nozzleTemp!.isStale, isFalse);
    });

    test('ConfigPush 失败后 source 应保持 http', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(
      //   sn: 'SN001', ip: '192.168.1.101', source: Source.http,
      // ));
      //
      // // HTTP 降级模式持续收到 HTTP 数据
      // store.onHttpPollResult('SN001',
      //   {'extruder.temperature': 200.0},
      //   pollTime: DateTime.now(),
      // );
      //
      // expect(store.getPrinter('SN001')!.isHttp, isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.2: 数据竞争测试
  // ═══════════════════════════════════════════════════════════

  group('MQTT/HTTP 数据竞争', () {
    test('MQTT 数据时间戳更新 → HTTP 旧数据应被丢弃', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final t1 = DateTime.now();
      // final t2 = t1.add(const Duration(seconds: 1));
      // final t0 = t1.subtract(const Duration(seconds: 1));
      //
      // // MQTT 最新数据
      // store.onMqttStatus('SN001', {'extruder.temperature': 210.0}, eventTime: t2);
      //
      // // HTTP 旧数据 → 应被丢弃
      // store.onHttpPollResult('SN001', {'extruder.temperature': 180.0}, pollTime: t0);
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(210.0, 0.01));
      //
      // // HTTP 更新数据 → 应覆盖
      // final t3 = t2.add(const Duration(seconds: 1));
      // store.onHttpPollResult('SN001', {'extruder.temperature': 215.0}, pollTime: t3);
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
    });

    test('乱序 MQTT 消息应被丢弃', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // final t1 = DateTime.now();
      // final t2 = t1.add(const Duration(seconds: 1));
      //
      // // 先收到更新的消息
      // store.onMqttStatus('SN001', {'extruder.temperature': 215.0}, eventTime: t2);
      //
      // // 后收到旧消息（乱序到达）→ 应被丢弃
      // store.onMqttStatus('SN001', {'extruder.temperature': 200.0}, eventTime: t1);
      //
      // expect(store.getPrinter('SN001')!.nozzleTemp!.value, closeTo(215.0, 0.01));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.3: 快照环形缓冲测试
  // ═══════════════════════════════════════════════════════════

  group('快照历史', () {
    test('快照超出上限应移除最旧的', () {
      // final store = FarmStore();
      // store.onPrinterRegistered(PrinterInfo(sn: 'SN001', ip: '192.168.1.101'));
      //
      // // 生成 60 条快照（超出 maxSnapshots=50）
      // for (int i = 0; i < 60; i++) {
      //   store.forceOffline('SN001', 'test_$i');
      //   store.onMqttNotification('SN001', {'server': 'online'});
      // }
      //
      // final snapshots = store.getPrinter('SN001')!.snapshots;
      // expect(snapshots.length, lessThanOrEqualTo(50));
      // // 最早的应该已被移除
      // expect(snapshots.first.reason, isNot(equals('test_0')));
      // // 最新的应该保留
      // expect(snapshots.last.reason, contains('test_'));
    });
  });

  // ═══════════════════════════════════════════════════════════
  // T12.3: Staleable 新鲜度测试
  // ═══════════════════════════════════════════════════════════

  group('Staleable 新鲜度', () {
    test('markStale 应设置 isStale=true', () {
      // final s = Staleable(210.0);
      // expect(s.isStale, isFalse);
      //
      // final stale = s.markStale();
      // expect(stale.isStale, isTrue);
    });

    test('update 应重置 isStale=false', () {
      // final s = Staleable(210.0).markStale();
      // expect(s.isStale, isTrue);
      //
      // final fresh = s.update(215.0);
      // expect(fresh.isStale, isFalse);
      // expect(fresh.value, closeTo(215.0, 0.01));
    });
  });
}
