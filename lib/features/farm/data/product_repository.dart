/// 产品库本地仓储
///
/// 当前使用 JSON 文件持久化，保持接口独立，后续可替换为 drift/sqflite。
import 'dart:convert';
import 'dart:io';

import '../domain/models/product_definition.dart';
import 'gcode_parser.dart';
import 'three_mf_parser.dart';

class ProductRepository {
  final File _storeFile;
  final GcodeParser _gcodeParser;
  final ThreeMfParser _threeMfParser;

  ProductRepository({
    File? storeFile,
    GcodeParser? gcodeParser,
    ThreeMfParser? threeMfParser,
  })  : _storeFile = storeFile ?? _defaultStoreFile(),
        _gcodeParser = gcodeParser ?? GcodeParser(),
        _threeMfParser = threeMfParser ?? ThreeMfParser();

  static File _defaultStoreFile() {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return File('$home/.lava_farm/products.json');
  }

  Future<List<ProductDefinition>> loadAll() async {
    if (!await _storeFile.exists()) return [];
    try {
      final raw = jsonDecode(await _storeFile.readAsString()) as List;
      final products = raw
          .whereType<Map>()
          .map((m) => ProductDefinition.fromJson(Map<String, dynamic>.from(m)))
          .toList();
      products.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return products;
    } catch (_) {
      return [];
    }
  }

  Future<void> saveAll(List<ProductDefinition> products) async {
    await _storeFile.parent.create(recursive: true);
    const encoder = JsonEncoder.withIndent('  ');
    await _storeFile.writeAsString(
      encoder.convert(products.map((p) => p.toJson()).toList()),
    );
  }

  Future<ProductDefinition> importFile(File file) async {
    final existing = await loadAll();
    final parsed = file.path.toLowerCase().endsWith('.3mf')
        ? await _threeMfParser.parse(file)
        : await _gcodeParser.parse(file);

    final version = _nextVersion(existing, parsed.name);
    final now = DateTime.now();
    final product = ProductDefinition(
      id: '${now.microsecondsSinceEpoch}',
      name: parsed.name,
      version: version,
      machineModel: 'U1',
      estimatedDuration: parsed.estimatedDuration,
      totalFilamentGrams: parsed.totalFilamentGrams,
      plateQuantity: 1,
      materials: parsed.materials,
      sourceFilePath: file.path,
      createdAt: now,
      updatedAt: now,
    );

    await saveAll([product, ...existing]);
    return product;
  }

  Future<void> upsert(ProductDefinition product) async {
    final products = await loadAll();
    final index = products.indexWhere((p) => p.id == product.id);
    final updated = product.copyWith(updatedAt: DateTime.now());
    if (index >= 0) {
      products[index] = updated;
    } else {
      products.insert(0, updated);
    }
    await saveAll(products);
  }

  Future<void> delete(String id) async {
    final products = await loadAll();
    products.removeWhere((p) => p.id == id);
    await saveAll(products);
  }

  int _nextVersion(List<ProductDefinition> products, String name) {
    final versions = products.where((p) => p.name == name).map((p) => p.version);
    if (versions.isEmpty) return 1;
    return versions.reduce((a, b) => a > b ? a : b) + 1;
  }
}
