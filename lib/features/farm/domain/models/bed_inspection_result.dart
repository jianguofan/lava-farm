/// 床板异物检测结果
///
/// 映射 LLM 视觉分析返回的 JSON schema。
/// 由 BedInspectionService 解析后存入 provider，供 UI 消费。
library bed_inspection_result;

/// 组件检测状态
class InspectionComponent {
  final bool detected;
  final double confidence;

  const InspectionComponent({
    required this.detected,
    required this.confidence,
  });

  factory InspectionComponent.fromJson(Map<String, dynamic> json) {
    return InspectionComponent(
      detected: json['detected'] as bool? ?? false,
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() => {
        'detected': detected,
        'confidence': confidence,
      };
}

/// 异物信息
class BedForeignObjects {
  final bool hasObjects;
  final String description;

  const BedForeignObjects({
    required this.hasObjects,
    required this.description,
  });

  factory BedForeignObjects.fromJson(Map<String, dynamic> json) {
    return BedForeignObjects(
      hasObjects: json['has_objects'] as bool? ?? false,
      description: json['description'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'has_objects': hasObjects,
        'description': description,
      };
}

/// 打印就绪判断
class PrintReadiness {
  final bool isReady;
  final bool caution;
  final String reason;
  final String recommendedAction;

  const PrintReadiness({
    required this.isReady,
    required this.caution,
    required this.reason,
    required this.recommendedAction,
  });

  factory PrintReadiness.fromJson(Map<String, dynamic> json) {
    return PrintReadiness(
      isReady: json['is_ready'] as bool? ?? false,
      caution: json['caution'] as bool? ?? false,
      reason: json['reason'] as String? ?? '',
      recommendedAction: json['recommended_action'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
        'is_ready': isReady,
        'caution': caution,
        'reason': reason,
        'recommended_action': recommendedAction,
      };

  /// 推荐操作的中文描述
  String get recommendedActionLabel {
    switch (recommendedAction) {
      case 'proceed':
        return '可直接打印';
      case 'clean_and_proceed':
        return '清理后可打印';
      case 'remove_objects_and_proceed':
        return '移除异物后可打印';
      case 'manual_inspection_required':
        return '需人工检查';
      default:
        return recommendedAction;
    }
  }
}

/// 检测组件集合
class InspectionComponents {
  final InspectionComponent printBed;
  final InspectionComponent printHead;
  final InspectionComponent casing;

  const InspectionComponents({
    required this.printBed,
    required this.printHead,
    required this.casing,
  });

  factory InspectionComponents.fromJson(Map<String, dynamic> json) {
    return InspectionComponents(
      printBed: InspectionComponent.fromJson(
          (json['print_bed'] as Map<String, dynamic>?) ?? {}),
      printHead: InspectionComponent.fromJson(
          (json['print_head'] as Map<String, dynamic>?) ?? {}),
      casing: InspectionComponent.fromJson(
          (json['casing'] as Map<String, dynamic>?) ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'print_bed': printBed.toJson(),
        'print_head': printHead.toJson(),
        'casing': casing.toJson(),
      };
}

/// 床板异物检测完整结果
class BedInspectionResult {
  final String sn;
  final String timestamp;
  final InspectionComponents components;
  final BedForeignObjects bedForeignObjects;
  final PrintReadiness printReadiness;

  const BedInspectionResult({
    this.sn = '',
    required this.timestamp,
    required this.components,
    required this.bedForeignObjects,
    required this.printReadiness,
  });

  factory BedInspectionResult.fromJson(Map<String, dynamic> json) {
    final inspection = json['inspection'] as Map<String, dynamic>? ?? {};
    return BedInspectionResult(
      sn: inspection['sn'] as String? ?? '',
      timestamp: inspection['timestamp'] as String? ?? '',
      components: InspectionComponents.fromJson(
          (inspection['components'] as Map<String, dynamic>?) ?? {}),
      bedForeignObjects: BedForeignObjects.fromJson(
          (inspection['bed_foreign_objects'] as Map<String, dynamic>?) ?? {}),
      printReadiness: PrintReadiness.fromJson(
          (inspection['print_readiness'] as Map<String, dynamic>?) ?? {}),
    );
  }

  Map<String, dynamic> toJson() => {
        'inspection': {
          'sn': sn,
          'timestamp': timestamp,
          'components': components.toJson(),
          'bed_foreign_objects': bedForeignObjects.toJson(),
          'print_readiness': printReadiness.toJson(),
        },
      };

  /// 是否有异物
  bool get hasForeignObjects => bedForeignObjects.hasObjects;

  /// 是否可直接打印
  bool get isReadyToPrint => printReadiness.isReady;

  /// 打印就绪状态的可读摘要
  String get statusSummary {
    if (hasForeignObjects) {
      return '⚠ ${bedForeignObjects.description}';
    }
    if (isReadyToPrint) {
      return printReadiness.caution ? '⚠ 可打印（注意）' : '✓ 床板干净';
    }
    return '✗ ${printReadiness.reason}';
  }
}
