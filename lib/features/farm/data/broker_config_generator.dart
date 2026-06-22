/// Broker 配置生成器（T9.1 的 Dart 实现）
///
/// 功能等效于 deployment/generate-broker-config.sh，
/// 但在 App 内运行，由 BrokerSetupPage 调用。
///
/// 生成产物:
/// - mosquitto.conf  — 完整配置（替换模板变量后）
/// - passwd           — 用户密码文件（PBKDF2 哈希）
/// - acl              — 访问控制列表
///
/// 部署目标:
/// - Docker: 复制到 ./mosquitto/config/
/// - RPi: 复制到 /etc/mosquitto/conf.d/ + /etc/mosquitto/

import 'dart:convert';
import 'dart:math';

/// 生成的配置集合
class GeneratedBrokerConfig {
  final String mosquittoConf;
  final String passwdFile; // mosquitto_passwd 格式（容器内执行生成）
  final String aclFile;
  final String appUsername;
  final String appPassword;

  /// 打印机凭据列表: Map<sn, password>
  final Map<String, String> printerCredentials;

  const GeneratedBrokerConfig({
    required this.mosquittoConf,
    required this.passwdFile,
    required this.aclFile,
    required this.appUsername,
    required this.appPassword,
    required this.printerCredentials,
  });
}

/// Broker 配置参数
class BrokerConfigParams {
  final String appUsername;
  final int mqttPort;
  final int wsPort;
  final int maxConnections;
  final int autosaveInterval;
  final String? bindAddress;
  final List<String> printerSns; // 打印机 SN 列表

  const BrokerConfigParams({
    this.appUsername = 'lava_app',
    this.mqttPort = 1883,
    this.wsPort = 9001,
    this.maxConnections = 200,
    this.autosaveInterval = 300,
    this.bindAddress,
    this.printerSns = const [],
  });
}

/// Broker 配置生成器
///
/// 在 Dart 端完整实现，不依赖 shell 脚本。
/// 生产部署时由 BrokerSetupPage 调用，生成配置后导出让用户复制到目标机器。
class BrokerConfigGenerator {
  final BrokerConfigParams params;

  BrokerConfigGenerator(this.params);

  // ── 密码生成 ──

  /// 生成安全随机密码（base64url，无 padding）
  static String generatePassword({int bytes = 24}) {
    final random = Random.secure();
    final buffer = List<int>.generate(bytes, (_) => random.nextInt(256));
    return base64Url.encode(buffer).replaceAll('=', '');
  }

  /// 生成 mosquitto_passwd 格式的命令列表
  ///
  /// mosquitto_passwd 使用 PBKDF2 哈希，无法在纯 Dart 中生成。
  /// 因此返回 CLI 命令列表，用户在部署时执行（或 App 通过 SSH 远程执行）。
  List<String> generatePasswdCommands() {
    final commands = <String>[];

    // App 管理员
    commands.add(
      "mosquitto_passwd -b /mosquitto/config/passwd "
      "${params.appUsername} '${generatePassword()}'",
    );

    // 打印机用户
    for (final sn in params.printerSns) {
      commands.add(
        "mosquitto_passwd -b /mosquitto/config/passwd "
        "printer_$sn '${generatePassword()}'",
      );
    }

    return commands;
  }

  // ── 配置文件生成 ──

  /// 生成 mosquitto.conf
  String generateMosquittoConf() {
    final bind = params.bindAddress;
    final bindSection = (bind != null && bind.isNotEmpty) ? ' $bind' : '';

    return '''
# ═══════════════════════════════════════════════════════
# lava-farm Mosquitto Broker 配置
# 生成时间: ${DateTime.now().toUtc().toIso8601String()}
# 打印机数量: ${params.printerSns.length}
# ═══════════════════════════════════════════════════════

# ── 监听 ──
listener ${params.mqttPort}$bindSection

# WebSocket (可选)
# listener ${params.wsPort}
# protocol websockets

# ── 认证 ──
allow_anonymous false
password_file /mosquitto/config/passwd

# ── ACL ──
acl_file /mosquitto/config/acl

# ── 连接限制 ──
max_connections ${params.maxConnections}
max_inflight_messages 50
max_queued_messages 1000
max_keepalive 300
message_size_limit 512000

# ── 持久化 ──
persistence true
persistence_location /mosquitto/data/
autosave_interval ${params.autosaveInterval}
max_queued_messages 10000

# ── 日志 ──
log_dest stdout
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
connection_messages true
log_timestamp true
log_timestamp_format %Y-%m-%dT%H:%M:%S

# ── 系统监控 ──
sys_interval 10
''';
  }

