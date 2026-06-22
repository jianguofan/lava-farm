# Lava Farm 架构文档

> Flutter 桌面端局域网 3D 打印机群控系统 — 最多 100 台 Snapmaker Moonraker
>
> **架构原则**：Broker 独立于 App，App 是纯客户端。部署简单不等于架构简单。

---

## 目录

- [1. 系统边界与目标](#1-系统边界与目标)
- [2. 整体架构](#2-整体架构)
- [3. 部署模型](#3-部署模型)
- [4. 通信层：MQTT + HTTP 双通道](#4-通信层mqtt--http-双通道)
- [5. Broker 连接管理](#5-broker-连接管理)
- [6. 打印机入网流程](#6-打印机入网流程)
- [7. FarmStore：多设备状态聚合](#7-farmstore多设备状态聚合)
- [8. 批量操作引擎](#8-批量操作引擎)
- [9. 文件分发](#9-文件分发)
- [10. 安全设计](#10-安全设计)
- [11. 连接监控与故障恢复](#11-连接监控与故障恢复)
- [12. UI 架构与数据流](#12-ui-架构与数据流)
- [13. 完整数据流时序](#13-完整数据流时序)
- [14. 目录结构](#14-目录结构)
- [15. 关键类接口定义](#15-关键类接口定义)

---

## 1. 系统边界与目标

### 1.1 系统定位

```
┌──────────────────────────────────────────────────────────────────┐
│                        Lava Farm 系统                             │
│                                                                   │
│  ┌─────────────────────────┐    ┌──────────────────────────────┐ │
│  │  Mosquitto Broker       │    │  lava-farm Desktop App       │ │
│  │  独立部署，固定 IP       │    │  Flutter (macOS/Win/Linux)   │ │
│  │  7×24 运行              │    │  纯 MQTT 客户端 + HTTP 降级  │ │
│  │  认证 + ACL             │    │  可随时开关，不影响打印       │ │
│  └────────┬────────────────┘    └─────────────┬────────────────┘ │
│           │          MQTT (主力通道)           │                  │
│           │  ←── +/status, +/notification     │                  │
│           │  ──→ {SN}/request                  │                  │
│           │  ←── {SN}/response                 │                  │
│           │                                    │                  │
│           │          HTTP (降级 + 文件)         │                  │
│           │  ←── GET :7125/printer/objects/query                  │
│           │  ──→ POST :7125/printer/...        │                  │
│           │  ──→ POST :7125/server/files/upload│                  │
│           │                                    │                  │
│  ┌────────┴────────┐                           │                  │
│  │ 打印机 1..100   │                           │                  │
│  │ Moonraker MQTT  │                           │                  │
│  │ → 连接 Broker   │                           │                  │
│  └─────────────────┘                           │                  │
└──────────────────────────────────────────────────────────────────┘
```

### 1.2 核心架构决策

| 决策项      | 选择                                                       | 理由                                                             |
| ----------- | ---------------------------------------------------------- | ---------------------------------------------------------------- |
| 主力通信    | MQTT (Mosquitto)                                           | 100 台规模下唯一实时推送方案；通配符 `+/status` 一条订阅监控全部 |
| Broker 部署 | Docker 容器（独立于 App）                                  | 打印任务持续数小时，App 关闭不影响打印；restart: always 保证 7×24 |
| 降级通道    | HTTP 轮询 (Moonraker :7125)                                | 打印机拒绝远程改配置时的保底方案                                 |
| 配置下发    | Moonraker `/server/config` API                             | 远程改配置，不碰设备文件系统                                     |
| 状态管理    | FarmStore (单入口模式)                                     | 复用 DeviceMetadataStore 设计理念                                |
| 安全        | 用户名密码 + ACL                                           | 局域网不等于可信网络，基本安全是架构级需求                       |
| UI 框架     | Flutter + Riverpod                                         | 与现有项目一致                                                   |
| SDK 复用    | lava_device_sdk (MoonrakerAdapter, MqttTransport, JsonRpc) | 协议层逻辑不变                                                   |

### 1.3 规模指标

| 指标                        | 目标值                                                        |
| --------------------------- | ------------------------------------------------------------- |
| 最大打印机数                | 100 台                                                        |
| MQTT 状态延迟               | < 1 秒                                                        |
| 批量暂停 50 台              | < 3 秒全部响应                                                |
| HTTP 降级轮询间隔           | 3s (活动) / 15s (空闲) / 30s (离线) — 需降级打印机数量 ≤ 100% |
| 批量上传 1 个 GCode → 10 台 | < 30 秒                                                       |
| Broker 崩溃恢复             | Mosquitto 自身 `autosave_interval` + 重启策略，App 自动重连   |
| 打印机断电 → App 检测       | < 3 秒 (Last Will)                                            |
| App 崩溃恢复                | Broker 不受影响；App 重启后自动重连并恢复状态                 |

---

## 2. 整体架构

### 2.1 分层架构图

```
┌──────────────────────────────────────────────────────────────────┐
│  UI 层 (lib/features/farm/presentation/)                          │
│  ┌────────────┐ ┌──────────────┐ ┌────────────┐ ┌─────────────┐ │
│  │Dashboard   │ │DiscoveryWiz  │ │BatchPanel  │ │PrinterDetail│ │
│  │打印机网格   │ │设备发现向导   │ │批量操作面板 │ │单机详情页    │ │
│  └─────┬──────┘ └──────┬───────┘ └─────┬──────┘ └──────┬──────┘ │
│        └───────────────┴───────────────┴───────────────┘         │
│                        │ ref.watch / ref.read                    │
├────────────────────────┼─────────────────────────────────────────┤
│  应用层 (lib/features/farm/application/providers/)                │
│  ┌─────────────────────┴───────────────────────────────────────┐ │
│  │ farmStoreProvider      ← StateNotifier<Map<sn, FarmPrinter>> │ │
│  │ brokerStateProvider    ← StreamProvider<BrokerConnState>     │ │
│  │ discoveryProvider      ← StateNotifier<DiscoveryState>       │ │
│  │ printerListProvider    ← Provider<List<FarmPrinter>>         │ │
│  │ farmStatsProvider      ← Provider<FarmStats>                 │ │
│  │ batchOperationProvider ← StateNotifier<BatchOpState>         │ │
│  │ httpFallbackProvider   ← Provider<List<FarmPrinter>>         │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                        │                                          │
├────────────────────────┼─────────────────────────────────────────┤
│  数据层 (lib/features/farm/data/)                                  │
│                                                                   │
│  ┌──────────────────────┴──────────────────────────────────────┐ │
│  │                    FarmStore ⭐                               │ │
│  │  "所有状态变更的唯一入口，所有 UI 读取的唯一出口"               │ │
│  │  Map<String, FarmPrinterState> _printers                     │ │
│  │                                                              │ │
│  │  写入方法 (数据源 → Store):                                   │ │
│  │    onMqttStatus(sn, payload)      ← MQTT +/status 消息       │ │
│  │    onMqttNotification(sn, data)   ← MQTT +/notification      │ │
│  │    onHttpPollResult(sn, data)     ← HTTP 轮询结果            │ │
│  │    onPrinterRegistered(info)      ← 入网完成                  │ │
│  │    onPrinterRemoved(sn)           ← 用户删除                  │ │
│  │    onBatchResult(sn, result)      ← 批量操作完成              │ │
│  │    forceOffline(sn, reason)       ← 连接监控判定离线          │ │
│  │                                                              │ │
│  │  中间件: 时间戳比较 · 字段合并 · 来源标记 · staleness · 快照   │ │
│  │                                                              │ │
│  │  读取出口:                                                    │ │
│  │    allPrinters, getPrinter(sn), getByGroup, getByState       │ │
│  │    onlineCount, printingCount, mqttCount, httpCount          │ │
│  └──────────────────────────────────────────────────────────────┘ │
│                                                                   │
│  ┌─────────────────────┐  ┌───────────────────────────────────┐  │
│  │BrokerConnectionMgr  │  │ FarmMqttRouter                    │  │
│  │ • 连接外部 Broker   │  │ • +/status → onMqttStatus         │  │
│  │ • 自动重连          │  │ • +/notification → onMqttNotif    │  │
│  │ • 认证凭据管理      │  │ • {sn}/response → RequestTracker  │  │
│  │ • 连接健康监控      │  │ • {sn}/request ← 命令发布         │  │
│  └─────────────────────┘  └───────────────────────────────────┘  │
│                                                                   │
│  ┌─────────────────────┐  ┌─────────────────────┐                │
│  │ ConfigPushService   │  │ BatchOperator       │                │
│  │ • POST /server/conf │  │ • Fan-Out 并发      │                │
│  │ • POST /server/rest │  │ • Semaphore(20)     │                │
│  │ • 等待上线验证       │  │ • 优先级队列        │                │
│  │ • 后台升级重试       │  │ • 超时 + 结果聚合    │                │
│  └─────────────────────┘  └─────────────────────┘                │
│                                                                   │
│  ┌─────────────────────┐  ┌─────────────────────┐                │
│  │ PrinterDiscovery    │  │ HttpPoller           │                │
│  │ • mDNS + TCP 扫描   │  │ • 请求队列(20并发)   │                │
│  └─────────────────────┘  │ • 自适应间隔         │                │
│                           │ • 后台 MQTT 升级尝试  │                │
│                           └─────────────────────┘                │
│                                                                   │
│  ┌─────────────────────┐  ┌─────────────────────┐                │
│  │ BrokerHealthMonitor │  │ CredentialStore      │                │
│  │ • 周期性 Ping 探测  │  │ • Broker 凭据持久化  │                │
│  │ • 假活检测          │  │ • 安全存储           │                │
│  │ • 降级通知          │  └─────────────────────┘                │
│  └─────────────────────┘                                         │
├──────────────────────────────────────────────────────────────────┤
│  SDK 层 (复用 lava_device_sdk)                                    │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │ MoonrakerAdapter  │  MqttTransport  │  JsonRpcRequest      │  │
│  │ 解析 notify_status │  MQTT v5 客户端  │  {"jsonrpc":"2.0",  │  │
│  │ _update 格式       │  connect/publish │   "method":"...",   │  │
│  │ _expandStatus()    │  /subscribe      │   "params":{...}}   │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘
```

### 2.2 与现有单机架构的关系

```
lava_device_sdk (共享协议层)
    │
    ├──→ flutter_zero_copy (单机 App)
    │    使用: DeviceClient, DeviceSessionImpl, DeviceMetadataStore
    │    特点: 一次只激活一台打印机
    │
    └──→ lava-farm (群控 App)  ← 本项目
         使用: MoonrakerAdapter, MqttTransport, JsonRpc
         新建: FarmStore, BrokerConnectionManager, BatchOperator, FarmHub
         特点: 100 台打印机同时在线，通过独立 Broker 聚合
```

### 2.3 单机 vs 群控的关键差异

| 维度          | 单机 (flutter_zero_copy)       | 群控 (lava-farm)                                      |
| ------------- | ------------------------------ | ----------------------------------------------------- |
| Store 键      | `Map<String, DeviceMetadata>`  | `Map<String, FarmPrinterState>`                       |
| 活跃设备数    | 1 (DeviceSessionImpl.activate) | N (全部，最多 100)                                    |
| MQTT 连接模型 | 每设备独立连接                 | 1 条连接到外部 Broker + 通配符订阅                    |
| Broker 管理   | 不涉及（连打印机直连）         | 连接外部 Broker，不管理 Broker 生命周期               |
| 写入来源      | MQTT, Cloud, Registry          | MQTT Broker, HTTP Poller, Discovery                   |
| 命令发送      | DeviceImpl.sendCommand         | BatchOperator.fanOut (MQTT/HTTP 双通道路由)           |
| 部署依赖      | 无                             | 需要 Docker 运行 Mosquitto 容器                       |

---

## 3. 部署模型


lava-farm 通过 Docker 管理 Mosquitto Broker。不维护内嵌子进程模式，不维护裸机安装脚本。
所有平台统一使用 `docker compose`。

**核心理念**：App 是纯 MQTT 客户端。Broker 作为 Docker 容器独立运行，`restart: always` 保证 7×24 可用。
App 可以随时关闭，打印不受影响。

```
┌──────────────────────────────────────────────────────────────┐
│                    lava-farm 部署                             │
│                                                              │
│  ┌──────────────────────────┐     ┌──────────────────────┐  │
│  │  Mosquitto Broker         │     │  lava-farm App       │  │
│  │  Docker 容器              │     │  Flutter Desktop     │  │
│  │  restart: always          │◄───►│  纯 MQTT 客户端      │  │
│  │  network_mode: host       │ MQTT│  可按需启停          │  │
│  │                           │     │                      │  │
│  │  运行时目录:               │     │  职责:               │  │
│  │  ~/.lava-farm/broker/     │     │  • 首次启动: 写配置  │  │
│  │    ├── docker-compose.yml │     │  • docker compose up │  │
│  │    ├── mosquitto/         │     │  • 连接 Broker       │  │
│  │    │   ├── config/        │     │  • 打印机入网        │  │
│  │    │   ├── data/          │     │  • 监控 & 控制       │  │
│  │    │   └── log/           │     │                      │  │
│  └──────────────────────────┘     └──────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### 3.2 首次启动流程

用户安装 lava-farm 桌面应用后，首次启动时自动完成 Broker 初始化：

```
Step 1: 检测 Docker
  App 启动 → 执行 `docker --version`
  ├─ 已安装 → 继续
  └─ 未安装 → 提示用户安装 Docker Desktop / Docker Engine
              macOS: 引导至 https://docs.docker.com/desktop/mac/install/
              Windows: 引导至 https://docs.docker.com/desktop/windows/install/
              Linux: 提示 apt install docker.io docker-compose-v2

Step 2: 生成配置
  App 创建 ~/.lava-farm/broker/ 目录结构
  ├── docker-compose.yml     ← 写入（见 3.3）
  └── mosquitto/
      └── config/
          ├── mosquitto.conf ← 写入（见 3.4）
          ├── passwd         ← 生成（含 lava_app 管理员用户 + 各打印机用户）
          └── acl            ← 生成（按 SN 隔离 topic 权限）

Step 3: 启动 Broker
  cd ~/.lava-farm/broker && docker compose up -d
  → 容器以 restart: always 启动
  → 之后即使重启宿主机，Broker 也会自动恢复

Step 4: App 连接
  App 以 lava_app 用户 + 密码连接 localhost:1883
  → 后续所有操作通过此 MQTT 连接
```

### 3.3 docker-compose.yml（App 内置模板）

App 不依赖外部 `deployment/` 目录。首次启动时将以下内容写入 `~/.lava-farm/broker/docker-compose.yml`：

```yaml
version: '3.8'

services:
  mosquitto:
    image: eclipse-mosquitto:2.0
    container_name: lava-farm-broker
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
          "$$SYS/#",
          "-C",
          "1",
          "-W",
          "3"
        ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

**关键设计决策**：

| 决策 | 选择 | 理由 |
|------|------|------|
| `network_mode: host` | 是 | 零 NAT 开销，打印机直连宿主机 IP。单实例部署，无需端口映射 |
| `restart: always` | 是 | 宿主机重启 / Docker 重启后 Broker 自动恢复，实现 7×24 |
| 配置 `:ro` 挂载 | 是 | 防止容器内篡改配置，只能通过 App 修改 |
| healthcheck | 是 | Docker 自动检测 Broker 健康状态，异常时可触发告警 |
| `max-size: 10m` | 是 | 日志轮转，防止磁盘写满 |
| 运行时目录 | `~/.lava-farm/broker/` | 用户家目录下，Docker 可访问 |

### 3.4 mosquitto.conf（App 内置模板）

```ini
# ═══ lava-farm Mosquitto Broker 配置 ═══
# 由 App 自动生成，用户无需手动编辑

# 监听所有网卡，端口 1883
listener 1883

# 认证
allow_anonymous false
password_file /mosquitto/config/passwd
acl_file /mosquitto/config/acl

# 连接限制
max_connections 200
max_inflight_messages 50
max_queued_messages 10000

# 持久化 — Broker 重启后恢复会话
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
```

### 3.5 ACL 模板（App 自动生成）

```ini
# lava-farm ACL — 由 App 在首次启动 + 每次入网时自动生成

# App 管理客户端：全局 topic 读写
user lava_app
topic readwrite +/#

# 每台打印机：仅操作自己的 topic（入网时自动追加）
# user printer_8110026B060740017
# topic read 8110026B060740017/request
# topic write 8110026B060740017/status
# topic write 8110026B060740017/notification
# topic write 8110026B060740017/response
```

### 3.6 App 端 Broker 生命周期管理

所有 Docker 操作统一封装在 `DockerBrokerManager` 类中：

```dart
class DockerBrokerManager {
  /// 运行时目录
  static String get runtimeDir =>
    '${Platform.environment['HOME']}/.lava-farm/broker';

  /// 检测 Docker 是否可用
  Future<bool> isDockerAvailable() async {
    try {
      final result = await Process.run('docker', ['--version']);
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// 初始化 Broker（首次启动调用）
  /// 1. 创建目录结构
  /// 2. 写入 docker-compose.yml
  /// 3. 写入 mosquitto.conf
  /// 4. 生成 passwd（管理员 + 初始打印机）
  /// 5. 写入 acl
  /// 6. docker compose up -d
  Future<void> initialize() async {
    // 1. 创建目录
    await Directory('$runtimeDir/mosquitto/config').create(recursive: true);
    await Directory('$runtimeDir/mosquitto/data').create(recursive: true);
    await Directory('$runtimeDir/mosquitto/log').create(recursive: true);

    // 2-5. 写入配置文件
    await _writeComposeFile();
    await _writeMosquittoConf();
    await _generatePasswordFile();
    await _writeAclFile();

    // 6. 启动
    await _compose('up', ['-d']);
  }

  /// 启动 Broker
  Future<void> start() => _compose('up', ['-d']);

  /// 停止 Broker
  Future<void> stop() => _compose('down');

  /// 重启 Broker（配置变更后）
  Future<void> restart() => _compose('restart');

  /// 获取 Broker 状态
  Future<bool> isRunning() async {
    final result = await _compose('ps', ['--format', 'json']);
    return result.contains('"Running"');
  }

  /// 新增打印机凭据（入网时调用）
  Future<void> addPrinterCredential({
    required String sn,
    required String username,
    required String password,
  }) async {
    // 1. 追加 passwd
    await Process.run('docker', [
      'exec', 'lava-farm-broker',
      'mosquitto_passwd', '-b',
      '/mosquitto/config/passwd',
      username, password,
    ]);

    // 2. 追加 acl
    final acl = '''
user $username
topic read $sn/request
topic write $sn/status
topic write $sn/notification
topic write $sn/response

''';
    await File('$runtimeDir/mosquitto/config/acl').writeAsString(acl, mode: FileMode.append);

    // 3. 重载配置（不中断服务）
    await Process.run('docker', ['exec', 'lava-farm-broker', 'kill', '-HUP', '1']);
  }

  /// 移除打印机凭据
  Future<void> removePrinterCredential(String username) async {
    // 从 passwd 删除用户
    await Process.run('docker', [
      'exec', 'lava-farm-broker',
      'mosquitto_passwd', '-D',
      '/mosquitto/config/passwd', username,
    ]);

    // 从 acl 删除对应段
    final acl = await File('$runtimeDir/mosquitto/config/acl').readAsString();
    final updated = acl.replaceAll(
      RegExp(r'user $username\n(?:topic (?:read|write) .+\n)+', multiLine: true),
      '',
    );
    await File('$runtimeDir/mosquitto/config/acl').writeAsString(updated);

    // 重载
    await Process.run('docker', ['exec', 'lava-farm-broker', 'kill', '-HUP', '1']);
  }

  // ── 内部辅助 ──

  Future<void> _writeComposeFile() async { /* 写入 3.3 的 yaml */ }
  Future<void> _writeMosquittoConf() async { /* 写入 3.4 的 conf */ }
  Future<void> _generatePasswordFile() async { /* mosquitto_passwd 生成 */ }
  Future<void> _writeAclFile() async { /* 写入 3.5 的 acl */ }

  Future<String> _compose(String command, [List<String>? args]) async {
    final result = await Process.run(
      'docker', ['compose', command, ...?args],
      workingDirectory: runtimeDir,
    );
    return result.stdout.toString();
  }
}
```

### 3.7 启动流程图

```
lava-farm App 启动
      │
      ▼
  Docker 可用？
      │
  ┌───┴───┐
  │ 否    │ 是
  ▼       ▼
显示      ~/.lava-farm/broker/
安装      docker-compose.yml
引导      存在？
页面          │
          ┌───┴───┐
          │ 否    │ 是（已初始化）
          ▼       ▼
    首次启动流程    docker compose up -d
    (3.2 Step 2-3)  (确保容器在运行)
          │         │
          └────┬────┘
               ▼
     App 连接 localhost:1883
     (lava_app 用户 + 密码)
               │
               ▼
         正常运行
```

**为什么 Docker 是唯一方案？**

- **零运维负担**：`restart: always` 自动处理崩溃恢复、宿主机重启
- **跨平台一致**：macOS / Windows / Linux 完全相同的部署方式
- **不管理子进程**：无需 `Process.start('mosquitto')` 的复杂性（信号处理、僵尸进程、崩溃重启、平台差异）
- **安全**：容器天然隔离，ACL + 认证内建
- **不维护裸机方案**：RPi 也能跑 Docker；`apt install mosquitto` 的用户也能 `apt install docker.io`
- **5MB 镜像**：`eclipse-mosquitto:2.0` 极小，启动 < 1 秒

**需要从当前代码中移除的内容**：

| 移除项 | 文件 | 原因 |
|--------|------|------|
| `MqttBrokerManager` | `mqtt_broker_manager.dart` | 内嵌子进程方案，被 DockerBrokerManager 替代 |
| `BrokerMode.embedded` 及相关 | `broker_mode.dart` | 不再需要模式切换 |
| `DeploymentMigrationService` | `deployment_migration_service.dart` | 无迁移场景 |
| `BrokerConfigGenerator` 手动导出 | `broker_config_generator.dart` | 简化为 DockerBrokerManager 内部方法 |
| Broker 设置页模式选择 UI | `broker_setup_page.dart` | 简化为单一 Docker 配置页 |

---

## 4. 通信层：MQTT + HTTP 双通道

### 4.1 Topic 结构

Moonraker 的 `instance_name` 使用设备序列号 (SN)，topic 格式如下：

```
                       ┌── 通配符订阅 (App 订阅)
                       │
订阅: +/status          ← 所有打印机状态推送 (JSON-RPC notify_status_update)
      +/notification    ← 所有打印机 Last Will ({"server":"online"/"offline"})
                       │
                       ├── 单设备通信
                       │
发布: {SN}/request      → App 向指定打印机发送 JSON-RPC 命令
订阅: {SN}/response     ← 打印机返回命令结果 (动态订阅，命令完成后取消)
      {SN}/status       ← 打印机定时状态推送 (按 status_interval 配置)
      {SN}/notification ← 打印机上线/下线/业务通知
      {SN}/klipper/state ← Klipper 进程状态 (可选)
```

**完整示例** — 打印机 SN: `8110026B060740017`：

```
发布: 8110026B060740017/request
  {"jsonrpc":"2.0", "method":"printer.gcode.script", "params":{"script":"G28\n"}, "id":42}

收到: 8110026B060740017/status
  {"jsonrpc":"2.0", "method":"notify_status_update",
   "params":[{"toolhead":{"position":[100,100,50,0]},
              "extruder":{"temperature":210.5, "target":210},
              "heater_bed":{"temperature":60.0, "target":60},
              "print_stats":{"state":"printing","filename":"benchy.gcode",
                             "total_duration":1234.5,"filament_used":5.2},
              "virtual_sdcard":{"progress":0.45,"is_active":true}}, 1718700000.0]}

收到: 8110026B060740017/notification
  {"server":"online"}   ← Last Will: 设备上线
  {"server":"offline"}  ← Last Will: 设备下线 (断电/断网)
```

### 4.2 FarmMqttRouter：消息路由器

```dart
class FarmMqttRouter {
  final FarmStore _store;
  final MqttTransport _mqtt;          // 连接到外部 Broker 的管理客户端
  final RequestTracker _tracker;      // JSON-RPC 请求-响应匹配
  final MoonrakerAdapter _adapter;    // 复用 SDK 解析器
  final Map<String, StreamSubscription> _responseSubs = {};

  /// 连接到外部 Broker + 订阅通配符
  Future<void> start({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    await _mqtt.connect(
      host: host,
      port: port,
      username: username,
      password: password,
    );

    // 通配符订阅 — 一条订阅覆盖全部 100 台打印机
    await _mqtt.subscribe('+/status', qos: 1);
    await _mqtt.subscribe('+/notification', qos: 1);

    // 消息分发
    _mqtt.messageStream.listen(_onMessage);
  }

  void _onMessage(MqttMessage msg) {
    final topic = msg.topic;
    final sn = _extractSn(topic);

    if (topic.endsWith('/status')) {
      _handleStatus(sn, msg.payload);           // → FarmStore.onMqttStatus
    } else if (topic.endsWith('/notification')) {
      _handleNotification(sn, msg.payload);      // → FarmStore.onMqttNotification
    } else if (topic.endsWith('/response')) {
      _tracker.complete(sn, msg.payload);        // → 完成等待中的 Future
    }
  }

  void _handleStatus(String sn, Uint8List payload) {
    final json = jsonDecode(utf8.decode(payload));
    Map<String, dynamic>? status;
    if (json['params'] is List && json['params'].isNotEmpty) {
      status = json['params'][0] as Map<String, dynamic>?;
    }
    if (status == null) return;

    // 提取 eventtime 作为数据时间戳，用于解决数据竞争
    final eventTime = (json['params']?.length == 2)
        ? DateTime.fromMillisecondsSinceEpoch(
            ((json['params'][1] as num) * 1000).toInt())
        : null;

    final expanded = <String, dynamic>{};
    _adapter.expandStatus(status, '', expanded);
    _store.onMqttStatus(sn, expanded, eventTime: eventTime);
  }

  void _handleNotification(String sn, Uint8List payload) {
    final json = jsonDecode(utf8.decode(payload));
    _store.onMqttNotification(sn, json);
  }

  /// 发送命令到指定打印机（MQTT 通道）
  Future<Map<String, dynamic>?> sendCommand(
    String sn, String method, [Map<String, dynamic>? params]
  ) async {
    final request = JsonRpcRequest(method: method, params: params);
    final future = _tracker.track(sn, request.id, timeout: Duration(seconds: 30));

    // 动态订阅 {sn}/response（如果尚未订阅）
    if (!_responseSubs.containsKey(sn)) {
      _responseSubs[sn] = await _mqtt.subscribe('$sn/response', qos: 1);
      // 延迟 50ms 确保订阅在 Broker 端生效后再发布
      await Future.delayed(Duration(milliseconds: 50));
    }

    await _mqtt.publish('$sn/request', utf8.encode(request.encode()), qos: 1);
    return future;
  }

  String _extractSn(String topic) => topic.split('/').first;
}
```

### 4.3 HTTP 降级通道

对于无法推送 MQTT 配置的打印机，自动降级为 HTTP 轮询。

**关键差异 vs MQTT**：HTTP 是全量快照（非增量），延迟本质高于 MQTT。降级是保底，不是等价替代。

```dart
class HttpPoller {
  final FarmStore _store;
  final RequestQueue _queue = RequestQueue(maxConcurrency: 20);
  Timer? _timer;
  Timer? _upgradeTimer;  // ← 新增：后台升级重试
  final List<_HttpTarget> _targets = [];

  void addPrinter(String sn, String ip, {int port = 7125, String? apiKey}) {
    _targets.add(_HttpTarget(sn: sn, ip: ip, port: port, apiKey: apiKey));
  }

  void removePrinter(String sn) {
    _targets.removeWhere((t) => t.sn == sn);
  }

  void start() {
    _scheduleNext(adaptiveInterval);
    _startUpgradeRetries();  // ← 后台持续尝试升级到 MQTT
  }

  void _scheduleNext(Duration delay) {
    _timer?.cancel();
    _timer = Timer(delay, () async {
      await _pollAll();
      _scheduleNext(adaptiveInterval);
    });
  }

  Future<void> _pollAll() async {
    final now = DateTime.now();
    final results = await _queue.executeAll(
      _targets.map((t) => () => _pollOne(t, now))
    );
    for (final result in results) {
      if (result.isSuccess) {
        _store.onHttpPollResult(result.sn, result.data, pollTime: now);
      } else {
        // 由 FarmConnectionMonitor 判定离线，不在这里直接标记
        _store.onHttpPollFailed(result.sn);
      }
    }
  }

  Future<_PollResult> _pollOne(_HttpTarget target, DateTime pollTime) async {
    try {
      final uri = Uri.parse('http://${target.ip}:${target.port}/printer/objects/query');
      final response = await http.get(uri,
        headers: target.apiKey != null ? {'X-Api-Key': target.apiKey!} : {},
      ).timeout(Duration(seconds: 10));
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        final status = json['result']['status'] as Map<String, dynamic>?;
        if (status != null) {
          return _PollResult(sn: target.sn, isSuccess: true,
            data: status, pollTime: pollTime);
        }
      }
      return _PollResult(sn: target.sn, isSuccess: false);
    } catch (_) {
      return _PollResult(sn: target.sn, isSuccess: false);
    }
  }

  /// 后台升级重试：周期性尝试推送 MQTT 配置
  void _startUpgradeRetries() {
    _upgradeTimer?.cancel();
    _upgradeTimer = Timer.periodic(Duration(minutes: 5), (_) async {
      for (final target in List.from(_targets)) {
        // 由 ConfigPushService 尝试重新推送 MQTT 配置
        // 成功 → source 切换为 mqtt → removePrinter(target.sn)
        // 失败 → 继续保持 HTTP 降级
      }
    });
  }

  /// 自适应间隔
  Duration get adaptiveInterval {
    final printing = _store.printingCount;
    final online = _store.onlineCount;
    final httpOnly = _store.httpCount;       // ← 只看 HTTP 降级打印机的状态
    if (printing > 0 && _store.httpPrintingCount > 0)
      return Duration(seconds: 3);
    if (online > 0 && httpOnly > 0)
      return Duration(seconds: 15);
    return Duration(seconds: 30);
  }

  void stop() {
    _timer?.cancel();
    _upgradeTimer?.cancel();
  }
}
```

---

## 5. Broker 连接管理

### 5.1 BrokerConnectionManager

```dart
class BrokerConnectionManager {
  final _stateController = BehaviorSubject<BrokerConnState>.seeded(BrokerConnState.disconnected);
  final CredentialStore _credentialStore;
  FarmMqttRouter? _router;
  Timer? _healthCheckTimer;

  /// 连接到外部 Broker
  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    _stateController.add(BrokerConnState.connecting);

    try {
      await _router?.start(
        host: host,
        port: port,
        username: username,
        password: password,
      );
      _stateController.add(BrokerConnState.connected);
      _startHealthCheck(host, port);
    } catch (e) {
      _stateController.add(BrokerConnState.error('连接失败: $e'));
      _scheduleReconnect(host, port, username, password);
    }
  }

  /// 自动重连（含指数退避）
  void _scheduleReconnect(String host, int port, String username, String password,
      [int attempt = 0]) {
    final delay = Duration(seconds: min(pow(2, attempt).toInt(), 30));
    Future.delayed(delay, () async {
      if (_stateController.value == BrokkerConnState.disconnected) return;
      await connect(host: host, port: port, username: username, password: password);
    });
  }

  /// 主动健康检测：周期性 ping（发送 MQTT PINGREQ）
  void _startHealthCheck(String host, int port) {
    _healthCheckTimer?.cancel();
    _healthCheckTimer = Timer.periodic(Duration(seconds: 15), (_) async {
      try {
        await _router?.ping();          // MQTT PINGREQ → 期待 PINGRESP
      } catch (_) {
        _stateController.add(BrokerConnState.degraded);
        // 触发重连
        final creds = _credentialStore.load();
        _scheduleReconnect(host, port, creds.username, creds.password);
      }
    });
  }

  /// 断开连接
  Future<void> disconnect() async {
    _healthCheckTimer?.cancel();
    await _router?.stop();
    _stateController.add(BrokerConnState.disconnected);
  }

  Stream<BrokerConnState> get stateStream => _stateController.stream;
  BrokerConnState get state => _stateController.value;
}

enum BrokerConnState { disconnected, connecting, connected, degraded, error }
```

### 5.2 FarmHub：群控入口

`FarmHub` 是一站式入口，管理完整群控生命周期。**不再管理 Broker 进程，只管理到 Broker 的连接。**

```dart
class FarmHub {
  final FarmStore store;
  final BrokerConnectionManager brokerConnMgr;
  final FarmMqttRouter mqttRouter;
  final PrinterDiscovery discovery;
  final ConfigPushService configPusher;
  final BatchOperator batchOperator;
  final FileUploader fileUploader;
  final HttpPoller httpPoller;
  final FarmConnectionMonitor connectionMonitor;
  final BrokerHealthMonitor brokerHealthMonitor;

  /// 启动群控系统
  Future<void> start({
    required BrokerConfig brokerConfig,
  }) async {
    // 1. 连接到 Broker（Docker 容器）
    await brokerConnMgr.connect(
      host: brokerConfig.host,
      port: brokerConfig.port,
      username: brokerConfig.username,
      password: brokerConfig.password,
    );

    // 2. 加载已注册打印机 (Hive)
    final saved = await PrinterRegistry.loadAll();
    store.loadFromRegistry(saved);

    // 3. 启动监控
    brokerHealthMonitor.start();
    connectionMonitor.start();

    // 4. 等待各打印机 MQTT 连接（通过 +/notification 感知）
    // 此步骤非阻塞，打印机状态异步更新
  }

  /// 发现局域网打印机
  Future<List<DiscoveredPrinter>> discover() async {
    final mdns = await discovery.discoverMdns();
    final tcp = await discovery.discoverTcp(subnet: _detectSubnet());
    return PrinterDiscovery.merge(mdns, tcp);
  }

  /// 单台打印机入网
  Future<OnboardingResult> onboard({
    required String ip,
    required int port,
    required String accessCode,
  }) async {
    // 1. 验证 Access Code
    final token = await _verifyAccessCode(ip, port, accessCode);
    if (token == null) return OnboardingResult.authFailed;

    // 2. 获取设备信息
    final info = await _fetchServerInfo(ip, port, token);
    final sn = info['instance_name'];

    // 3. 推送 MQTT 配置（含 Broker 凭据）
    final (success, source) = await configPusher.push(
      ip: ip, port: port, sn: sn,
      brokerHost: brokerConnMgr.host,
      brokerPort: brokerConnMgr.port,
      mqttUsername: 'printer_$sn',
      mqttPassword: _generatePrinterPassword(sn),
    );

    if (!success) {
      // 降级到 HTTP
      httpPoller.addPrinter(sn, ip, port: port, apiKey: token);
    }

    // 4. 注册到系统
    store.onPrinterRegistered(PrinterInfo(
      sn: sn, ip: ip, port: port,
      source: source,
    ));

    // 5. 持久化
    await PrinterRegistry.save(store.exportToRegistry());

    return OnboardingResult.success(sn: sn, source: source);
  }

  Future<void> shutdown() async {
    connectionMonitor.stop();
    brokerHealthMonitor.stop();
    httpPoller.stop();
    await brokerConnMgr.disconnect();
    await PrinterRegistry.save(store.exportToRegistry());
  }
}
```

---

## 6. 打印机入网流程

### 6.1 完整时序

```
用户点击"添加打印机"
         │
         ▼
┌─ Step 1: 发现 ──────────────────────────────────────────────────
│  mDNS 扫描 _moonraker._tcp.local  (5s 超时)
│  TCP 扫描 192.168.x.0/24:7125    (254个IP, 50并发, 500ms超时)
│  → 合并去重 → 展示发现列表
│
│  用户从列表选择打印机（或手动输入 IP）
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 2: 验证 ──────────────────────────────────────────────────
│  POST http://{ip}:7125/access/login
│  Body: {"access_code": "12345678"}
│  ← 200: {"result": {"token": "..."}}
│  ← 401: Access Code 错误 → 提示用户重新输入
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 3: 获取设备信息 ──────────────────────────────────────────
│  GET http://{ip}:7125/server/info
│  ← {"result": {"klippy_connected": true, "components": [...],
│                 "instance_name": "8110026B060740017", ...}}
│  → 记录 SN, 型号, 固件版本
│
│  ⚠️ 检查打印机当前状态:
│    if (print_stats.state == "printing") {
│      提示用户: "打印机正在打印中，重配 MQTT 需要重启 Moonraker，将中断当前打印"
│      用户确认后继续 / 取消
│    }
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 4: 推送 MQTT 配置 ────────────────────────────────────────
│  POST http://{ip}:7125/server/config
│  Body: {
│    "config": {
│      "mqtt": {
│        "address": "192.168.1.100",        ← Broker 固定 IP
│        "port": 1883,
│        "username": "printer_8110026B...",  ← 自动生成的凭据
│        "password": "<random>",
│        "instance_name": "8110026B060740017",
│        "status_interval": 1.0,
│        "enable_moonraker_api": true
│      }
│    }
│  }
│  ← 200: config 写入成功
│  ← 4xx/5xx: 写入失败 → 标记 HTTP 降级 → 跳转到 Step 7
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 5: 重启 Moonraker 生效配置 ────────────────────────────────
│  POST http://{ip}:7125/server/restart
│  ← 200: Moonraker 正在重启
│
│  等待重启完成 (轮询 GET /server/info, 最多等 20s):
│    T+0s:  连接拒绝 (Moonraker 重启中)
│    T+5s:  连接成功 → klippy_connected: false (Klipper 启动中)
│    T+10s: 连接成功 → klippy_connected: true → 重启完成
│
│  (超时从 15s 增加到 20s，给慢速打印机余量)
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 6: 等待 MQTT 连接 ────────────────────────────────────────
│  App 订阅 +/notification, 等待 SN 的 online 消息
│
│  T+0s:   开始等待 (超时 20s)
│  T+3s:   收到 8110026B060740017/notification = {"server":"online"}
│  → MQTT 入网成功！
│
│  T+20s:  超时未收到 online → 标记 HTTP 降级
└─────────────────────────────────────────────────────────────────
         │
         ▼
┌─ Step 7: 注册到系统 ────────────────────────────────────────────
│  FarmStore.onPrinterRegistered(PrinterInfo(
│    sn: "8110026B060740017",
│    ip: "192.168.1.101",
│    port: 7125,
│    source: Source.mqtt,           ← MQTT 模式（或 Source.http）
│    displayName: "Printer-1",
│    model: "Snapmaker J1",
│    ...))
│
│  持久化到 Hive (下次启动自动加载)
└─────────────────────────────────────────────────────────────────
```

### 6.2 ConfigPushService

```dart
class ConfigPushService {
  static const _maxRetries = 3;
  static const _restartTimeout = Duration(seconds: 20);
  final FarmStore? _store;  // 用于等待 MQTT 上线

  /// 推送 MQTT 配置到打印机
  Future<(bool, Source)> push({
    required String ip,
    required int port,
    required String sn,
    required String brokerHost,
    required int brokerPort,
    required String mqttUsername,
    required String mqttPassword,
    double statusInterval = 1.0,
  }) async {
    final config = {
      'config': {
        'mqtt': {
          'address': brokerHost,
          'port': brokerPort,
          'username': mqttUsername,
          'password': mqttPassword,
          'instance_name': sn,
          'status_interval': statusInterval,
          'enable_moonraker_api': true,
        }
      }
    };

    // 先尝试带凭据的配置
    for (int attempt = 0; attempt < _maxRetries; attempt++) {
      try {
        final resp = await http.post(
          Uri.parse('http://$ip:$port/server/config'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(config),
        ).timeout(Duration(seconds: 10));

        if (resp.statusCode != 200) {
          if (attempt == _maxRetries - 1) return (false, Source.http);
          await Future.delayed(Duration(seconds: 3));
          continue;
        }

        // 重启
        await http.post(
          Uri.parse('http://$ip:$port/server/restart'),
        ).timeout(Duration(seconds: 5));

        // 等待 MQTT 上线
        final online = await _waitForMqttOnline(sn);
        if (online) return (true, Source.mqtt);

      } catch (_) {
        if (attempt < _maxRetries - 1) {
          await Future.delayed(Duration(seconds: 5));
        }
      }
    }

    // 全部重试失败 → 降级为 HTTP
    return (false, Source.http);
  }

  Future<bool> _waitForMqttOnline(String sn) async {
    final start = DateTime.now();
    while (DateTime.now().difference(start) < _restartTimeout) {
      final printer = _store?.getPrinter(sn);
      if (printer?.connectionState == FarmConnectionState.online) {
        return true;
      }
      await Future.delayed(Duration(milliseconds: 500));
    }
    return false;
  }
}
```

---

## 7. FarmStore：多设备状态聚合

### 7.1 数据结构

```dart
class FarmPrinterState {
  // ── 身份 (永不清) ──
  final String sn;
  String? displayName;
  String ip;
  int port;
  String? group;
  String? model;
  String? firmwareVersion;

  // ── 通信模式 ──
  Source source;              // mqtt | http
  FarmConnectionState connectionState;

  // ── 实时遥测 (Staleable — 断连时标记过期) ──
  Staleable<double>? nozzleTemp;
  Staleable<double>? bedTemp;
  Staleable<String>? printState;
  Staleable<double>? progress;
  Staleable<String>? currentFile;
  Staleable<int>? layerNum;
  Staleable<int>? totalLayers;
  Staleable<double>? estimatedTime;

  // ── 累积指标 ──
  double? totalDuration;
  double? filamentUsed;
  double? _lastReportedDuration;    // ← 修复累积逻辑：记录上次报告值

  // ── 数据版本 (用于解决 MQTT/HTTP 竞争) ──
  DateTime? lastDataTimestamp;      // ← 来自 MQTT eventtime 或 HTTP pollTime
  DateTime lastStatusTime;

  // ── 批量操作 ──
  BatchResult? lastBatchResult;

  // ── 快照 ──
  static const _maxSnapshots = 50;  // ← 从 20 增加到 50，用于复杂问题排查
  final List<FarmSnapshot> _snapshots = [];

  // ── 派生属性 ──
  bool get isOnline => connectionState == FarmConnectionState.online;
  bool get isPrinting => printState?.value == 'printing';
  bool get isMqtt => source == Source.mqtt;
  bool get isHttp => source == Source.http;

  /// 更新遥测数据，带时间戳保护
  void updateTelemetry(Map<String, dynamic> data, {DateTime? eventTime}) {
    // 时间戳保护：忽略比已有数据更旧的更新
    if (eventTime != null && lastDataTimestamp != null) {
      if (eventTime.isBefore(lastDataTimestamp!)) return;
    }

    if (data.containsKey('extruder.temperature')) {
      nozzleTemp = Staleable(data['extruder.temperature'], isStale: false);
    }
    if (data.containsKey('heater_bed.temperature')) {
      bedTemp = Staleable(data['heater_bed.temperature'], isStale: false);
    }
    if (data.containsKey('print_stats.state')) {
      printState = Staleable(data['print_stats.state'], isStale: false);
    }
    if (data.containsKey('virtual_sdcard.progress')) {
      progress = Staleable(data['virtual_sdcard.progress'], isStale: false);
    }
    if (data.containsKey('print_stats.filename')) {
      currentFile = Staleable(data['print_stats.filename'], isStale: false);
    }
    // 累积指标：使用增量而非全量累加
    if (data.containsKey('print_stats.total_duration')) {
      final current = (data['print_stats.total_duration'] as num).toDouble();
      if (_lastReportedDuration != null && current > _lastReportedDuration!) {
        totalDuration = (totalDuration ?? 0) + (current - _lastReportedDuration!);
      } else if (_lastReportedDuration == null) {
        totalDuration = current;
      }
      _lastReportedDuration = current;
    }
    if (eventTime != null) {
      lastDataTimestamp = eventTime;
    }
    lastStatusTime = DateTime.now();
  }
}
```

### 7.2 FarmStore 核心

```dart
class FarmStore {
  final Map<String, FarmPrinterState> _printers = {};

  // ═══ 写入方法 ═══

  /// MQTT 状态推送（主力通道）
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 时间戳保护：忽略晚于已有数据的更新
    if (eventTime != null && printer.lastDataTimestamp != null) {
      if (!eventTime.isAfter(printer.lastDataTimestamp!)) return;
    }

    printer.updateTelemetry(status, eventTime: eventTime);
    printer.markFresh(Source.mqtt);
    _notify();
  }

  /// HTTP 轮询结果（降级通道）
  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 时间戳保护：HTTP 轮询数据可能晚于 MQTT 数据
    if (printer.lastDataTimestamp != null && !pollTime.isAfter(printer.lastDataTimestamp!)) {
      return;  // ← 丢弃过时数据
    }

    printer.updateTelemetry(data, eventTime: pollTime);
    printer.markFresh(Source.http);
    _notify();
  }

  /// MQTT 通知（Last Will 等）
  void onMqttNotification(String sn, Map<String, dynamic> data) {
    final printer = _printers[sn];
    if (printer == null) return;

    if (data['server'] == 'online') {
      printer.connectionState = FarmConnectionState.online;
      printer.markTelemetryStale();  // 等下一次状态推送刷新
    } else if (data['server'] == 'offline') {
      printer.connectionState = FarmConnectionState.offline;
      printer.markTelemetryStale();
    }
    _notify();
  }

  /// 强制离线（由连接监控触发，例如 60s 无状态更新）
  void forceOffline(String sn, String reason) {
    final printer = _printers[sn];
    if (printer == null) return;
    printer.connectionState = FarmConnectionState.offline;
    printer.markTelemetryStale();
    captureSnapshot(sn, reason);
    _notify();
  }

  /// HTTP 轮询单次失败（不直接标记离线，由连接监控累积判定）
  void onHttpPollFailed(String sn) {
    // 仅记录，不改变状态。由 FarmConnectionMonitor 做累积判定
  }

  // ═══ 读取出口 ═══

  FarmPrinterState? getPrinter(String sn) => _printers[sn];
  List<FarmPrinterState> get allPrinters => List.unmodifiable(_printers.values);

  int get count => _printers.length;
  int get onlineCount => _printers.values.where((p) => p.isOnline).length;
  int get printingCount => _printers.values.where((p) => p.isPrinting).length;
  int get mqttCount => _printers.values.where((p) => p.isMqtt).length;
  int get httpCount => _printers.values.where((p) => p.isHttp).length;
  int get httpPrintingCount =>
    _printers.values.where((p) => p.isHttp && p.isPrinting).length;

  // ... (其余方法与当前设计一致: onPrinterRegistered, onPrinterRemoved,
  //      onBatchResult, captureSnapshot, loadFromRegistry, exportToRegistry 等)
}
```

### 7.3 写入通知优化

当前设计每个 `on*` 方法都调用 `notifyListeners()`，100 台打印机每秒产生 100 次 UI 重建信号。优化方案：

```dart
class FarmStore {
  Timer? _batchTimer;
  final Set<String> _dirtySns = {};
  static const _batchWindow = Duration(milliseconds: 100);  // 100ms 批处理窗口

  void _notify() {
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(_batchWindow, () {
        _notifier.notifyListeners();  // 批量通知
        _dirtySns.clear();
        _batchTimer = null;
      });
    }
  }
}

// 在 StateNotifier 中配合 select() 精确重建:
// ref.watch(farmStoreProvider.select((s) => s['SN001']?.nozzleTemp));
```

---

## 8. 批量操作引擎

### 8.1 BatchOperator（含优先级）

```dart
class BatchOperator {
  final FarmStore _store;
  final FarmMqttRouter _mqttRouter;
  final HttpPoller? _httpPoller;
  static const int maxConcurrency = 20;
  static const int highPriorityConcurrency = 40;   // ← 急停等场景更高并发

  /// 批量急停 — 高优先级，更高并发，更短超时
  Future<List<BatchResult>> batchEmergencyStop() {
    final allSns = _store.allPrinters.map((p) => p.sn).toList();
    return _fanOut(
      printerSns: allSns,
      operation: 'emergency_stop',
      timeout: Duration(seconds: 5),
      maxConcurrency: highPriorityConcurrency,     // ← 40 并发，加速覆盖
      action: (sn) => _sendCommand(sn, 'printer.gcode.script',
                                   {'script': 'M112\n'}),
    );
  }

  // ... batchPause, batchResume, batchCancel, batchGcode, batchSetNozzleTemp
  // 使用默认 maxConcurrency: 20

  Future<List<BatchResult>> _fanOut({
    required List<String> printerSns,
    required String operation,
    required Future<void> Function(String sn) action,
    Duration timeout = const Duration(seconds: 30),
    int maxConcurrency = maxConcurrency,
  }) async {
    final results = <BatchResult>[];
    final semaphore = Semaphore(maxConcurrency);

    final futures = printerSns.map((sn) async {
      await semaphore.acquire();
      final startTime = DateTime.now();
      try {
        await action(sn).timeout(timeout);
        final result = BatchResult(
          printerSn: sn, success: true, operation: operation,
          duration: DateTime.now().difference(startTime),
        );
        _store.onBatchResult(sn, result);
        results.add(result);
      } catch (e, st) {
        final result = BatchResult(
          printerSn: sn, success: false, operation: operation,
          error: e.toString(),
          duration: DateTime.now().difference(startTime),
        );
        _store.onBatchResult(sn, result);
        results.add(result);
      } finally {
        semaphore.release();
      }
    });

    await Future.wait(futures);
    return results;
  }

  /// 命令路由: MQTT 或 HTTP
  Future<void> _sendCommand(String sn, String method,
      [Map<String, dynamic>? params]) async {
    final printer = _store.getPrinter(sn);
    if (printer == null) throw Exception('打印机 $sn 未注册');

    if (printer.source == Source.mqtt) {
      final result = await _mqttRouter.sendCommand(sn, method, params);
      if (result == null) throw TimeoutException('MQTT 命令超时: $method');
    } else {
      // HTTP 命令发送后，立即触发一次针对性状态查询以快速确认
      final result = await _sendHttpCommand(printer.ip, printer.port,
                                            method, params);
      // 异步触发一次立刻轮询确认状态
      _httpPoller?.probeSingle(sn);
      return result;
    }
  }
}
```

### 8.2 `probeSingle`：HTTP 降级模式的即时状态确认

```dart
// HttpPoller 新增方法
Future<void> probeSingle(String sn) async {
  final target = _targets.firstWhere((t) => t.sn == sn);
  final result = await _pollOne(target, DateTime.now());
  if (result.isSuccess) {
    _store.onHttpPollResult(result.sn, result.data, pollTime: result.pollTime);
  }
}
```

---

## 9. 文件分发

与当前设计基本一致，差异点：

```dart
class FileUploader {
  static const int maxConcurrent = 5;  // 文件传输保守并发

  Future<List<UploadResult>> batchUpload({
    required List<String> printerSns,
    required String localFilePath,
    required String remoteFileName,
    FarmStore? store,
    void Function(int completed, int total)? onProgress,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) throw Exception('文件不存在: $localFilePath');

    // ← 使用流式读取，避免大文件全量加载到内存
    final fileSize = await file.length();
    if (fileSize > 200 * 1024 * 1024) {  // 200MB 上限
      throw Exception('文件过大: ${fileSize} bytes, 超过 200MB 限制');
    }
    final fileBytes = await file.readAsBytes();  // 对于 < 200MB 的 GCode 文件，内存加载可接受

    // ... 其余逻辑与当前设计一致
  }

  Future<UploadResult> _uploadToPrinter({...}) async {
    // ... 上传逻辑
    // 新增：上传后校验（可选，通过 Moonraker /server/files/metadata 检查文件大小）
  }
}
```

---

## 10. 安全设计

### 10.1 安全模型

```
安全层级:
  ┌─────────────────────────────────────────────────────────────┐
  │ 第 1 层: Broker 认证 (MQTT CONNECT)                         │
  │   每个客户端（App、每台打印机）有独立用户名/密码              │
  │   匿名连接被拒绝 (allow_anonymous false)                    │
  ├─────────────────────────────────────────────────────────────┤
  │ 第 2 层: Topic ACL                                           │
  │   打印机 A 不能发布或订阅打印机 B 的 topic                    │
  │   App 管理客户端有全局读写权限                               │
  ├─────────────────────────────────────────────────────────────┤
  │ 第 3 层: 打印机 Access Code 验证                             │
  │   入网时需输入打印机预设的 Access Code                       │
  │   验证通过后才能推送 MQTT 配置                               │
  ├─────────────────────────────────────────────────────────────┤
  │ 第 4 层: 传输安全 (可选)                                     │
  │   生产环境建议 MQTT TLS + HTTPS                             │
  │   Docker 容器部署，默认开启认证                                         │
  └─────────────────────────────────────────────────────────────┘
```

### 10.2 凭据管理

```dart
class CredentialStore {
  /// 为打印机生成随机密码
  static String generatePrinterPassword(String sn) {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// 安全存储 App 端 Broker 凭据
  Future<void> saveBrokerCredentials({
    required String host,
    required int port,
    required String username,
    required String password,
  }) async {
    // 使用 flutter_secure_storage 或 keychain
    await _secureStorage.write(key: 'broker_host', value: host);
    await _secureStorage.write(key: 'broker_port', value: port.toString());
    await _secureStorage.write(key: 'broker_username', value: username);
    await _secureStorage.write(key: 'broker_password', value: password);
  }
}
```

---

## 11. 连接监控与故障恢复

### 11.1 故障检测矩阵

```
故障类型              检测方式                  检测延迟    恢复方式
────────────────────────────────────────────────────────────────
打印机断电           Last Will offline         1-3s       用户手动重连
打印机 MQTT 断连     Last Will offline         1-3s       Moonraker 自动重连
打印机假在线         60s 无状态更新              60s        标记离线 + 通知用户
Broker 崩溃          BrokerHealthMonitor       < 15s       App 等待 Broker 恢复后重连
Broker 假活          MQTT PINGREQ 无响应        15s        App 触发重连
App 断连 Broker      MQTT 连接断开              < 5s       自动重连（指数退避）
App 网络断开         连接断开 + HTTP 全超时      < 5s        通知用户
ConfigPush 失败      HTTP 4xx/5xx              即时        降级 HTTP + 后台 5min 重试
HTTP 轮询失败        连续 3 次超时              30-45s      标记离线
```

### 11.2 Broker 健康监控

```dart
class BrokerHealthMonitor {
  final FarmMqttRouter _router;
  final FarmStore _store;
  int _consecutiveFailures = 0;
  static const int maxFailures = 3;

  void start() {
    // 周期性 PING 检测：如 MQTT PINGRESP 超时，标记 Broker 不健康
    // 连续 3 次失败 → 通知 UI "Broker 连接异常" → 触发重连
  }

  void _onPingFailed() {
    _consecutiveFailures++;
    if (_consecutiveFailures >= maxFailures) {
      // Broker 假活 — 连接存在但无响应
      // → 通知 BrokerConnectionManager 触发重连
    }
  }
}
```

### 11.3 恢复流程

```
Broker 崩溃恢复:
  Mosquitto 崩溃 (OOM/系统重启/其他)
    │
    ├── persistence true → 重启后恢复 session
    │   ├── 打印机自动重连 (Moonraker _do_reconnect)
    │   └── App 自动重连 (BrokerConnectionManager 指数退避)
    │
    └── 所有打印机恢复后 → 状态推送恢复 → UI 更新

App 崩溃恢复:
  App 崩溃 / 用户强制退出
    │
    ├── Broker 不受影响 ← 关键！
    ├── 打印机继续正常通信
    ├── 用户重启 App → BonjourConnectionManager.connect()
    ├── 订阅 +/status, +/notification
    ├── 从 Hive 加载已注册打印机 → FarmStore.loadFromRegistry()
    └── 状态立即恢复（打印机一直在推送）
```

---

## 12. UI 架构与数据流

### 12.1 Riverpod Provider 依赖图

```dart
// ═══ 核心 Store ═══
final farmStoreProvider = StateNotifierProvider<FarmStoreNotifier, Map<String, FarmPrinterState>>((ref) {
  return FarmStoreNotifier(FarmStore());
});

// ═══ Broker 连接状态 ═══
final brokerConnMgrProvider = Provider<BrokerConnectionManager>((ref) {
  return BrokerConnectionManager();
});

final brokerStateProvider = StreamProvider<BrokerConnState>((ref) {
  return ref.read(brokerConnMgrProvider).stateStream;
});

// ═══ 派生: 打印机列表 ═══
final printerListProvider = Provider<List<FarmPrinterState>>((ref) {
  final state = ref.watch(farmStoreProvider);
  return state.values.toList()..sort((a, b) => a.sn.compareTo(b.sn));
});

// ═══ 派生: 按状态筛选 ═══
final printingPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isPrinting).toList();
});

final offlinePrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => !p.isOnline).toList();
});

final httpFallbackPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isHttp).toList();
});

// ═══ 派生: 统计 ═══
final farmStatsProvider = Provider<FarmStats>((ref) {
  final state = ref.watch(farmStoreProvider);
  final printers = state.values;
  return FarmStats(
    total: printers.length,
    online: printers.where((p) => p.isOnline).length,
    printing: printers.where((p) => p.isPrinting).length,
    mqttCount: printers.where((p) => p.isMqtt).length,
    httpCount: printers.where((p) => p.isHttp).length,
  );
});

class FarmStats {
  final int total, online, printing, mqttCount, httpCount;
  double get onlineRate => total > 0 ? online / total : 0;
}
```

### 12.2 UI 组件树

```
FarmApp
└── MaterialApp
    └── DashboardPage
        ├── AppBar
        │   ├── BrokerStatusIndicator  ← ref.watch(brokerStateProvider)
        │   │   显示: 🟢已连接 / 🟡连接中 / 🔴断开 / ⚠️降级

        │   └── [添加打印机] 按钮 → DiscoveryWizardPage
        │
        ├── AlertBanner (条件显示)
        │   HTTP降级打印机: "3 台打印机使用 HTTP 降级模式"
        │
        ├── StatsBar  ← ref.watch(farmStatsProvider)
        │   ┌──────┬──────┬──────┬──────┬──────┐
        │   │ 总数 │ 在线 │ 打印 │ MQTT │ HTTP │
        │   │  45  │  42  │  8   │  38  │  4   │
        │   └──────┴──────┴──────┴──────┴──────┘
        │
        ├── FilterChips
        │   [全部] [打印中:8] [空闲] [暂停] [离线:3] [MQTT:38] [HTTP:4]
        │
        ├── BatchToolbar (选中打印机时显示)
        │   [暂停] [取消] [归零] [设置温度] [发送GCode] [上传打印]
        │
        └── PrinterGrid  ← ref.watch(printerListProvider)
            ┌──────────┬──────────┬──────────┬──────────┐
            │PrinterCard│PrinterCard│PrinterCard│PrinterCard│
            │🟢 MQTT   │🔵 打印中  │🟡 暂停   │🟠 HTTP   │
            │210°C/60°C│215°C/62°C│205°C/58°C│210°C/60°C│
            │待机      │benchy 45%│cube 72%  │离线      │
            └──────────┴──────────┴──────────┴──────────┘
                          (自适应列数, 支持勾选, 虚拟化滚动)
```

---

## 13. 完整数据流时序

### 13.1 生产模式启动（App 连接到外部 Broker）

```
Broker (固定IP:1883)        Lava Farm App               Hive / 打印机
      │                          │                          │
      │                          │ 1. 加载凭据 & 打印机列表   │
      │                          │──── Hive.load() ────────→│
      │                          │←── 已注册打印机列表 ──────│
      │                          │                          │
      │←── MQTT CONNECT ────────│                          │
      │     (username/password) │                          │
      │──→ CONNACK ────────────→│                          │
      │                          │                          │
      │←── subscribe +/status ──│                          │
      │←── subscribe +/notif ───│                          │
      │                          │                          │
      │                          │── FarmStore.loadFromRegistry()
      │                          │                          │
      │    (打印机陆续连接 Broker) │                          │
      │←── CONNECT printer_001 ──│                          │
      │←── publish 001/notif ───→│──→ 收到 +/notification ──→│
      │     {"server":"online"}  │    SN=001 online         │→ FarmStore.onMqttNotification
      │                          │                          │→ UI: Printer-1 上线
      │                          │                          │
      │←── publish 001/status ──→│──→ 收到 +/status ───────→│→ FarmStore.onMqttStatus
      │     (1s 间隔持续)        │                          │→ UI: 实时更新温度/进度
```

### 13.2 App 关闭后重开（生产模式的核心优势）

```
      (操作员关闭 App)
      │
      │  Broker 继续运行 ← 关键！
      │  打印机 1..100 保持 MQTT 连接
      │  状态推送持续（Broker 内部队列缓存, autosave 持久化）
      │
      │  (操作员重新打开 App)
      │
      │  App → MQTT CONNECT → Broker
      │  App → subscribe +/status, +/notification
      │
      │  打印机状态即刻恢复:
      │  打印机 001 仍在推送 → App 立即收到最新状态
      │  UI 在 1-2 秒内恢复到关闭前的样子
      │
      │  (如果打印机在 App 关闭期间离线):
      │  打印机 002/notification {"server":"offline"} 可能已过
      │  → 但 App 重新订阅后，60s 心跳超时会检测到离线
      │  → 或连接时查看最后状态时间戳判定
```

### 13.3 批量命令时序

```
用户点击"暂停全部打印中的打印机" (8台)
      │
      ▼
BatchOperator.batchPause(["811...001", ..., "811...008"])
      │
      ├─ Semaphore(maxConcurrency: 20, 足够覆盖 8 台)
      │
      ├─ 并发发送 8 条 MQTT 命令到 Broker:
      │    publish 811...001/request → Broker → 打印机 001
      │    publish 811...002/request → Broker → 打印机 002
      │    ... (全部并发，Semaphore 不阻塞)
      │
      ├─ 等待 {sn}/response:
      │    打印机 002: response (189ms) → 成功
      │    打印机 001: response (234ms) → 成功
      │    ...
      │    打印机 008: 超时 30s → 失败
      │
      └─ 结果聚合 → FarmStore.onBatchResult() → UI 实时更新
```

### 13.4 HTTP 降级 + 后台恢复时序

```
打印机 SN: 811...099 (ConfigPush 失败, 标记为 Source.http)

HttpPoller (3s 间隔 — 该打印机正在打印):
  │
  │  T+0s    HTTP GET :7125/printer/objects/query → 200 OK
  │          FarmStore.onHttpPollResult() → UI 更新
  │
  │  T+3s    HTTP GET → 200 OK → UI 更新
  │
  │  ...     打印任务持续 ...
  │
  │  同时: 后台升级重试 (5分钟间隔):
  │  T+300s  ConfigPushService.push() → 重试推送 MQTT 配置
  │          ├─ 成功 (网络恢复) → POST /server/config → 200
  │          │   → POST /server/restart
  │          │   → 等待 +/notification online
  │          │   → source 切换为 Source.mqtt
  │          │   → HttpPoller.removePrinter(sn)
  │          │   ✅ 已恢复到 MQTT!
  │          │
  │          └─ 失败 → 继续 HTTP 降级，5 分钟后重试
```

---

## 14. 目录结构

```
lava-farm/
├── ARCHITECTURE.md
├── README.md
├── pubspec.yaml
│
├── openspec/
│   ├── config.yaml
│   └── changes/lava-farm/
│       ├── proposal.md
│       ├── design.md
│       └── tasks.md
│
├── deployment/                           # ← Docker Compose 参考模板（App 内置到 ~/.lava-farm/broker/）
│   └── docker-compose.yml
│
├── lib/
│   ├── main.dart
│   │
│   └── features/
│       └── farm/
│           ├── application/
│           │   └── providers/
│           │       ├── farm_store_provider.dart
│           │       ├── broker_state_provider.dart       # ← 改名：不再是 broker 进程状态
│           │       ├── discovery_provider.dart
│           │       ├── printer_list_provider.dart
│           │       ├── farm_stats_provider.dart
│           │       └── batch_operation_provider.dart
│           │
│           ├── presentation/
│           │   ├── pages/
│           │   │   ├── farm_dashboard_page.dart
│           │   │   ├── printer_detail_page.dart
│           │   │   ├── discovery_wizard_page.dart
│           │   │   ├── broker_setup_page.dart           # ← 新增：Broker 连接配置
│           │   │   └── settings_page.dart
│           │   └── widgets/
│           │       ├── printer_card.dart
│           │       ├── printer_grid.dart
│           │       ├── stats_bar.dart
│           │       ├── batch_toolbar.dart
│           │       ├── broker_status_indicator.dart
│           │       ├── connection_badge.dart
│           │       ├── deployment_mode_banner.dart       # ← 新增：模式提示横幅
│           │       └── discovery_result_list.dart
│           │
│           └── data/
│               ├── farm_store.dart
│               ├── farm_printer_state.dart
│               ├── staleable.dart
│               ├── farm_snapshot.dart
│               ├── docker_broker_manager.dart             # ← 新：Docker 管理 Mosquitto 生命周期
│               ├── broker_connection_manager.dart        # ← 新：连接外部 Broker
│               ├── broker_health_monitor.dart            # ← 新：Broker 健康监控
│               ├── credential_store.dart                 # ← 新：凭据安全存储
│               ├── farm_mqtt_router.dart
│               ├── config_push_service.dart
│               ├── batch_operator.dart
│               ├── batch_result.dart
│               ├── printer_discovery.dart
│               ├── http_poller.dart
│               ├── file_uploader.dart
│               ├── farm_connection_monitor.dart
│               ├── request_tracker.dart
│               ├── request_queue.dart
│               ├── printer_info.dart
│               ├── printer_registry.dart                 # ← 新：Hive 持久化封装
│               └── farm_hub.dart
│
├── test/
│   └── features/farm/data/
│       ├── farm_store_test.dart
│       ├── farm_mqtt_router_test.dart
│       ├── batch_operator_test.dart
│       ├── printer_discovery_test.dart
│       ├── http_poller_test.dart
│       ├── config_push_service_test.dart
│       ├── broker_connection_manager_test.dart           # ← 新增
│       └── credential_store_test.dart                    # ← 新增
│
└── assets/
    └── deployment/
        └── mosquitto/                    # Docker Compose 参考模板
            ├── mosquitto.conf.production
            └── acl.example
```

---

## 15. 关键类接口定义

```dart
// ═══════════════════════════════════════════════════════════
// FarmHub — 群控系统入口
// ═══════════════════════════════════════════════════════════

class FarmHub {
  final FarmStore store;
  final BrokerConnectionManager brokerConnMgr;
  final FarmMqttRouter mqttRouter;
  final PrinterDiscovery discovery;
  final ConfigPushService configPusher;
  final BatchOperator batchOperator;
  final FileUploader fileUploader;
  final HttpPoller httpPoller;
  final FarmConnectionMonitor connectionMonitor;
  final BrokerHealthMonitor brokerHealthMonitor;

  Future<void> start({required BrokerConfig brokerConfig});
  Future<List<DiscoveredPrinter>> discover();
  Future<OnboardingResult> onboard({required String ip, required int port, required String accessCode});
  void removePrinter(String sn);
  Future<List<BatchResult>> batchPause(List<String> sns);
  Future<List<BatchResult>> batchCancel(List<String> sns);
  Future<List<BatchResult>> batchGcode({required List<String> sns, required String gcode});
  Future<List<BatchResult>> batchEmergencyStop();
  Future<List<UploadResult>> batchUploadAndPrint({required List<String> sns, required String filePath, required String fileName});
  Future<void> shutdown();
}

class BrokerConfig {
  final String host;
  final int port;
  final String username;
  final String password;
  final String host;  final int port;  final String username;  final String password;
}


// ═══════════════════════════════════════════════════════════
// BrokerConnectionManager
// ═══════════════════════════════════════════════════════════

class BrokerConnectionManager {
  Stream<BrokerConnState> get stateStream;
  BrokerConnState get state;
  bool get isConnected;
  Future<void> connect({required String host, required int port, required String username, required String password});
  Future<void> disconnect();
}

enum BrokerConnState { disconnected, connecting, connected, degraded, error }

// ═══════════════════════════════════════════════════════════
// FarmMqttRouter
// ═══════════════════════════════════════════════════════════

class FarmMqttRouter {
  Future<void> start({required String host, required int port, required String username, required String password});
  Future<Map<String, dynamic>?> sendCommand(String sn, String method, [Map<String, dynamic>? params]);
  Future<void> ping();  // ← 新增：用于健康检测
  Future<void> stop();
}

// ═══════════════════════════════════════════════════════════
// FarmStore
// ═══════════════════════════════════════════════════════════

class FarmStore {
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime});
  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime});
  void onMqttNotification(String sn, Map<String, dynamic> data);
  void onHttpPollFailed(String sn);
  void forceOffline(String sn, String reason);
  void onPrinterRegistered(PrinterInfo info);
  void onPrinterRemoved(String sn);
  void onBatchResult(String sn, BatchResult result);
  void captureSnapshot(String sn, String reason, {String? context, Object? error});
  void loadFromRegistry(List<PrinterInfo> printers);
  List<PrinterInfo> exportToRegistry();

  FarmPrinterState? getPrinter(String sn);
  List<FarmPrinterState> get allPrinters;
  List<FarmPrinterState> getByGroup(String group);
  List<FarmPrinterState> get mqttPrinters;
  List<FarmPrinterState> get httpFallbackPrinters;
  int get count;
  int get onlineCount;
  int get printingCount;
  int get mqttCount;
  int get httpCount;
  int get httpPrintingCount;
}

// ═══════════════════════════════════════════════════════════
// BatchOperator
// ═══════════════════════════════════════════════════════════

class BatchOperator {
  Future<List<BatchResult>> batchPause(List<String> printerSns);
  Future<List<BatchResult>> batchResume(List<String> printerSns);
  Future<List<BatchResult>> batchCancel(List<String> printerSns);
  Future<List<BatchResult>> batchGcode({required List<String> printerSns, required String gcode});
  Future<List<BatchResult>> batchSetNozzleTemp({required List<String> printerSns, required double temp});
  Future<List<BatchResult>> batchEmergencyStop();  // ← 高优先级，更高并发
}

// ═══════════════════════════════════════════════════════════
// ConfigPushService
// ═══════════════════════════════════════════════════════════

class ConfigPushService {
  Future<(bool, Source)> push({
    required String ip, required int port,
    required String sn, required String brokerHost,
    required int brokerPort,
    required String mqttUsername, required String mqttPassword,
  });
}

// ═══════════════════════════════════════════════════════════
// PrinterDiscovery
// ═══════════════════════════════════════════════════════════

class PrinterDiscovery {
  Future<List<DiscoveredPrinter>> discoverMdns({Duration timeout = const Duration(seconds: 5)});
  Future<List<DiscoveredPrinter>> discoverTcp({required String subnet, int port = 7125, int concurrency = 50});
  static List<DiscoveredPrinter> merge(List<DiscoveredPrinter> mdns, List<DiscoveredPrinter> tcp);
}

// ═══════════════════════════════════════════════════════════
// HttpPoller
// ═══════════════════════════════════════════════════════════

class HttpPoller {
  void addPrinter(String sn, String ip, {int port = 7125, String? apiKey});
  void removePrinter(String sn);
  void start();
  void stop();
  Future<void> probeSingle(String sn);  // ← 新增：命令后即时确认
  Duration get adaptiveInterval;
}

// ═══════════════════════════════════════════════════════════
// CredentialStore (新增)
// ═══════════════════════════════════════════════════════════

class CredentialStore {
  static String generatePrinterPassword(String sn);
  Future<void> saveBrokerCredentials({required String host, required int port, required String username, required String password});
  Future<BrokerConfig?> loadBrokerCredentials();
  Future<void> clearBrokerCredentials();
}

// ═══════════════════════════════════════════════════════════
// BrokerHealthMonitor (新增)
// ═══════════════════════════════════════════════════════════

class BrokerHealthMonitor {
  void start();
  void stop();
  Stream<BrokerHealthState> get healthStream;
}

// ═══════════════════════════════════════════════════════════
// PrinterRegistry (新增)
// ═══════════════════════════════════════════════════════════

class PrinterRegistry {
  static Future<List<PrinterInfo>> loadAll();
  static Future<void> save(List<PrinterInfo> printers);
  static Future<void> add(PrinterInfo info);
  static Future<void> remove(String sn);
}
```

---

## 与前一版架构的主要变更

| 变更             | 前一版                   | 当前版                                                                            | 原因                                     |
| ---------------- | ------------------------ | --------------------------------------------------------------------------------- | ---------------------------------------- |
| Broker 部署      | App 子进程               | Docker 容器部署（docker compose）                                                | 7×24 可用性，跨平台一致，零运维负担      |
| 安全管理         | `allow_anonymous true`   | 用户名密码 + ACL                                                                  | 局域网安全基线                           |
| 新增类           | MqttBrokerManager        | DockerBrokerManager + BrokerConnectionManager + CredentialStore                  | Docker 管理 Mosquitto，职责分离          |
| HTTP 降级恢复    | 3 次重试后永久降级       | 后台 5min 间隔持续重试                                                            | 不应永久卡在降级                         |
| 数据竞争保护     | 无                       | eventTime 时间戳比较                                                              | MQTT/HTTP 同时写入安全                   |
| 累积指标         | 全量累加（错误）         | 增量累加                                                                          | 避免 totalDuration 指数增长              |
| 批量急停         | 20 并发，5s 超时         | 40 并发，5s 超时                                                                  | 急停必须最快速度覆盖                     |
| HTTP 命令确认    | 等下次轮询               | probeSingle 即时查询                                                              | 降级模式下命令确认延迟从 3s 降到 ~200ms  |
| 通知频率         | 每次写入 notifyListeners | 100ms 批处理窗口                                                                  | 100 台 × 1s 间隔 = 最多 10 次/秒 UI 重建 |
| 快照数量         | 20 条                    | 50 条                                                                             | 复杂问题排查需要更长历史                 |
| onChangeNotifier | 直接监听                 | 配合 Riverpod select() 精确重建                                                   | 减少不必要的 Widget rebuild              |

---

## 参考

- [Moonraker MQTT 源码](https://github.com/Arksine/moonraker/blob/master/moonraker/components/mqtt.py) — Topic 格式、config 参数
- [Mosquitto 官方文档](https://mosquitto.org/man/mosquitto-conf-5.html) — persistence, ACL, 安全配置
- [FDM Monster 架构](https://github.com/fdm-monster/fdm-monster-server) — 批量操作 Fan-Out 模式参考
- [OctoFarm 架构](https://github.com/OctoFarm/OctoFarm) — 独立 Server + Web UI 模式
- [DEVICE_ARCHITECTURE.md](flutter_zero_copy) — 单机控制架构（DeviceMetadataStore 模式来源）
- [Eclipse Mosquitto Docker](https://hub.docker.com/_/eclipse-mosquitto) — 生产部署参考

---

# 附录：Docker 启动 Mosquitto Broker 详解

## 1. 整体架构原理

在 lava-farm 中，Broker 是独立于 App 运行的 MQTT 消息中间件。核心职责：

```
所有打印机 ←──MQTT──→ Mosquitto Broker ←──MQTT──→ lava-farm App
                (独立进程，7×24 运行)
```

**为什么需要独立 Broker？**
- 打印任务持续数小时甚至数天，App 关闭后打印不能中断
- 100 台打印机每秒推送状态，需要专用的消息队列进程
- 支持多操作员（多个 App 实例同时连接同一个 Broker）

**为什么选 Mosquitto？**
- C 语言实现，内存占用极小（1000 连接仅需 ~50MB）
- 单核可支撑 10万+ msg/s 吞吐
- MQTT v5 + v3.1.1 双协议
- 内建 ACL + 认证 + TLS + persistence
- Docker 镜像仅 ~5MB

---

## 2. 快速启动

### 2.1 最简验证（无认证，仅测试用）

```bash
# 一行启动，不持久化，重启后数据丢失
docker run -d --name mosquitto-test \
  -p 1883:1883 \
  eclipse-mosquitto:2.0 \
  mosquitto -c /dev/null -v  # -v = verbose 日志，方便调试
```

验证是否启动成功：

```bash
# 终端1: 订阅
docker exec -it mosquitto-test mosquitto_sub -h localhost -t 'test/hello'

# 终端2: 发布
docker exec -it mosquitto-test mosquitto_pub -h localhost -t 'test/hello' -m 'world'
# 终端1 应收到 "world"
```

---

## 3. 生产部署：Docker Compose

### 3.1 目录结构

```
deployment/
├── docker-compose.yml
└── mosquitto/
    ├── config/
    │   ├── mosquitto.conf    # 主配置
    │   ├── passwd            # 用户密码（mosquitto_passwd 生成）
    │   └── acl               # 访问控制列表
    ├── data/                 # 持久化数据（Docker volume 挂载）
    └── log/
        └── mosquitto.log
```

### 3.2 docker-compose.yml

```yaml
version: '3.8'

services:
  mosquitto:
    image: eclipse-mosquitto:2.0
    container_name: lava-farm-broker
    restart: always                    # 崩溃自动重启
    network_mode: host                 # ← 关键：使用宿主机网络
    # host 网络模式下 ports 映射无效，容器直接监听宿主机端口
    volumes:
      - ./mosquitto/config:/mosquitto/config:ro   # :ro = 只读，防止容器篡改
      - ./mosquitto/data:/mosquitto/data
      - ./mosquitto/log:/mosquitto/log
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    # 健康检查：每 30s 用 mosquitto_sub 探测
    healthcheck:
      test: ["CMD", "mosquitto_sub", "-h", "localhost", "-t", "$$SYS/#", "-C", "1", "-W", "3"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
```

**为什么用 `network_mode: host`？**

| 网络模式 | 性能 | 适用场景 |
|----------|------|----------|
| `host` | ⭐⭐⭐ 最优（零 NAT 开销） | 单实例部署，打印机在同一局域网 |
| `bridge` + `-p 1883:1883` | ⭐⭐ 略有损耗 | 需要端口映射、多容器编排时 |
| `overlay` | ⭐ 有跨主机延迟 | 跨主机集群（Swarm / K8s） |

打印机数量 ≤ 100 时，bridge 模式的 NAT 损耗可忽略。选 `host` 主要是避免 IP 管理复杂度，直接监听宿主机 IP 即可。

### 3.3 启动命令

```bash
# 1. 创建目录
mkdir -p deployment/mosquitto/{config,data,log}

# 2. 写入配置文件（见下方 4.1）
# 3. 生成密码文件（见下方 4.2）
# 4. 写入 ACL 文件（见下方 4.3）

# 5. 启动
cd deployment
docker compose up -d

# 6. 查看日志
docker compose logs -f mosquitto

# 7. 验证
docker compose ps
# 期望输出: lava-farm-broker  Up (healthy)
```

---

## 4. 配置文件详解

### 4.1 mosquitto.conf 逐行说明

```ini
# ═══════════════════════════════════════════════════════════════
# 一、监听配置
# ═══════════════════════════════════════════════════════════════

# 监听端口 1883（MQTT 标准端口）
# 不指定 bind_address，默认监听所有网卡接口 0.0.0.0
listener 1883

# 【可选】绑定到指定网卡（多网卡时建议绑定 LAN 口 IP）
# bind_address 192.168.1.100

# 【可选】追加 WebSocket 监听，方便浏览器直接连 MQTT
# listener 9001
# protocol websockets


# ═══════════════════════════════════════════════════════════════
# 二、协议版本
# ═══════════════════════════════════════════════════════════════

# 支持 MQTT v5 协议（默认同时兼容 v3.1.1）
# Moonraker 使用 MQTT v3.1.1，这里不需要显式设置
# 如果只用 v5: protocol mqttv5


# ═══════════════════════════════════════════════════════════════
# 三、认证
# ═══════════════════════════════════════════════════════════════

# 拒绝匿名连接 — 每个客户端必须有用户名密码
allow_anonymous false

# 密码文件路径（容器内路径，与 docker-compose volume 对应）
# 生成方式: mosquitto_passwd -c passwd <username>
password_file /mosquitto/config/passwd


# ═══════════════════════════════════════════════════════════════
# 四、ACL（访问控制列表）
# ═══════════════════════════════════════════════════════════════

acl_file /mosquitto/config/acl


# ═══════════════════════════════════════════════════════════════
# 五、连接限制 — 防止资源耗尽
# ═══════════════════════════════════════════════════════════════

# 最大并发连接数 = 打印机数×2 + App数 + 余量
# 100打印机 × 2 (Moonraker + Klipper 各一?) = 通常只 Moonraker 一个连接
# 实际: 100 打印机 + 5 App 客户端 + 内部分 = ~150，取 200 留余量
max_connections 200

# 单客户端最大 inflight QoS>0 消息数（未确认的消息）
# 默认 20，增加到 50 以应对批量命令场景
max_inflight_messages 50

# 单客户端允许排队的最大 QoS 1/2 消息数
max_queued_messages 1000


# ═══════════════════════════════════════════════════════════════
# 六、持久化 — Broker 重启后会话恢复
# ═══════════════════════════════════════════════════════════════

# 启用持久化，crash 或重启后恢复 session
persistence true
persistence_location /mosquitto/data/

# 自动保存间隔（秒）
# 每 300 秒将内存中的持久化数据刷到磁盘
# 过小 → 频繁 I/O；过大 → 崩溃时丢失更多数据
autosave_interval 300

# 内存中最多缓存的持久化消息数
# 设为 0 = 无限制（磁盘空间够的前提下）
max_queued_messages 10000

# 【可选】QoS 0 消息也持久化（默认不持久化 QoS 0 消息）
# 不推荐开启 — 会显著增加 I/O
# persistence_qos0 false


# ═══════════════════════════════════════════════════════════════
# 七、MQTT 协议参数
# ═══════════════════════════════════════════════════════════════

# Keepalive 最大间隔（秒）
# 打印机通常设为 30s keepalive。Broker 允许 5~65535 范围
# 设为 65535 表示接受任意 keepalive
max_keepalive 300

# 1.5 × keepalive 时间内无通信 → 判定客户端离线
# 这是 Broker 层面的超时，配合 Moonraker Last Will 遗嘱消息使用
# 默认 = 1.5 × max_keepalive

# 单条消息最大大小（字节），默认无限制
# 限制以防内存攻击
message_size_limit 512000


# ═══════════════════════════════════════════════════════════════
# 八、日志
# ═══════════════════════════════════════════════════════════════

# 输出到文件（生产环境）
log_dest file /mosquitto/log/mosquitto.log

# 输出到 stdout（Docker 环境也推荐开启，方便 docker logs 查看）
log_dest stdout

# 仅记录 error + warning + notice（正常连接不记录，避免日志爆炸）
log_type error
log_type warning
log_type notice

# 记录客户端连接/断开事件（排查问题有用）
connection_messages true

# 日志时间戳格式
log_timestamp true
log_timestamp_format %Y-%m-%dT%H:%M:%S


# ═══════════════════════════════════════════════════════════════
# 九、系统监控 topic（可选）
# ═══════════════════════════════════════════════════════════════

# 开启 $SYS 主题，暴露 Broker 内部指标
# $SYS/broker/bytes/received
# $SYS/broker/bytes/sent
# $SYS/broker/clients/connected
# $SYS/broker/clients/maximum
# $SYS/broker/messages/received
# $SYS/broker/messages/sent
# $SYS/broker/heap/current
# 等等...
sys_interval 10
```

### 4.2 密码文件（passwd）生成

```bash
# 进入 config 目录
cd deployment/mosquitto/config

# 创建密码文件并添加 App 管理用户（-c 表示创建新文件）
mosquitto_passwd -c passwd lava_app
# 交互式输入密码 → 哈希后写入 passwd 文件
# 文件内容示例:
# lava_app:$7$101$SALT$HASH==   ← pbkdf2 哈希，不可逆

# 追加打印机用户（-b 非交互，适合脚本批量生成）
mosquitto_passwd -b passwd printer_SN001 $(openssl rand -base64 16)
mosquitto_passwd -b passwd printer_SN002 $(openssl rand -base64 16)
# ... 每台打印机一个用户

# 批量脚本示例:
#!/bin/bash
echo ">>> 正在为打印机 $1 生成 Broker 凭据..."
PASSWORD=$(openssl rand -base64 16)
mosquitto_passwd -b /mosquitto/config/passwd "printer_$1" "$PASSWORD"
echo "用户名: printer_$1"
echo "密码:    $PASSWORD"
# 将凭据透传给 ConfigPushService ↓
```

**原理**：`mosquitto_passwd` 使用 PBKDF2 哈希加盐存储密码，不可逆。Broker 收到 CONNECT 报文后，从 passwd 文件读取对应用户的哈希，对客户端提交的密码做同样的 PBKDF2 哈希，比较结果。

### 4.3 ACL 文件详解

```ini
# ═══════════════════════════════════════════════════════════════
# ACL 设计原理
# ═══════════════════════════════════════════════════════════════
#
# Mosquitto ACL 按顺序匹配，找到第一个匹配的规则后停止。
# 因此: 先写具体规则，最后写默认策略 → 类似防火墙规则
#
# 权限模型:
#   topic [read|write|readwrite] <topic_pattern>
#
# 通配符:
#   +  单层匹配 (如 +/status 匹配 001/status，不匹配 001/sub/status)
#   #  多层匹配 (如 # 匹配所有 topic)
#
# lava-farm ACL 设计:
#   - App (lava_app):  全局读写 → readwrite +/#
#   - 打印机:          仅操作自己 SN 前缀的 topic
# ═══════════════════════════════════════════════════════════════

# ── 第 1 条: App 管理客户端 ──
# 拥有最高权限：可以读写所有 topic
user lava_app
topic readwrite +/#


# ── 第 2~N 条: 打印机客户端 ──
# 每台打印机仅能操作自己 SN 下的 topic
# "printer 读 request" = 打印机接收发给自己的命令
# "printer 写 status"  = 打印机发布自己的状态

user printer_SN001
topic read SN001/request
topic write SN001/status
topic write SN001/notification
topic write SN001/response

user printer_SN002
topic read SN002/request
topic write SN002/status
topic write SN002/notification
topic write SN002/response

# ... 每增加一台打印机，追加一组 4 条规则

# ── 安全兜底: 拒绝所有未匹配的连接 ──
# (Mosquitto 2.0+ 默认拒绝没有 ACL 规则的用户)

# 如果想显式拒绝:
# user anonymous
# topic deny #
```

**ACL 为什么这样设计？**
- 打印机 A 不能订阅/发布打印机 B 的 topic → 防止误操作或恶意干扰
- App 有全局权限 → 可以管理所有打印机
- 每个打印机 4 个 topic（request/status/notification/response）→ 最小权限原则

---

## 5. 配置原理深入

### 5.1 MQTT 连接流程

```
打印机 Moonraker                     Mosquitto Broker                     lava-farm App
     │                                      │                                  │
     │── CONNECT ──────────────────────────→│                                  │
     │   clientId: "8110026B060740017"       │                                  │
     │   username: "printer_SN001"           │── 查 passwd 验证密码              │
     │   password: "..."                     │── 查 ACL 检查权限                │
     │   will_topic: "SN001/notification"    │                                  │
     │   will_payload: {"server":"offline"}  │  记录遗嘱消息                     │
     │   keepalive: 30                       │                                  │
     │                                       │                                  │
     │←─ CONNACK (accepted) ────────────────│                                  │
     │                                       │                                  │
     │── SUBSCRIBE SN001/request ───────────→│  检查 ACL: printer_SN001 有 read │
     │←─ SUBACK ────────────────────────────│                                  │
     │                                       │                                  │
     │── PUBLISH SN001/notification ────────→│  检查 ACL: printer_SN001 有 write│
     │   {"server":"online"}                 │                                  │
     │                                       │──→ 路由给订阅了 +/notification   │
     │                                       │    ────────────────────────────→│
     │                                       │     lava_app 收到上线通知        │
     │                                       │                                  │
     │── PUBLISH SN001/status ──────────────→│  检查 ACL: printer_SN001 有 write│
     │   (每秒1次)                           │──→ 路由给订阅了 +/status         │
     │                                       │    ────────────────────────────→│
     │                                       │     lava_app 实时更新 UI         │
```

### 5.2 Last Will（遗嘱消息）原理

```
正常离线:
  打印机 → DISCONNECT → Broker 清除 Will 消息（不发布 offline）

异常离线 (断电/断网/crash):
  Broker 检测心跳超时 (1.5 × keepalive = 45s)
    → Broker 自动发布打印机预设的 Will 消息:
      Topic: SN001/notification
      Payload: {"server":"offline"}
      → lava_app 订阅 +/notification 收到 → 标记打印机离线
```

**关键配置**：打印机的 Moonraker MQTT 配置中的 `status_interval` 和 `keepalive` 决定了检测延迟。典型值：keepalive=30s → 最坏 45s 检测到离线。

### 5.3 Persistence（持久化）原理

```
正常状态:
  所有 session 数据在内存中
  autosave_interval 300 → 每 5 分钟刷盘一次

Broker 重启 (docker restart / 进程崩溃):
  1. Mosquitto 启动 → 读取 /mosquitto/data/*.db
  2. 恢复所有持久化 session:
     - 客户端的订阅关系
     - QoS ≥ 1 的未投递消息
  3. 打印机检测到连接断开 → 自动重连 (Moonraker _do_reconnect)
  4. 重连后恢复 session → 继续正常通信

autosave_interval 设置权衡:
  间隔大 (1800s): 崩溃时可能丢失 30 分钟内的增量
  间隔小 (60s):  频繁 I/O，树莓派 SD 卡可能吃不消
  推荐: 300s (5分钟) — 平衡点是即使崩溃最坏也就丢 5 分钟内的 QoS 消息
```

### 5.4 QoS 与消息可靠性

```
QoS 0 (最多一次)     — lava-farm 不用
  PUBLISH → 不等待确认，可能丢消息

QoS 1 (至少一次)     — lava-farm 主力使用
  PUBLISH → PUBACK ← (发送方等待确认)
  ✓ 保证至少送达一次
  ✗ 可能重复送达（App 侧需幂等处理）

QoS 2 (恰好一次)     — 开销大，lava-farm 不用
  四次握手保证恰好一次，延迟高，不适合高频状态推送

lava-farm QoS 策略:
  打印机状态 (/status):    QoS 1 — 需要可靠
  打印机通知 (/notification): QoS 1 — 遗嘱消息不能丢
  App 命令 (/request):     QoS 1 — 命令必须送达
  App 响应 (/response):    QoS 1 — 确保命令结果被接收
```

---

## 6. 启动后验证

### 6.1 基础连通性

```bash
# 1. 检查容器状态
docker compose ps
# 应输出: lava-farm-broker  Up (healthy)

# 2. 检查端口监听
netstat -tlnp | grep 1883
# 或: ss -tlnp | grep 1883

# 3. 用 mosquitto_sub/mosquitto_pub 验证（需要 mosquitto-clients）
brew install mosquitto  # macOS
apt install mosquitto-clients  # Linux

# 订阅 $SYS 主题，查看 Broker 内部指标
mosquitto_sub -h <broker_ip> -p 1883 \
  -u lava_app -P <password> \
  -t '$SYS/broker/clients/connected' -v

# 发布测试消息
mosquitto_pub -h <broker_ip> -p 1883 \
  -u lava_app -P <password> \
  -t 'test/hello' -m 'lava-farm test'
```

### 6.2 模拟打印机入网

```bash
# 终端1: 以打印机身份连接 + 发布状态
mosquitto_pub -h <broker_ip> -p 1883 \
  -u printer_SN001 -P <printer_password_1> \
  -t 'SN001/status' -m '{"extruder":{"temperature":210}}' \
  --will-topic 'SN001/notification' --will-payload '{"server":"offline"}' \
  -d  # -d = debug，打印所有协议交互

# 终端2: 以 App 身份订阅
mosquitto_sub -h <broker_ip> -p 1883 \
  -u lava_app -P <app_password> \
  -t '+/status' -t '+/notification' -v
# 应看到: SN001/status {"extruder":{"temperature":210}}
```

### 6.3 权限隔离验证

```bash
# 测试: 打印机 SN001 尝试写 SN002 的 topic → 应该被拒绝
mosquitto_pub -h <broker_ip> -p 1883 \
  -u printer_SN001 -P <printer_password_1> \
  -t 'SN002/status' -m 'malicious data' \
  -d
# 预期: Connection Refused: not authorised
# 或 ACL denial，消息被静默丢弃（取决于 mosquitto 版本和 acl 设置）
```

---

## 7. 常见问题排查

### 7.1 容器启动失败

```bash
# 查看完整日志
docker compose logs mosquitto

# 常见错误:
# 1. "Unable to open config file" → volumes 路径错误
# 2. "Address already in use" → 1883 端口被占用
# 3. "password_file: No such file" → passwd 文件未创建
```

### 7.2 打印机连不上 Broker

```bash
# 1. 检查防火墙
sudo ufw status  # Linux
# 或检查宿主机防火墙是否放行 1883

# 2. 检查 Broker 是否监听正确接口
docker exec lava-farm-broker netstat -tlnp | grep 1883

# 3. 从打印机所在的机器测试连通性
nc -zv <broker_ip> 1883

# 4. 检查 ACL 是否拒绝连接
docker compose logs mosquitto | grep "denied"
```

### 7.3 App 连接后收不到消息

```bash
# 1. 确认订阅成功
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -u lava_app -P <password> \
  -t '$SYS/broker/subscriptions/count' -C 1

# 2. 检查是否有消息在流
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -u lava_app -P <password> \
  -t '+/status' -C 5  # 取 5 条后退出

# 3. 检查 inflight/queued
# $SYS/broker/messages/inflight
# $SYS/broker/messages/stored   ← 持久化队列中的消息数
```

---

## 8. 安全加固（生产环境推荐）

```ini
# ── mosquitto.conf 追加 ──

# 限制客户端 ID 最大长度
max_clientid_length 128

# 限制单客户端发布速率（防止打印机异常大量发消息）
# 单位：条/秒。100 条/秒对 1 台打印机已非常宽松
# max_packet_size 65536  # 单包最大 64KB

# TLS 加密（局域网场景可选，公网部署必须）
# listener 8883
# cafile /mosquitto/config/ca.crt
# certfile /mosquitto/config/server.crt
# keyfile /mosquitto/config/server.key
# require_certificate true
# use_identity_as_username true
```

---

## 9. 资源估算

| 打印机数量 | 推荐内存 | 推荐 CPU | 磁盘（持久化） |
|-----------|---------|---------|---------------|
| ≤ 10 | 64 MB | 任意 | 1 GB |
| ≤ 50 | 128 MB | 任意 | 2 GB |
| ≤ 100 | 256 MB | 任意 | 5 GB |
| ≤ 200 | 512 MB | 1 核 | 10 GB |

Mosquitto 极其轻量，树莓派 4B (4GB) 即可支撑 200 台打印机。

---

## 10. 运维命令速查

```bash
# 启动/停止/重启
docker compose up -d
docker compose down
docker compose restart mosquitto

# 查看实时日志
docker compose logs -f mosquitto
docker compose logs --tail=100 mosquitto

# 查看当前连接数
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/clients/connected' -C 1 -W 3

# 查看持久化文件
ls -lh deployment/mosquitto/data/

# 添加新打印机用户（在线添加，无需重启 Broker）
mosquitto_passwd -b deployment/mosquitto/config/passwd \
  "printer_${SN}" "$(openssl rand -base64 16)"

# 重载配置（仅限部分参数；认证/ACL 文件会自动 reload）
docker exec lava-farm-broker pkill -HUP mosquitto
# 注意: HUP 信号会重载 password_file 和 acl_file，不中断现有连接
```
