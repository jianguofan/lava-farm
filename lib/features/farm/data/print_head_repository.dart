/// 打印头预设本地仓储
///
/// 风格与 [ProductRepository] / [ProductionHistoryRepository] 一致：
/// JSON 文件持久化（~/.lava_farm/print_heads.json）。文件缺失或解析失败时
/// 返回默认 4 头配置。
import 'dart:convert';
import 'dart:io';

import '../domain/models/print_head.dart';

class PrintHeadRepository {
  final File _storeFile;

  PrintHeadRepository({File? storeFile})
      : _storeFile = storeFile ?? _defaultStoreFile();

  static File _defaultStoreFile() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return File('$home/.lava_farm/print_heads.json');
  }

  /// 默认 4 头：PLA / 0.4mm / 四个区分色 / 全部启用。
  static List<PrintHead> defaultHeads() => const [
        PrintHead(
            index: 1,
            filamentType: 'PLA',
            argb: 0xFFFFFFFF,
            nozzleDiameter: 0.4,
            enabled: true),
        PrintHead(
            index: 2,
            filamentType: 'PLA',
            argb: 0xFF333333,
            nozzleDiameter: 0.4,
            enabled: true),
        PrintHead(
            index: 3,
            filamentType: 'PLA',
            argb: 0xFFF00000,
            nozzleDiameter: 0.4,
            enabled: true),
        PrintHead(
            index: 4,
            filamentType: 'PLA',
            argb: 0xFF0C63E2,
            nozzleDiameter: 0.4,
            enabled: true),
      ];

  Future<List<PrintHead>> loadAll() async {
    if (!await _storeFile.exists()) {
      final defaults = defaultHeads();
      await saveAll(defaults);
      return defaults;
    }
    try {
      final raw = jsonDecode(await _storeFile.readAsString()) as List;
      final heads = raw
          .whereType<Map>()
          .map((m) => PrintHead.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      if (heads.isEmpty) return defaultHeads();
      return heads;
    } catch (_) {
      return defaultHeads();
    }
  }

  Future<void> saveAll(List<PrintHead> heads) async {
    await _storeFile.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await _storeFile.writeAsString(
      encoder.convert(heads.map((h) => h.toJson()).toList()),
    );
  }
}
