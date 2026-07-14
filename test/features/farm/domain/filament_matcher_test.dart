/// FilamentMatcher / 耗材→打印头匹配 单元测试
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/domain/models/print_head.dart';
import 'package:lava_farm/features/farm/domain/models/product_material.dart';
import 'package:lava_farm/features/farm/domain/services/filament_matcher.dart';

const _white = 0xFFFFFFFF;
const _black = 0xFF000000;
const _red = 0xFFFF0000;
const _blue = 0xFF0000FF;

PrintHead _head(int i, int argb,
        {String type = 'PLA', double nozzle = 0.4, bool enabled = true}) =>
    PrintHead(
        index: i,
        filamentType: type,
        argb: argb,
        nozzleDiameter: nozzle,
        enabled: enabled);

void main() {
  group('colorDistance (CIEDE2000)', () {
    test('同色距离为 0', () {
      expect(colorDistance(const Color(_red), const Color(_red)), 0);
    });
    test('黑白差异远大于近似红', () {
      final bw = colorDistance(const Color(_black), const Color(_white));
      final rr = colorDistance(const Color(_red), const Color(0xFFFF0808));
      expect(bw, greaterThan(50));
      expect(rr, lessThan(10));
    });
  });

  group('findMatchingExtruder', () {
    test('精确颜色命中立即返回对应头', () {
      final heads = [_head(1, _white), _head(2, _black), _head(3, _red)];
      final match = findMatchingExtruder(
        type: 'PLA',
        color: const Color(_black),
        heads: heads,
      );
      expect(match, 2);
    });
    test('类型不匹配返回 null', () {
      final heads = [_head(1, _red, type: 'PETG')];
      expect(
        findMatchingExtruder(
            type: 'PLA', color: const Color(_red), heads: heads),
        isNull,
      );
    });
    test('无精确色时取色距最小者', () {
      final heads = [_head(1, _blue), _head(2, _red)]; // 红更接近粉红
      final match = findMatchingExtruder(
        type: 'PLA',
        color: const Color(0xFFFF0080), // 偏红粉
        heads: heads,
      );
      expect(match, 2);
    });
    test('跳过未启用的头', () {
      final heads = [_head(1, _red, enabled: false), _head(2, _blue)];
      final match = findMatchingExtruder(
        type: 'PLA',
        color: const Color(_red),
        heads: heads,
      );
      expect(match, 2); // 头1禁用，落到头2
    });
    test('喷嘴不一致则跳过', () {
      final heads = [_head(1, _red, nozzle: 0.6), _head(2, _red, nozzle: 0.4)];
      final match = findMatchingExtruder(
        type: 'PLA',
        color: const Color(_red),
        nozzle: 0.4,
        heads: heads,
      );
      expect(match, 2);
    });
  });

  group('assignHeads', () {
    test('有效耗材(grams>0)匹配，未用耗材(grams==0)置空', () {
      final mats = [
        ProductMaterial(
            colorName: 'PLA', argb: _red, grams: 10, extruderIndex: 1),
        ProductMaterial(
            colorName: 'PLA', argb: _blue, grams: 0, extruderIndex: 2),
      ];
      final heads = [_head(1, _red), _head(2, _blue)];
      final out = assignHeads(mats, heads);
      expect(out[0].assignedHead, 1);
      expect(out[1].assignedHead, isNull);
    });
  });
}
