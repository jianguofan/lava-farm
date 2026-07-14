/// 打印前耗材→打印头映射 G-code 生成
///
/// 对应 lava_app `setPrePrintConfiguration`（lava_device_viewmodel.dart:3969）
/// 下发的设备 G-code。固件据此把切片文件里的逻辑挤出机（slice filament id）
/// 映射到物理打印头。索引沿用 lava_app 的 0-based 约定（真机如为 1-based，
/// 只需改本文件）：
///   - CONFIG_EXTRUDER = sliceId - 1   （ProductMaterial.extruderIndex - 1）
///   - MAP_EXTRUDER    = head - 1      （ProductMaterial.assignedHead - 1）
library pre_print_gcode;

import '../models/product_material.dart';

/// 生成耗材映射 G-code；没有任何已分配耗材时返回 null（不下发）。
String? buildExtruderMapGcode(List<ProductMaterial> materials) {
  final assigned = materials.where((m) => m.assignedHead != null).toList();
  if (assigned.isEmpty) return null;

  final buf = StringBuffer();
  final usedHeads = <int>{};

  for (final m in assigned) {
    final sliceId = m.extruderIndex;
    if (sliceId == null) continue; // 无 slice 槽位无法映射
    final configExtruder = sliceId - 1; // 0-based
    final mapExtruder = m.assignedHead! - 1; // 0-based
    usedHeads.add(mapExtruder);
    buf.writeln(
        'SET_PRINT_EXTRUDER_MAP CONFIG_EXTRUDER=$configExtruder MAP_EXTRUDER=$mapExtruder');
  }

  if (buf.isEmpty) return null;

  final used = (usedHeads.toList()..sort()).join(',');
  buf.writeln('SET_PRINT_USED_EXTRUDERS EXTRUDERS=$used');
  return buf.toString();
}
