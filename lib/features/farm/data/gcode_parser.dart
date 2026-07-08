/// G-code 产品参数解析器
///
/// 优先解析常见切片器注释；解析不到时返回可手工补全的默认值。
import 'dart:io';

import '../domain/models/product_material.dart';

class ParsedGcodeProduct {
  final String name;
  final Duration estimatedDuration;
  final double totalFilamentGrams;
  final List<ProductMaterial> materials;

  const ParsedGcodeProduct({
    required this.name,
    required this.estimatedDuration,
    required this.totalFilamentGrams,
    required this.materials,
  });
}

class GcodeParser {
  Future<ParsedGcodeProduct> parse(File file) async {
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last.replaceAll(RegExp(r'\.(gcode|g)$'), '')
        : '未命名产品';

    Duration duration = Duration.zero;
    double grams = 0;

    try {
      final content = await file.readAsString();
      final lines = content.split(RegExp(r'\r?\n')).take(3000);
      for (final line in lines) {
        duration = _parseDuration(line) ?? duration;
        grams = _parseFilamentGrams(line) ?? grams;
      }
    } catch (_) {
      // 保留默认值，允许 UI 手工补全。
    }

    final materials = grams > 0
        ? [
            ProductMaterial(
              colorName: '默认耗材',
              argb: 0xFF9E9E9E,
              grams: grams,
            )
          ]
        : const <ProductMaterial>[];

    return ParsedGcodeProduct(
      name: name,
      estimatedDuration: duration,
      totalFilamentGrams: grams,
      materials: materials,
    );
  }

  Duration? _parseDuration(String line) {
    final secondsMatch = RegExp(
      r'(?:estimated printing time|TIME|Print Time).*?([0-9]+)s',
      caseSensitive: false,
    ).firstMatch(line);
    if (secondsMatch != null) {
      return Duration(seconds: int.tryParse(secondsMatch.group(1)!) ?? 0);
    }

    final hms = RegExp(r'(\d+)h\s*(\d+)m\s*(\d+)s').firstMatch(line);
    if (hms != null) {
      return Duration(
        hours: int.parse(hms.group(1)!),
        minutes: int.parse(hms.group(2)!),
        seconds: int.parse(hms.group(3)!),
      );
    }
    return null;
  }

  double? _parseFilamentGrams(String line) {
    final match = RegExp(
      r'(?:filament.*?weight|Filament weight|filament used).*?([0-9]+(?:\.[0-9]+)?)\s*g',
      caseSensitive: false,
    ).firstMatch(line);
    if (match == null) return null;
    return double.tryParse(match.group(1)!);
  }
}
