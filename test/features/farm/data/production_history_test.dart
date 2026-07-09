// 投产历史持久化测试
import 'dart:io';

import 'package:lava_farm/features/farm/data/production_history_repository.dart';
import 'package:lava_farm/features/farm/domain/models/production_record.dart';
import 'package:test/test.dart';

ProductionRecord _record({
  required String id,
  String productId = 'p1',
  String productName = 'Demo',
  List<String> sns = const ['SN1', 'SN2'],
  int success = 2,
  int failed = 0,
  DateTime? startedAt,
}) {
  final start = startedAt ?? DateTime(2026, 7, 9, 10);
  return ProductionRecord(
    id: id,
    productId: productId,
    productName: productName,
    fileName: 'demo.3mf',
    printerSns: sns,
    successCount: success,
    failedCount: failed,
    failures: const {},
    printPlate: 1,
    startedAt: start,
    finishedAt: start.add(const Duration(minutes: 5)),
  );
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('prod_history_test_');
  });

  tearDown(() {
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  ProductionHistoryRepository newRepo() {
    final file = File('${tempDir.path}/history.json');
    return ProductionHistoryRepository(storeFile: file);
  }

  test('loadAll 空文件返回空列表', () async {
    final repo = newRepo();
    expect(await repo.loadAll(), isEmpty);
  });

  test('saveAll -> loadAll 往返一致', () async {
    final repo = newRepo();
    final records = [
      _record(id: 'r1', startedAt: DateTime(2026, 7, 9, 10)),
      _record(id: 'r2', startedAt: DateTime(2026, 7, 9, 11)),
    ];
    await repo.saveAll(records);

    final loaded = await repo.loadAll();
    expect(loaded.length, 2);
    expect(loaded.map((r) => r.id).toSet(), {'r1', 'r2'});
  });

  test('add 追加并按开始时间倒序', () async {
    final repo = newRepo();
    await repo.add(_record(id: 'r1', startedAt: DateTime(2026, 7, 9, 10)));
    await repo.add(_record(id: 'r2', startedAt: DateTime(2026, 7, 9, 12)));
    await repo.add(_record(id: 'r3', startedAt: DateTime(2026, 7, 9, 11)));

    final loaded = await repo.loadAll();
    expect(loaded.map((r) => r.id).toList(), ['r2', 'r3', 'r1']);
  });

  test('clear 清空历史', () async {
    final repo = newRepo();
    await repo.add(_record(id: 'r1'));
    await repo.clear();
    expect(await repo.loadAll(), isEmpty);
  });

  test('删减超过上限的旧记录', () async {
    final repo = ProductionHistoryRepository(
      storeFile: File('${tempDir.path}/history.json'),
      maxRecords: 3,
    );
    for (var i = 0; i < 5; i++) {
      await repo.add(_record(
        id: 'r$i',
        startedAt: DateTime(2026, 7, 9, 8 + i),
      ));
    }
    final loaded = await repo.loadAll();
    expect(loaded.length, 3);
    // 保留最近 3 条：r2, r3, r4
    expect(loaded.map((r) => r.id).toSet(), {'r2', 'r3', 'r4'});
  });

  test('失败明细序列化往返', () async {
    final repo = newRepo();
    final start = DateTime(2026, 7, 9, 10);
    final record = ProductionRecord(
      id: 'r1',
      productId: 'p1',
      productName: 'Demo',
      fileName: 'demo.3mf',
      printerSns: const ['SN1', 'SN2'],
      successCount: 1,
      failedCount: 1,
      failures: const {'SN2': '上传超时'},
      printPlate: 2,
      startedAt: start,
      finishedAt: start.add(const Duration(seconds: 30)),
    );
    await repo.add(record);

    final loaded = (await repo.loadAll()).single;
    expect(loaded.failedCount, 1);
    expect(loaded.failures['SN2'], '上传超时');
    expect(loaded.printPlate, 2);
  });
}
