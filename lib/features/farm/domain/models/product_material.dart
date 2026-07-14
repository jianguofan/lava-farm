/// 产品材料定义
///
/// 描述一个产品打印所需的单种耗材颜色与重量。
class ProductMaterial {
  final String colorName;
  final int argb;
  final double grams;
  final int? extruderIndex;

  /// 分配到的物理打印头编号（1-based，1..4）；null=未分配。
  /// 由 [FilamentMatcher] 自动匹配或用户手动选择，用于下发映射 G-code。
  final int? assignedHead;

  const ProductMaterial({
    required this.colorName,
    required this.argb,
    required this.grams,
    this.extruderIndex,
    this.assignedHead,
  });

  factory ProductMaterial.fromJson(Map<String, dynamic> json) {
    return ProductMaterial(
      colorName: json['colorName'] as String? ?? '未知颜色',
      argb: json['argb'] as int? ?? 0xFF9E9E9E,
      grams: (json['grams'] as num?)?.toDouble() ?? 0,
      extruderIndex: (json['extruderIndex'] as num?)?.toInt(),
      assignedHead: (json['assignedHead'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'colorName': colorName,
        'argb': argb,
        'grams': grams,
        'extruderIndex': extruderIndex,
        'assignedHead': assignedHead,
      };

  ProductMaterial copyWith({
    String? colorName,
    int? argb,
    double? grams,
    int? extruderIndex,
    int? assignedHead,
  }) {
    return ProductMaterial(
      colorName: colorName ?? this.colorName,
      argb: argb ?? this.argb,
      grams: grams ?? this.grams,
      extruderIndex: extruderIndex ?? this.extruderIndex,
      assignedHead: assignedHead ?? this.assignedHead,
    );
  }
}