  /// 生成 ACL 文件
  String generateAcl() {
    final buffer = StringBuffer();
    buffer.writeln('# lava-farm Mosquitto ACL');
    buffer.writeln('# 生成时间: ${DateTime.now().toUtc().toIso8601String()}');
    buffer.writeln();

    // App 管理客户端：全局读写
    buffer.writeln('user ${params.appUsername}');
    buffer.writeln('topic readwrite +/#');
    buffer.writeln();

    // 打印机客户端：仅操作自己的 topic
    for (final sn in params.printerSns) {
      buffer.writeln('user printer_$sn');
      buffer.writeln('topic read $sn/request');
      buffer.writeln('topic write $sn/status');
      buffer.writeln('topic write $sn/notification');
      buffer.writeln('topic write $sn/response');
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 生成凭据汇总（给用户保存）
  String generateCredentialsSummary() {
    final appPassword = generatePassword();
    final printerCreds = <String, String>{};

    final buffer = StringBuffer();
    buffer.writeln('╔══════════════════════════════════════════════╗');
    buffer.writeln('║  lava-farm MQTT Broker 凭据汇总              ║');
    buffer.writeln('╚══════════════════════════════════════════════╝');
    buffer.writeln();
    buffer.writeln('━━━ App 管理客户端 ━━━');
    buffer.writeln('用户名:   ${params.appUsername}');
    buffer.writeln('密码:     $appPassword');
    buffer.writeln('权限:     全局读写 (readwrite +/#)');
    buffer.writeln();
    buffer.writeln('━━━ 打印机客户端 (${params.printerSns.length} 台) ━━━');

    for (final sn in params.printerSns) {
      final pass = generatePassword();
      printerCreds[sn] = pass;
      buffer.writeln('  $sn:');
      buffer.writeln('    用户名: printer_$sn');
      buffer.writeln('    密码:   $pass');
      buffer.writeln();
    }

    buffer.writeln('━━━ 部署命令 ━━━');
    buffer.writeln('# Docker 部署:');
    buffer.writeln('#   将 mosquitto.conf, passwd, acl 复制到 deployment/mosquitto/config/');
    buffer.writeln('#   docker compose up -d');
    buffer.writeln();
    buffer.writeln('# RPi 部署:');
    buffer.writeln('#   sudo cp mosquitto.conf /etc/mosquitto/conf.d/lava-farm.conf');
    buffer.writeln('#   sudo systemctl reload mosquitto');
    buffer.writeln();
    buffer.writeln('⚠️  请妥善保管此文件，部署完成后建议删除');

    return buffer.toString();
  }

  /// 一键生成完整配置
  GeneratedBrokerConfig generate() {
    final appPassword = generatePassword();
    final printerCreds = <String, String>{};
    for (final sn in params.printerSns) {
      printerCreds[sn] = generatePassword();
    }

    // 生成 passwd 格式（用户名:密码对，用户部署时用 mosquitto_passwd 哈希化）
    final passwdLines = <String>[
      '${params.appUsername}:$appPassword',
    ];
    for (final entry in printerCreds.entries) {
      passwdLines.add('printer_${entry.key}:${entry.value}');
    }
    final passwdFile = passwdLines.join('\n');

    return GeneratedBrokerConfig(
      mosquittoConf: generateMosquittoConf(),
      passwdFile: passwdFile,
      aclFile: generateAcl(),
      appUsername: params.appUsername,
      appPassword: appPassword,
      printerCredentials: printerCreds,
    );
  }
}
