/// 投产历史本地仓储
///
/// JSON 文件持久化，保持与 `ProductRepository` 一致的风格。
/// 历史按开始时间倒序保存，超过 [maxRecords] 时丢弃最旧记录。
import 'dart:convert';
import 'dart:io';

import '../domain/models/production_record.dart';

class ProductionHistoryRepository {
  final File _storeFile;
  final int maxRecords;

  ProductionHistoryRepository({
    File? storeFile,
    this.maxRecords = 500,
  }) : _storeFile = storeFile ?? _defaultStoreFile();

  static File _defaultStoreFile() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return File('$home/.lava_farm/production_history.json');
  }

  Future<List<ProductionRecord>> loadAll() async {
    if (!await _storeFile.exists()) return [];
    try {
      final raw = jsonDecode(await _storeFile.readAsString()) as List;
      final records = raw
          .whereType<Map>()
          .map((m) =>
              ProductionRecord.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      records.sort((a, b) => b.startedAt.compareTo(a.startedAt));
      return records;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<ProductionRecord> records) async {
    await _storeFile.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await _storeFile.writeAsString(
      encoder.convert(records.map((r) => r.toJson()).toList()),
    );
  }

  /// 追加（或按 id 更新）一条投产记录，保持倒序并裁剪到 [maxRecords]。
  Future<void> add(ProductionRecord record) async {
    final records = await loadAll();
    final idx = records.indexWhere((r) => r.id == record.id);
    if (idx >= 0) {
      records[idx] = record;
    } else {
      records.add(record);
    }
    records.sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (records.length > maxRecords) {
      records.removeRange(maxRecords, records.length);
    }
    await saveAll(records);
  }

  Future<void> clear() async {
    await saveAll(const []);
  }
}
