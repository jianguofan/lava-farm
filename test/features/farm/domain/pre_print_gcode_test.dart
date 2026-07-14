/// buildExtruderMapGcode 单元测试
import 'package:flutter_test/flutter_test.dart';
import 'package:lava_farm/features/farm/domain/models/product_material.dart';
import 'package:lava_farm/features/farm/domain/services/pre_print_gcode.dart';

void main() {
  test('无已分配耗材返回 null', () {
    expect(buildExtruderMapGcode(const []), isNull);
    expect(
      buildExtruderMapGcode([
        ProductMaterial(
            colorName: 'PLA', argb: 0xFFFFFFFF, grams: 1, extruderIndex: 1),
      ]),
      isNull,
    );
  });

  test('生成 0-based 映射行 + 去重排序的 USED_EXTRUDERS', () {
    final gcode = buildExtruderMapGcode([
      ProductMaterial(
          colorName: 'PLA',
          argb: 0xFFFFFFFF,
          grams: 1,
          extruderIndex: 1,
          assignedHead: 3),
      ProductMaterial(
          colorName: 'PLA',
          argb: 0xFFFFFFFF,
          grams: 1,
          extruderIndex: 2,
          assignedHead: 1),
      ProductMaterial(
          colorName: 'PLA',
          argb: 0xFFFFFFFF,
          grams: 1,
          extruderIndex: 3,
          assignedHead: 3),
    ]);
    expect(gcode, isNotNull);
    final lines = gcode!.trim().split('\n');
    expect(
        lines,
        contains(
            'SET_PRINT_EXTRUDER_MAP CONFIG_EXTRUDER=0 MAP_EXTRUDER=2')); // slice1→head3
    expect(
        lines,
        contains(
            'SET_PRINT_EXTRUDER_MAP CONFIG_EXTRUDER=1 MAP_EXTRUDER=0')); // slice2→head1
    expect(
        lines,
        contains(
            'SET_PRINT_EXTRUDER_MAP CONFIG_EXTRUDER=2 MAP_EXTRUDER=2')); // slice3→head3
    // 去重：head1(0) 与 head3(2) → "0,2"
    expect(lines.last, 'SET_PRINT_USED_EXTRUDERS EXTRUDERS=0,2');
  });

  test('跳过无 extruderIndex 的耗材', () {
    final gcode = buildExtruderMapGcode([
      ProductMaterial(
          colorName: 'PLA', argb: 0xFFFFFFFF, grams: 1, assignedHead: 1),
    ]);
    expect(gcode, isNull); // 无 slice id，无法生成映射行
  });
}
