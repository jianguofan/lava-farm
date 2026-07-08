/// 农场异常告警模型
///
/// 从设备状态中生成、合并、跟踪的异常告警，
/// 支持置顶展示、确认和静音。
import 'package:flutter/foundation.dart';

/// 告警严重级别
enum FarmAlertSeverity {
  /// 严重：打印错误、温度异常、硬件故障
  critical,

  /// 警告：离线、心跳超时、降级
  warning,

  /// 信息：HTTP 降级提示等
  info,
}

extension FarmAlertSeverityX on FarmAlertSeverity {
  String get label {
    switch (this) {
      case FarmAlertSeverity.critical:
        return '严重';
      case FarmAlertSeverity.warning:
        return '警告';
      case FarmAlertSeverity.info:
        return '提示';
    }
  }

  /// 排序权重（数字越小越靠前）
  int get rank {
    switch (this) {
      case FarmAlertSeverity.critical:
        return 0;
      case FarmAlertSeverity.warning:
        return 1;
      case FarmAlertSeverity.info:
        return 2;
    }
  }
}

/// 告警类型（用于合并去重）
enum FarmAlertType {
  /// 打印错误（Moonraker error）
  printError,

  /// 温度异常（喷嘴/热床超限）
  temperatureAnomaly,

  /// 设备离线
  offline,

  /// 心跳超时
  heartbeatTimeout,

  /// HTTP 降级
  httpDegraded,

  /// 耗材不足
  filamentLow,

  /// 床板异物
  foreignObject,
}

extension FarmAlertTypeX on FarmAlertType {
  String get label {
    switch (this) {
      case FarmAlertType.printError:
        return '打印错误';
      case FarmAlertType.temperatureAnomaly:
        return '温度异常';
      case FarmAlertType.offline:
        return '设备离线';
      case FarmAlertType.heartbeatTimeout:
        return '心跳超时';
      case FarmAlertType.httpDegraded:
        return '连接降级';
      case FarmAlertType.filamentLow:
        return '耗材不足';
      case FarmAlertType.foreignObject:
        return '床板异物';
    }
  }

  FarmAlertSeverity get defaultSeverity {
    switch (this) {
      case FarmAlertType.printError:
      case FarmAlertType.temperatureAnomaly:
      case FarmAlertType.foreignObject:
        return FarmAlertSeverity.critical;
      case FarmAlertType.offline:
      case FarmAlertType.heartbeatTimeout:
        return FarmAlertSeverity.warning;
      case FarmAlertType.httpDegraded:
      case FarmAlertType.filamentLow:
        return FarmAlertSeverity.info;
    }
  }
}

/// 告警状态
enum FarmAlertStatus {
  /// 活跃（未处理）
  active,

  /// 已确认（操作员已知晓）
  acknowledged,

  /// 已解决（问题消失，等待过期清理）
  resolved,

  /// 已静音（临时隐藏，到期后恢复）
  muted,
}

/// 一条农场告警
@immutable
class FarmAlert {
  final String id;
  final String printerSn;
  final String? printerName;
  final FarmAlertType type;
  final FarmAlertSeverity severity;
  final FarmAlertStatus status;
  final String title;
  final String? detail;
  final DateTime createdAt;
  final DateTime lastSeenAt;
  final int count; // 合并次数
  final DateTime? acknowledgedAt;
  final DateTime? resolvedAt;
  final DateTime? mutedUntil;

  const FarmAlert({
    required this.id,
    required this.printerSn,
    this.printerName,
    required this.type,
    required this.severity,
    required this.status,
    required this.title,
    this.detail,
    required this.createdAt,
    required this.lastSeenAt,
    this.count = 1,
    this.acknowledgedAt,
    this.resolvedAt,
    this.mutedUntil,
  });

  /// 创建新告警
  factory FarmAlert.create({
    required String printerSn,
    String? printerName,
    required FarmAlertType type,
    FarmAlertSeverity? severity,
    required String title,
    String? detail,
  }) {
    final now = DateTime.now();
    return FarmAlert(
      id: '${printerSn}_${type.name}_${now.millisecondsSinceEpoch}',
      printerSn: printerSn,
      printerName: printerName,
      type: type,
      severity: severity ?? type.defaultSeverity,
      status: FarmAlertStatus.active,
      title: title,
      detail: detail,
      createdAt: now,
      lastSeenAt: now,
    );
  }

  /// 合并重复告警（同一设备、同一类型、未解决）
  FarmAlert merge(FarmAlert other) {
    assert(printerSn == other.printerSn && type == other.type);
    return copyWith(
      lastSeenAt: other.lastSeenAt.isAfter(lastSeenAt)
          ? other.lastSeenAt
          : lastSeenAt,
      count: count + other.count,
      detail: other.detail ?? detail,
      // 如果被合并的告警级别更高，提升级别
      severity: other.severity.rank < severity.rank ? other.severity : severity,
    );
  }

  FarmAlert copyWith({
    String? id,
    String? printerSn,
    String? printerName,
    FarmAlertType? type,
    FarmAlertSeverity? severity,
    FarmAlertStatus? status,
    String? title,
    String? detail,
    DateTime? createdAt,
    DateTime? lastSeenAt,
    int? count,
    DateTime? acknowledgedAt,
    DateTime? resolvedAt,
    DateTime? mutedUntil,
  }) {
    return FarmAlert(
      id: id ?? this.id,
      printerSn: printerSn ?? this.printerSn,
      printerName: printerName ?? this.printerName,
      type: type ?? this.type,
      severity: severity ?? this.severity,
      status: status ?? this.status,
      title: title ?? this.title,
      detail: detail ?? this.detail,
      createdAt: createdAt ?? this.createdAt,
      lastSeenAt: lastSeenAt ?? this.lastSeenAt,
      count: count ?? this.count,
      acknowledgedAt: acknowledgedAt ?? this.acknowledgedAt,
      resolvedAt: resolvedAt ?? this.resolvedAt,
      mutedUntil: mutedUntil ?? this.mutedUntil,
    );
  }

  /// 是否应在前端展示（未解决且未静音）
  bool get isVisible =>
      status == FarmAlertStatus.active ||
      status == FarmAlertStatus.acknowledged;

  /// 是否已静音且仍在静音期内
  bool get isMuted =>
      status == FarmAlertStatus.muted &&
      mutedUntil != null &&
      mutedUntil!.isAfter(DateTime.now());

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is FarmAlert && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
