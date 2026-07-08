/// 产品/模型定义
///
/// 产品定义是投产流程的输入：把 G-code / 3MF 文件、缩略图、
/// 机型、生产时长、单盘数量和耗材信息沉淀为可复用记录。
import 'product_material.dart';

class ProductDefinition {
  final String id;
  final String name;
  final int version;
  final String machineModel;
  final Duration estimatedDuration;
  final double totalFilamentGrams;
  final int plateQuantity;
  final List<ProductMaterial> materials;
  final String sourceFilePath;
  final String? thumbnailPath;
  final DateTime createdAt;
  final DateTime updatedAt;

  const ProductDefinition({
    required this.id,
    required this.name,
    required this.version,
    required this.machineModel,
    required this.estimatedDuration,
    required this.totalFilamentGrams,
    required this.plateQuantity,
    required this.materials,
    required this.sourceFilePath,
    this.thumbnailPath,
    required this.createdAt,
    required this.updatedAt,
  });

  String get displayName => version <= 1 ? name : '$name v$version';

  ProductDefinition copyWith({
    String? id,
    String? name,
    int? version,
    String? machineModel,
    Duration? estimatedDuration,
    double? totalFilamentGrams,
    int? plateQuantity,
    List<ProductMaterial>? materials,
    String? sourceFilePath,
    String? thumbnailPath,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return ProductDefinition(
      id: id ?? this.id,
      name: name ?? this.name,
      version: version ?? this.version,
      machineModel: machineModel ?? this.machineModel,
      estimatedDuration: estimatedDuration ?? this.estimatedDuration,
      totalFilamentGrams: totalFilamentGrams ?? this.totalFilamentGrams,
      plateQuantity: plateQuantity ?? this.plateQuantity,
      materials: materials ?? this.materials,
      sourceFilePath: sourceFilePath ?? this.sourceFilePath,
      thumbnailPath: thumbnailPath ?? this.thumbnailPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  factory ProductDefinition.fromJson(Map<String, dynamic> json) {
    return ProductDefinition(
      id: json['id'] as String,
      name: json['name'] as String? ?? '未命名产品',
      version: (json['version'] as num?)?.toInt() ?? 1,
      machineModel: json['machineModel'] as String? ?? 'U1',
      estimatedDuration: Duration(
        seconds: (json['estimatedDurationSeconds'] as num?)?.toInt() ?? 0,
      ),
      totalFilamentGrams:
          (json['totalFilamentGrams'] as num?)?.toDouble() ?? 0,
      plateQuantity: (json['plateQuantity'] as num?)?.toInt() ?? 1,
      materials: (json['materials'] as List? ?? const [])
          .whereType<Map>()
          .map((m) => ProductMaterial.fromJson(Map<String, dynamic>.from(m)))
          .toList(),
      sourceFilePath: json['sourceFilePath'] as String? ?? '',
      thumbnailPath: json['thumbnailPath'] as String?,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'version': version,
        'machineModel': machineModel,
        'estimatedDurationSeconds': estimatedDuration.inSeconds,
        'totalFilamentGrams': totalFilamentGrams,
        'plateQuantity': plateQuantity,
        'materials': materials.map((m) => m.toJson()).toList(),
        'sourceFilePath': sourceFilePath,
        'thumbnailPath': thumbnailPath,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };
}
