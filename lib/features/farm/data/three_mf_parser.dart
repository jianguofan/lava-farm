/// Gcode.3MF 产品参数解析器
///
/// 阶段一先提供可用的文件级 fallback；后续在此处补充 ZIP/XML 解析，
/// 提取 plate、材料和缩略图。
import 'dart:io';

import 'gcode_parser.dart';

class ThreeMfParser {
  Future<ParsedGcodeProduct> parse(File file) async {
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last.replaceAll(RegExp(r'\.3mf$'), '')
        : '未命名产品';

    return ParsedGcodeProduct(
      name: name,
      estimatedDuration: Duration.zero,
      totalFilamentGrams: 0,
      materials: const [],
    );
  }
}
