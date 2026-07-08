/// 产品材料定义
///
/// 描述一个产品打印所需的单种耗材颜色与重量。
class ProductMaterial {
  final String colorName;
  final int argb;
  final double grams;
  final int? extruderIndex;

  const ProductMaterial({
    required this.colorName,
    required this.argb,
    required this.grams,
    this.extruderIndex,
  });

  factory ProductMaterial.fromJson(Map<String, dynamic> json) {
    return ProductMaterial(
      colorName: json['colorName'] as String? ?? '未知颜色',
      argb: json['argb'] as int? ?? 0xFF9E9E9E,
      grams: (json['grams'] as num?)?.toDouble() ?? 0,
      extruderIndex: (json['extruderIndex'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() => {
        'colorName': colorName,
        'argb': argb,
        'grams': grams,
        'extruderIndex': extruderIndex,
      };

  ProductMaterial copyWith({
    String? colorName,
    int? argb,
    double? grams,
    int? extruderIndex,
  }) {
    return ProductMaterial(
      colorName: colorName ?? this.colorName,
      argb: argb ?? this.argb,
      grams: grams ?? this.grams,
      extruderIndex: extruderIndex ?? this.extruderIndex,
    );
  }
}
