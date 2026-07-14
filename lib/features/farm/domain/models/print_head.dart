/// 打印头预设
///
/// 描述机台一个物理打印头当前装载的耗材：颜色、类型、喷嘴直径。
/// 全局一套（默认 4 个头），持久化在 ~/.lava_farm/print_heads.json。
/// 用于耗材→打印头的自动匹配（[FilamentMatcher]）与展示。
class PrintHead {
  /// 1-based 打印头编号（1..4）
  final int index;

  /// 耗材类型，如 "PLA" / "PETG"（匹配时必须一致）
  final String filamentType;

  /// 装载耗材颜色（ARGB，0xFFRRGGBB）
  final int argb;

  /// 喷嘴直径（mm），匹配时若与文件喷嘴不符则跳过
  final double nozzleDiameter;

  /// 是否启用（已装载）。未启用的头不参与匹配
  final bool enabled;

  const PrintHead({
    required this.index,
    required this.filamentType,
    required this.argb,
    required this.nozzleDiameter,
    required this.enabled,
  });

  factory PrintHead.fromJson(Map<String, dynamic> json) {
    return PrintHead(
      index: (json['index'] as num?)?.toInt() ?? 1,
      filamentType: json['filamentType'] as String? ?? 'PLA',
      argb: (json['argb'] as num?)?.toInt() ?? 0xFF9E9E9E,
      nozzleDiameter: (json['nozzleDiameter'] as num?)?.toDouble() ?? 0.4,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
        'index': index,
        'filamentType': filamentType,
        'argb': argb,
        'nozzleDiameter': nozzleDiameter,
        'enabled': enabled,
      };

  PrintHead copyWith({
    int? index,
    String? filamentType,
    int? argb,
    double? nozzleDiameter,
    bool? enabled,
  }) {
    return PrintHead(
      index: index ?? this.index,
      filamentType: filamentType ?? this.filamentType,
      argb: argb ?? this.argb,
      nozzleDiameter: nozzleDiameter ?? this.nozzleDiameter,
      enabled: enabled ?? this.enabled,
    );
  }
}
