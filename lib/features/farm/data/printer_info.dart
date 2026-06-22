/// 打印机基础信息模型
///
/// 在发现、入网、注册各阶段共享的数据结构。
/// 从发现结果 (DiscoveredPrinter) 转换为注册信息 (PrinterInfo)。

/// 通信来源
enum Source {
  /// MQTT 主力通道
  mqtt,

  /// HTTP 降级通道
  http,
}

extension SourceDisplay on Source {
  String get label {
    switch (this) {
      case Source.mqtt: return 'MQTT';
      case Source.http: return 'HTTP';
    }
  }

  bool get isMqtt => this == Source.mqtt;
  bool get isHttp => this == Source.http;
}

/// 打印机连接状态
enum FarmConnectionState {
  online,
  offline,
  configuring,  // 正在推送配置
  restarting,   // Moonraker 重启中
  degraded,     // 延迟高但可通
}

extension FarmConnectionStateDisplay on FarmConnectionState {
  bool get isOnline => this == FarmConnectionState.online;
  bool get isOffline => this == FarmConnectionState.offline;

  String get label {
    switch (this) {
      case FarmConnectionState.online:      return '在线';
      case FarmConnectionState.offline:     return '离线';
      case FarmConnectionState.configuring: return '配置中';
      case FarmConnectionState.restarting:  return '重启中';
      case FarmConnectionState.degraded:     return '降级';
    }
  }
}

/// 打印机注册信息（持久化到 Hive）
class PrinterInfo {
  final String sn;
  String? displayName;
  final String ip;
  final int port;
  String? group;
  final Source source;
  String? model;
  String? firmwareVersion;
  String? apiKey; // Moonraker API Key (Access Token)

  PrinterInfo({
    required this.sn,
    this.displayName,
    required this.ip,
    this.port = 7125,
    this.group,
    this.source = Source.mqtt,
    this.model,
    this.firmwareVersion,
    this.apiKey,
  });

  /// 从原始发现数据创建（IP 必填，SN 可选）
  factory PrinterInfo.fromDiscovery({
    required String ip,
    String? sn,
    int port = 7125,
    String? hostname,
    String? model,
    String? firmwareVersion,
    Source source = Source.mqtt,
    String? apiKey,
  }) {
    return PrinterInfo(
      sn: sn ?? ip.replaceAll('.', '_'),
      displayName: hostname ?? sn ?? ip,
      ip: ip,
      port: port,
      model: model,
      firmwareVersion: firmwareVersion,
      source: source,
      apiKey: apiKey,
    );
  }

  /// 唯一标识
  String get id => sn;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PrinterInfo && sn == other.sn;

  @override
  int get hashCode => sn.hashCode;

  @override
  String toString() => 'PrinterInfo(sn: $sn, ip: $ip, source: ${source.label})';
}
