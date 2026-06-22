/// Docker Mosquitto Broker 管理器
///
/// 通过 Docker Compose 管理 Mosquitto MQTT Broker 的完整生命周期。
/// 替代旧的 MqttBrokerManager（内嵌子进程）和 DeploymentMigrationService（模式迁移）。
///
/// 职责:
/// - 检测 Docker 是否可用
/// - 初始化 ~/.lava-farm/broker/ 目录 + 生成配置文件
/// - docker compose up/down/restart
/// - 运行时管理打印机凭据（ACL 追加 + 热重载）

import 'dart:io';

import 'broker_config_generator.dart';

/// Docker Mosquitto Broker 管理器
class DockerBrokerManager {
  static const String _containerName = 'lava-farm-broker';

  /// 运行时目录
  static String get runtimeDir {
    final home = Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '/tmp';
    return '$home/.lava-farm/broker';
  }

  static String get configDir => '$runtimeDir/mosquitto/config';
  static String get dataDir => '$runtimeDir/mosquitto/data';
  static String get logDir => '$runtimeDir/mosquitto/log';

  // ═══════════════════════════════════════════════════════════
  // Docker 可用性检测
  // ═══════════════════════════════════════════════════════════

  /// 检测 Docker 是否可用
  Future<bool> isDockerAvailable() async {
    try {
      final result = await Process.run('docker', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 检测 Docker Compose 是否可用（v2: `docker compose`）
  Future<bool> isComposeAvailable() async {
    try {
      final result = await Process.run('docker', ['compose', 'version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  // ═══════════════════════════════════════════════════════════
  // 初始化
  // ═══════════════════════════════════════════════════════════

  /// 检查是否已初始化
  bool get isInitialized =>
      File('$runtimeDir/docker-compose.yml').existsSync();

  /// 初始化 Broker（首次启动调用）
  ///
  /// 1. 创建目录结构
  /// 2. 写入 docker-compose.yml
  /// 3. 写入 mosquitto.conf
  /// 4. 生成 passwd（管理员用户）
  /// 5. 写入 acl
  Future<void> initialize() async {
    // 1. 创建目录
    await Directory(configDir).create(recursive: true);
    await Directory(dataDir).create(recursive: true);
    await Directory(logDir).create(recursive: true);

    // 2. 写入 docker-compose.yml
    await File('$runtimeDir/docker-compose.yml')
        .writeAsString(_composeFileContent);

    // 3. 写入 mosquitto.conf
    await File('$configDir/mosquitto.conf')
        .writeAsString(_mosquittoConfContent);

    // 4. 生成管理员凭据并写入 passwd
    final appPassword =
        BrokerConfigGenerator.generatePassword();
    await File('$configDir/passwd').writeAsString(
      'lava_app:$appPassword\n',
    );

    // 5. 写入初始 ACL
    await File('$configDir/acl').writeAsString(_aclBaseContent);

    // 保存管理员凭据供后续使用（调用方负责持久化到 CredentialStore）
  }

  // ═══════════════════════════════════════════════════════════
  // 生命周期
  // ═══════════════════════════════════════════════════════════

  /// 启动 Broker 容器
  Future<void> start() => _compose('up', ['-d']);

  /// 停止 Broker 容器
  Future<void> stop() => _compose('down');

  /// 重启 Broker（配置变更后）
  Future<void> restart() => _compose('restart');

  /// Broker 是否在运行
  Future<bool> isRunning() async {
    try {
      final result = await Process.run(
        'docker',
        ['ps', '--filter', 'name=$_containerName', '--format', '{{.Status}}'],
      );
      return result.exitCode == 0 &&
          (result.stdout as String).contains('Up');
    } catch (_) {
      return false;
    }
  }

  /// 获取容器日志（最近 N 行）
  Future<String> getLogs({int lines = 50}) async {
    final result = await Process.run('docker', [
      'logs',
      '--tail',
      lines.toString(),
      _containerName,
    ]);
    return result.exitCode == 0
        ? (result.stdout as String)
        : '无法获取日志';
  }

  // ═══════════════════════════════════════════════════════════
  // 打印机凭据管理（运行时追加，不中断服务）
  // ═══════════════════════════════════════════════════════════

  /// 入网时新增打印机凭据
  ///
  /// 1. 在容器内执行 mosquitto_passwd 追加用户
  /// 2. 追加 ACL 条目
  /// 3. 发送 SIGHUP 热重载配置
  Future<void> addPrinterCredential({
    required String sn,
    required String username,
    required String password,
  }) async {
    // 1. 追加 passwd
    await Process.run('docker', [
      'exec',
      _containerName,
      'mosquitto_passwd',
      '-b',
      '/mosquitto/config/passwd',
      username,
      password,
    ]);

    // 2. 追加 acl
    final aclEntry = '''
user $username
topic read $sn/request
topic write $sn/status
topic write $sn/notification
topic write $sn/response

''';
    await File('$configDir/acl').writeAsString(
      aclEntry,
      mode: FileMode.append,
    );

    // 3. 热重载（不中断现有连接）
    await _reloadConfig();
  }

  /// 删除打印机凭据
  Future<void> removePrinterCredential(String username, String sn) async {
    // 1. 从 passwd 删除用户
    await Process.run('docker', [
      'exec',
      _containerName,
      'mosquitto_passwd',
      '-D',
      '/mosquitto/config/passwd',
      username,
    ]);

    // 2. 从 acl 删除对应段
    final aclFile = File('$configDir/acl');
    if (await aclFile.exists()) {
      final acl = await aclFile.readAsString();
      final pattern = RegExp(
        'user $username\\n'
        r'(?:topic (?:read|write) [^\n]+\n)+',
        multiLine: true,
      );
      final updated = acl.replaceAll(pattern, '');
      await aclFile.writeAsString(updated);
    }

    // 3. 热重载
    await _reloadConfig();
  }

  /// 向所有注册打印机重新推送凭据（配置变更场景）
  Future<void> regenerateAllCredentials(
    List<String> printerSns, {
    required Map<String, String> snToUsername,
  }) async {
    // 重新生成 passwd 文件
    final buffer = StringBuffer();
    buffer.writeln('lava_app:${BrokerConfigGenerator.generatePassword()}');

    // 重新生成 acl
    final aclBuffer = StringBuffer(_aclBaseContent);

    for (final sn in printerSns) {
      final username = snToUsername[sn] ?? 'printer_$sn';
      final password = BrokerConfigGenerator.generatePassword();
      buffer.writeln('$username:$password');

      aclBuffer.writeln('user $username');
      aclBuffer.writeln('topic read $sn/request');
      aclBuffer.writeln('topic write $sn/status');
      aclBuffer.writeln('topic write $sn/notification');
      aclBuffer.writeln('topic write $sn/response');
      aclBuffer.writeln();
    }

    await File('$configDir/passwd').writeAsString(buffer.toString());
    await File('$configDir/acl').writeAsString(aclBuffer.toString());

    // 热重载
    await _reloadConfig();
  }

  // ═══════════════════════════════════════════════════════════
  // 配置模板（内置于 App 中）
  // ═══════════════════════════════════════════════════════════

  /// docker-compose.yml 模板
  static String get _composeFileContent => '''
version: '3.8'

services:
  mosquitto:
    image: eclipse-mosquitto:2.0
    container_name: $_containerName
    restart: always
    network_mode: host
    volumes:
      - ./mosquitto/config:/mosquitto/config:ro
      - ./mosquitto/data:/mosquitto/data
      - ./mosquitto/log:/mosquitto/log
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test:
        [
          "CMD",
          "mosquitto_sub",
          "-h",
          "localhost",
          "-t",
          "\$\$SYS/#",
          "-C",
          "1",
          "-W",
          "3"
        ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
''';

  /// mosquitto.conf 模板
  static String get _mosquittoConfContent => '''
# lava-farm Mosquitto Broker 配置
# 由 App 自动生成，用户无需手动编辑

# 监听所有网卡
listener 1883

# 认证
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl

# 连接限制
max_connections 200
max_inflight_messages 50
max_queued_messages 10000

# 持久化
persistence true
persistence_location /mosquitto/data/
autosave_interval 300

# Keepalive
max_keepalive 300

# 日志
log_dest file /mosquitto/log/mosquitto.log
log_type error
log_type warning
log_type notice
connection_messages true
''';

  /// ACL 基础模板（不含打印机用户 — 入网时动态追加）
  static String get _aclBaseContent => '''# lava-farm Mosquitto ACL
# 打印机用户由 App 在入网时自动追加

# App 管理客户端：全局读写
user lava_app
topic readwrite +/#

''';

  // ═══════════════════════════════════════════════════════════
  // 内部方法
  // ═══════════════════════════════════════════════════════════

  /// 热重载配置（发送 SIGHUP 到 mosquitto 进程）
  Future<void> _reloadConfig() async {
    final running = await isRunning();
    if (!running) return;

    await Process.run('docker', [
      'exec',
      _containerName,
      'kill',
      '-HUP',
      '1',
    ]);
  }

  /// 执行 docker compose 命令
  Future<String> _compose(String command, [List<String>? args]) async {
    final fullArgs = ['compose', command, ...?args];
    final result = await Process.run(
      'docker',
      fullArgs,
      workingDirectory: runtimeDir,
    );
    return result.exitCode == 0
        ? (result.stdout as String)
        : 'Error: ${result.stderr}';
  }
}
