# Design: lava-farm — 独立 Broker + 桌面 App 纯客户端

## 1. 架构总览

```
┌──────────────────────────────────────────────────────────────────────────┐
│                        Flutter Desktop UI                                │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐  │
│  │ 打印机网格   │  │ 批量操作面板  │  │ 设备发现向导  │  │ Broker 设置   │  │
│  │ PrinterGrid │  │ BatchPanel   │  │ DiscoveryWiz │  │ BrokerSetup  │  │
│  └──────┬──────┘  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘  │
│         └────────────────┼─────────────────┼─────────────────┘          │
│                          │ Riverpod Providers                           │
│  ┌───────────────────────┼────────────────────────────────────────────┐  │
│  │                Application Layer (lib/features/farm/application/)   │  │
│  │  farmStoreProvider  │  batchOperationProvider  │  brokerStateProvider │
│  │  discoveryProvider  │  printerListProvider     │  farmStatsProvider   │
│  └───────────────────────┼────────────────────────────────────────────┘  │
└──────────────────────────┼──────────────────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────────────────┐
│                   Data Layer (lib/features/farm/data/)                   │
│                                                                          │
│  ┌────────────────────────┴───────────────────────────────────────┐    │
│  │                      FarmStore ⭐                                │    │
│  │  多设备状态聚合 — 单入口读写 — 时间戳保护 — 中间件 — 快照         │    │
│  │  Map<String, FarmPrinterState>  _printers                       │    │
│  │                                                                  │    │
│  │  写入路径:                                                        │    │
│  │    MQTT +/status  ──→ onMqttStatus(sn, payload, eventTime)      │    │
│  │    MQTT +/notif   ──→ onMqttNotification(sn, data)              │    │
│  │    HTTP 轮询      ──→ onHttpPollResult(sn, payload, pollTime)   │    │
│  │    HTTP 失败      ──→ onHttpPollFailed(sn)                      │    │
│  │    连接监控       ──→ forceOffline(sn, reason)                  │    │
│  │    批量操作结果   ──→ onBatchResult(sn, result)                 │    │
│  │                                                                  │    │
│  │  中间件: 时间戳比较 · 字段合并 · staleness · MQTT/HTTP 来源标记   │    │
│  └──────────────────────────────────────────────────────────────────┘    │
│                                                                          │
│  ┌────────────────────┐  ┌──────────────────────┐  ┌─────────────────┐  │
│  │BrokerConnectionMgr │  │ ConfigPushService     │  │ BatchOperator   │  │
│  │ • 连接外部 Broker  │  │ • POST /server/config │  │ • Fan-Out       │  │
│  │ • 自动重连(退避)   │  │ • POST /server/restart│  │ • 优先级队列    │  │
│  │ • MQTT PING 健康   │  │ • 后台升级重试        │  │ • 20/40 并发    │  │
│  └────────┬───────────┘  └──────────┬───────────┘  └────────┬────────┘  │
│           │                         │                        │           │
│  ┌────────┴───────────┐  ┌──────────┴───────────┐                        │
│  │ BrokerHealthMonitor│  │ HttpPoller (降级通道) │                        │
│  │ • PING 周期检测    │  │ • 请求队列 (20并发)  │                        │
│  │ • 假活判定         │  │ • 自适应间隔         │                        │
│  │ • 连续失败告警     │  │ • probeSingle 即时确认│                       │
│  └────────────────────┘  │ • 后台 MQTT 升级尝试  │                        │
│                          └──────────────────────┘                        │
│  ┌────────────────────┐  ┌──────────────────────┐                        │
│  │ CredentialStore    │  │ PrinterRegistry      │                        │
│  │ • 凭据安全存储     │  │ • Hive 持久化封装    │                        │
│  │ • 打印机密码生成   │  │ • 批量导入/导出      │                        │
│  └────────────────────┘  └──────────────────────┘                        │
└──────────────────────────────────────────────────────────────────────────┘
                           │
┌──────────────────────────┼──────────────────────────────────────────────┐
│                          │        SDK Layer                              │
│  ┌───────────────────────┴────────────────────────────────────────────┐  │
│  │  lava_device_sdk (复用)                                             │  │
│  │  MoonrakerAdapter  │  MqttTransport  │  JsonRpcRequest/Response    │  │
│  └────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                           │
              ┌────────────┼────────────────────────┐
              │            │                        │
        ┌─────┴──────┐     │              ┌─────────┴──────────┐
        │ Mosquitto  │     │              │ Moonraker Printer N │
        │ Broker     │     │              │ :7125 (HTTP)        │
        │ 独立部署   │     │              │ → Broker :1883      │
        │ 7×24 :1883 │     │              │ Topic: SN/status    │
        └────────────┘     │              └─────────────────────┘
              │            │
              └── MQTT ────┴── lava-farm App (纯客户端)
```

---

## 2. 部署模型

### 2.1 双模式设计

lava-farm 提供两种部署模式：

```
生产模式（推荐）:
  Mosquitto Broker 独立部署（Docker / RPi / Linux 服务器）
  固定 IP，7×24 运行，认证 + ACL
  App 可随时开关不影响打印机通信
  支持多操作员（多 App 实例同时连接）

快速体验模式（评估用，≤ 10 台）:
  App 内嵌 Mosquitto 子进程
  零配置，开箱即用
  关闭 App = 断开所有打印机
  UI 顶部橙色警告条持续提示
```

### 2.2 生产模式 Broker 部署

**方案 A：Docker Compose（推荐）**
- 一行 `docker compose up -d`
- 适用于 NAS、Linux 服务器、Mac mini、Windows WSL2

**方案 B：Raspberry Pi 一键脚本**
- `curl | bash` 一键安装配置
- $35 硬件成本，适合专用部署

**方案 C：系统包管理器**
- `apt install mosquitto` / `brew install mosquitto`
- 已有 Linux 服务器用户的选项

App 内置 Broker 配置生成器：输入部署方式 → 生成 `mosquitto.conf` + `passwd` + `acl` → 用户复制到目标机器。

### 2.3 快速体验模式限制

- App 需阻止系统休眠
- 关闭 App 前检测活跃打印任务并弹窗确认
- 不提供崩溃恢复（进程随 App 生命周期）
- 无认证（仅限 localhost 连接）

---

## 3. 与单机架构的关系

### 3.1 架构对比

| 维度 | 单机 (flutter_zero_copy) | 群控 (lava-farm) |
|------|--------------------------|-------------------|
| **活跃设备数** | 1 (DeviceSessionImpl) | N (最多100) |
| **MQTT 连接** | 每设备独立连接 | 1 条连接到外部 Broker |
| **Broker 管理** | 不涉及 | 连接管理（BrokerConnectionManager），不管理 Broker 生命周期 |
| **消息流向** | App → 设备 (一对一) | Broker 聚合 → App (多对一) |
| **状态存储** | DeviceMetadataStore | FarmStore (同样单入口 + 新增时间戳保护) |
| **连接管理** | DeviceSession.activate/deactivate | BrokerConnectionManager.connect/disconnect |
| **命令发送** | DeviceImpl.sendCommand | BatchOperator.fanOut (MQTT/HTTP 双通道路由) |
| **配置方式** | 手动输入 IP + Access Code | 发现 → 远程推送 [mqtt] 配置（含凭据） |
| **安全模型** | Access Code | Broker 认证 + ACL + Access Code |

### 3.2 复用关系

```
lava_device_sdk (共享)
├── MoonrakerAdapter      ← 群控复用：解析 MQTT 消息格式
├── JsonRpcRequest        ← 群控复用：构建 JSON-RPC 命令
├── MqttTransport         ← 群控复用：MQTT 客户端连接
└── StateTree             ← 群控不直接用，FarmStore 替代

lava-farm (新建)
├── FarmStore             ← 新：多设备聚合（时间戳保护 + 批处理通知）
├── BrokerConnectionManager ← 新：外部 Broker 连接 + 自动重连
├── BrokerHealthMonitor   ← 新：Broker 健康监控 + 假活检测
├── CredentialStore       ← 新：凭据生成与安全存储
├── PrinterRegistry       ← 新：Hive 持久化封装
├── ConfigPushService     ← 新：Moonraker HTTP API 封装 + 后台升级重试
├── BatchOperator         ← 新：批量命令 Fan-Out（含优先级队列）
├── PrinterDiscovery      ← 新：局域网设备发现
├── HttpPoller            ← 新：HTTP 轮询降级（含 probeSingle + 后台升级）
└── FarmConnectionMonitor ← 新：心跳 + 假在线检测
```

---

## 4. Broker 连接管理

### 4.1 BrokerConnectionManager

连接到外部 Broker，不管理 Broker 进程：

```
连接流程:
  FarmHub.start()
    → BrokerConnectionManager.connect(host, port, username, password)
      → MqttTransport.connect()
      → subscribe('+/status', qos: 1)
      → subscribe('+/notification', qos: 1)
      → brokerConnState = connected
      → 启动 BrokerHealthMonitor (周期性 PING)
      → 启动 FarmConnectionMonitor (打印机心跳)

断开流程:
  FarmHub.shutdown()
    → FarmConnectionMonitor.stop()
    → BrokerHealthMonitor.stop()
    → HttpPoller.stop()
    → BrokerConnectionManager.disconnect()
      → MqttTransport.disconnect()
      → brokerConnState = disconnected

Broker 断连恢复:
  MQTT 连接断开
    → brokerConnState = degraded
    → 指数退避重连 (2s → 4s → 8s → ... → 30s max)
    → 重连成功 → 重新订阅 +/status, +/notification
    → brokerConnState = connected

Broker 假活检测:
  BrokerHealthMonitor 每 15s 发送 MQTT PINGREQ
    → 期待 PINGRESP
    → 连续 3 次无响应 → 判定假活 → 触发重连
```

### 4.2 BrokerConnectionManager 接口

```dart
class BrokerConnectionManager {
  Stream<BrokerConnState> get stateStream;
  BrokerConnState get state;
  bool get isConnected;

  Future<void> connect({
    required String host,
    required int port,
    required String username,
    required String password,
  });
  Future<void> disconnect();
}

enum BrokerConnState { disconnected, connecting, connected, degraded, error }
```

### 4.3 与旧版 MqttBrokerManager 的差异

| 旧版 MqttBrokerManager | 新版 BrokerConnectionManager |
|------------------------|------------------------------|
| 管理 Mosquitto 子进程 | 连接已有的 Broker |
| Process.start / kill | MqttTransport.connect / disconnect |
| 生成 mosquitto.conf | 读取 Broker 凭据 |
| 端口探活 | MQTT PING 健康检测 |
| 崩溃恢复（重启子进程） | 自动重连（指数退避） |
| 检查 mosquitto 是否安装 | 不涉及 |

---

## 5. 打印机入网流程

### 5.1 发现 → 配置 → 验证

```
Step 1: 发现
  mDNS: 扫描 _moonraker._tcp.local → 获取 IP + 端口
  TCP:  扫描 192.168.1.0/24:7125 → HTTP GET /server/info
  → 合并去重 → 展示发现列表

Step 2: 验证
  POST /access/login → 获取 Token
  ⚠️ 检查打印机当前状态:
    if (打印中) → 警告用户：重配 MQTT 需重启 Moonraker，将中断打印

Step 3: 获取设备信息
  GET /server/info → 记录 SN, 型号, 固件版本

Step 4: 推送 MQTT 配置（含 Broker 凭据）
  POST /server/config
  Body: { config: { mqtt: {
    address: "<Broker 固定 IP>",
    port: 1883,
    username: "printer_<SN>",
    password: "<随机生成>",
    instance_name: "<SN>",
    status_interval: 1.0,
    enable_moonraker_api: true
  }}}
  → 成功 → POST /server/restart (重启 Moonraker)
  → 失败 → 标记为 HTTP 降级 + 15s 后重试（最多 3 次）

Step 5: 等待 MQTT 连接
  订阅 +/notification, 等待 SN 的 online 消息
  超时 20s → 标记 HTTP 降级

Step 6: 注册到系统
  FarmStore.onPrinterRegistered() → 持久化到 Hive
```

### 5.2 发现协议

```dart
class PrinterDiscovery {
  Future<List<DiscoveredPrinter>> discoverMdns({
    Duration timeout = const Duration(seconds: 5),
  });

  Future<List<DiscoveredPrinter>> discoverTcp({
    required String subnet,
    int port = 7125,
    int startIp = 1,
    int endIp = 254,
    int concurrency = 50,
    Duration timeout = const Duration(milliseconds: 500),
  });

  static List<DiscoveredPrinter> merge(
    List<DiscoveredPrinter> mdns,
    List<DiscoveredPrinter> tcp,
  );
}
```

---

## 6. FarmStore — 多设备状态聚合

### 6.1 设计原则

- **单入口写入**：所有数据源只往 FarmStore 写
- **时间戳保护**：解决 MQTT 和 HTTP 同时写入的竞争条件
- **中间件集中**：校验、合并、staleness、快照全在 FarmStore 内
- **批处理通知**：100ms 窗口合并通知，100 台打印机最多 10 次/秒 UI 重建
- **Riverpod 驱动**：FarmStore 的变化通过 `farmStoreProvider` 通知 UI

### 6.2 写入方法（含时间戳保护）

```dart
class FarmStore {
  final Map<String, FarmPrinterState> _printers = {};

  /// MQTT 状态推送（主力通道）
  void onMqttStatus(String sn, Map<String, dynamic> status, {DateTime? eventTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 时间戳保护
    if (eventTime != null && printer.lastDataTimestamp != null) {
      if (!eventTime.isAfter(printer.lastDataTimestamp!)) return;
    }

    printer.updateTelemetry(status, eventTime: eventTime);
    printer.markFresh(Source.mqtt);
    _notify();  // 批处理通知
  }

  /// HTTP 轮询结果（降级通道）
  void onHttpPollResult(String sn, Map<String, dynamic> data, {required DateTime pollTime}) {
    final printer = _printers[sn];
    if (printer == null) return;

    // 丢弃比已有 MQTT 数据更旧的 HTTP 数据
    if (printer.lastDataTimestamp != null && !pollTime.isAfter(printer.lastDataTimestamp!)) {
      return;
    }

    printer.updateTelemetry(data, eventTime: pollTime);
    printer.markFresh(Source.http);
    _notify();
  }

  /// HTTP 轮询单次失败（不直接改状态，由连接监控累积判定）
  void onHttpPollFailed(String sn) {
    // 仅记录，状态由 FarmConnectionMonitor 累积判定
  }

  /// MQTT 通知（Last Will）
  void onMqttNotification(String sn, Map<String, dynamic> data);

  /// 强制离线（连接监控触发）
  void forceOffline(String sn, String reason);

  // ... onPrinterRegistered, onPrinterRemoved, onBatchResult 等
}
```

### 6.3 批处理通知

```dart
class FarmStore {
  Timer? _batchTimer;
  static const _batchWindow = Duration(milliseconds: 100);

  void _notify() {
    if (_batchTimer == null || !_batchTimer!.isActive) {
      _batchTimer = Timer(_batchWindow, () {
        _notifier.notifyListeners();
        _batchTimer = null;
      });
    }
  }
}
```

UI 端配合 Riverpod `select()` 精确重建：
```dart
// 只有 SN001 的温度变了才重建此 Widget
final temp = ref.watch(farmStoreProvider
  .select((s) => s['SN001']?.nozzleTemp?.value));
```

### 6.4 FarmPrinterState

```dart
class FarmPrinterState {
  final String sn;
  String? displayName;
  String ip;
  int port;
  String? group;

  // 通信模式
  Source source;              // mqtt | http
  FarmConnectionState connectionState;

  // 实时遥测 (Staleable)
  Staleable<double>? nozzleTemp;
  Staleable<double>? bedTemp;
  Staleable<String>? printState;
  Staleable<double>? progress;
  Staleable<String>? currentFile;

  // 数据版本（用于解决 MQTT/HTTP 竞争）
  DateTime? lastDataTimestamp;

  // 累积指标（增量累加）
  double? totalDuration;
  double? filamentUsed;
  double? _lastReportedDuration;

  // 配置
  String? model;
  String? firmwareVersion;

  // 批量操作
  BatchResult? lastBatchResult;

  // 快照 (环形缓冲 50 条)
  final List<FarmSnapshot> _snapshots = [];
}
```

---

## 7. 通信层：MQTT + HTTP 双通道

### 7.1 MQTT Topic 结构

```
通配符订阅 (App → Broker):
  +/status           ← 所有打印机状态推送
  +/notification     ← Last Will 遗嘱消息

单设备 topic:
  {SN}/request       → App 发送 JSON-RPC 命令
  {SN}/response      ← 打印机返回命令结果
  {SN}/status        ← 打印机定时状态推送
  {SN}/notification  ← 设备上线/下线
```

### 7.2 MQTT 消息处理

```
MQTT 消息到达 (MqttTransport.messageStream)
  │
  ├─ topic 匹配 +/status
  │   → 提取 SN → 解析 JSON-RPC
  │   → 提取 eventtime 作为数据时间戳
  │   → MoonrakerAdapter._expandStatus() 展平嵌套对象
  │   → FarmStore.onMqttStatus(sn, expanded, eventTime)
  │
  ├─ topic 匹配 +/notification
  │   → 提取 SN → 解析 JSON → FarmStore.onMqttNotification(sn, data)
  │
  └─ topic 匹配 {SN}/response
      → RequestTracker 匹配 → 完成对应 Future
```

### 7.3 HTTP 降级通道

```dart
class HttpPoller {
  final FarmStore _store;
  final _queue = RequestQueue(maxConcurrency: 20);
  Timer? _timer;
  Timer? _upgradeTimer;  // 后台升级重试

  void addPrinter(String sn, String ip, {int port = 7125, String? apiKey});

  /// 命令发送后即时确认
  Future<void> probeSingle(String sn);

  /// 后台升级重试：每 5 分钟尝试推送 MQTT 配置
  void _startUpgradeRetries();

  Duration get adaptiveInterval {
    // 只看 HTTP 降级打印机的状态，不与 MQTT 打印机混合计算
    if (_store.httpPrintingCount > 0) return Duration(seconds: 3);
    if (_store.httpOnlineCount > 0)  return Duration(seconds: 15);
    return Duration(seconds: 30);
  }
}
```

关键改进：
- `probeSingle`：HTTP 命令发送后立即触发一次即时轮询，降低命令确认延迟
- `_startUpgradeRetries`：后台每 5 分钟重试推送 MQTT 配置，不再永久卡在降级
- `adaptiveInterval` 只看 HTTP 打印机的状态，避免被 MQTT 打印机状态污染

---

## 8. 批量操作引擎

### 8.1 Fan-Out 模式

```dart
class BatchOperator {
  final FarmStore _store;
  final FarmMqttRouter _mqttRouter;
  static const int maxConcurrency = 20;
  static const int highPriorityConcurrency = 40;  // 急停等场景

  /// 批量急停 — 高优先级，40 并发，5s 超时
  Future<List<BatchResult>> batchEmergencyStop();

  /// 批量暂停/取消/恢复/GCode/温度 — 20 并发
  Future<List<BatchResult>> batchPause(List<String> printerSns);
  Future<List<BatchResult>> batchResume(List<String> printerSns);
  Future<List<BatchResult>> batchCancel(List<String> printerSns);
  Future<List<BatchResult>> batchGcode({required List<String> sns, required String gcode});
  Future<List<BatchResult>> batchSetNozzleTemp({required List<String> sns, required double temp});

  /// 命令路由: MQTT (主力) 或 HTTP (降级)
  Future<void> _sendCommand(String sn, String method, [Map<String, dynamic>? params]) {
    final printer = _store.getPrinter(sn)!;
    if (printer.source == Source.mqtt) {
      return _mqttRouter.sendCommand(sn, method, params);  // 有响应确认
    } else {
      // HTTP 命令 + probeSingle 即时确认
      return _sendHttpCommand(...).then((_) => _httpPoller?.probeSingle(sn));
    }
  }
}
```

### 8.2 批量操作 UI 流程

```
用户操作流程 (以批量暂停为例):
  1. 用户在网格中勾选打印机
  2. 点击工具栏 "暂停打印" 按钮
  3. 确认对话框: "暂停 12 台打印机的当前打印?"
  4. 确认 → BatchOperator.batchPause(sns)
  5. 每台打印机状态实时更新:
     ├─ MQTT 打印机: 等 {SN}/response → 更新卡片
     ├─ HTTP 打印机: POST 命令 → probeSingle() → 更新卡片
     └─ 超时打印机: 显示错误信息
  6. 底部通知栏: "批量暂停完成: 12/12 成功, 耗时 1.2s"
```

---

## 9. 连接管理与健康监控

### 9.1 连接状态定义

```dart
enum FarmConnectionState {
  online,           // 在线
  offline,          // 离线
  configuring,      // 正在推送配置
  restarting,       // Moonraker 重启中
  degraded,         // 延迟高但可通
}
```

### 9.2 故障检测矩阵

```
故障类型              检测方式                  检测延迟    恢复方式
────────────────────────────────────────────────────────────────
打印机断电           Last Will offline         1-3s       用户手动重连
打印机 MQTT 断连     Last Will offline         1-3s       Moonraker 自动重连
打印机假在线         60s 无状态更新              60s        forceOffline + 通知
Broker 崩溃          BrokerHealthMonitor       < 15s      App 等待自动重连
Broker 假活          MQTT PINGREQ 无响应       15-45s     App 触发重连
App 断连 Broker      MQTT 连接断开              < 5s       自动重连(指数退避)
ConfigPush 失败      HTTP 4xx/5xx              即时       降级 HTTP + 5min 后台重试
HTTP 轮询失败        连续 3 次超时              30-45s      forceOffline
```

### 9.3 FarmConnectionMonitor

```dart
class FarmConnectionMonitor {
  // 每 30s 检查所有在线打印机的最后状态时间
  // 超过 60s → forceOffline(sn, 'heartbeat_timeout')
  // 利用 Moonraker Last Will 遗嘱消息（1-3s 延迟）
}
```

---

## 10. 安全设计

### 10.1 安全层次

```
第 1 层: Broker 认证
  每个客户端有独立用户名/密码
  allow_anonymous false

第 2 层: Topic ACL
  打印机 A 不能访问打印机 B 的 topic
  App 管理客户端有全局 readwrite +/#

第 3 层: 打印机 Access Code
  入网时需输入预设 Access Code

第 4 层: 凭据安全存储
  App 端: flutter_secure_storage / keychain
  Broker 端: mosquitto_passwd (hashed)
```

### 10.2 ACL 示例

```
user lava_app
topic readwrite +/#

user printer_8110026B060740017
topic read 8110026B060740017/request
topic write 8110026B060740017/status
topic write 8110026B060740017/notification
topic write 8110026B060740017/response
```

---

## 11. 文件分发

```dart
class FileUploader {
  static const int maxConcurrentUploads = 5;

  Future<List<UploadResult>> batchUpload({
    required List<String> printerSns,
    required String localFilePath,
    required String remoteFileName,
    FarmStore? store,
    void Function(int completed, int total)? onProgress,
  });

  // 限制: 单文件 ≤ 200MB
  // HTTP multipart 上传到 /server/files/upload
}
```

---

## 12. UI 架构

### 12.1 Riverpod Provider 设计

```dart
// 核心 Store
final farmStoreProvider = StateNotifierProvider<FarmStoreNotifier, Map<String, FarmPrinterState>>((ref) {
  return FarmStoreNotifier(FarmStore());
});

// Broker 连接状态
final brokerStateProvider = StreamProvider<BrokerConnState>((ref) {
  return ref.read(brokerConnMgrProvider).stateStream;
});

// 派生: 打印机列表
final printerListProvider = Provider<List<FarmPrinterState>>((ref) {
  final state = ref.watch(farmStoreProvider);
  return state.values.toList()..sort((a, b) => a.sn.compareTo(b.sn));
});

// 派生: 按状态筛选
final printingPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isPrinting).toList();
});

final httpFallbackPrintersProvider = Provider<List<FarmPrinterState>>((ref) {
  return ref.watch(printerListProvider).where((p) => p.isHttp).toList();
});

// 派生: 统计
final farmStatsProvider = Provider<FarmStats>((ref) {
  final printers = ref.watch(printerListProvider);
  return FarmStats(
    total: printers.length,
    online: printers.where((p) => p.isOnline).length,
    printing: printers.where((p) => p.isPrinting).length,
    mqttCount: printers.where((p) => p.isMqtt).length,
    httpCount: printers.where((p) => p.isHttp).length,
  );
});
```

### 12.2 页面结构

```
lib/features/farm/
├── application/
│   └── providers/
│       ├── farm_store_provider.dart
│       ├── broker_state_provider.dart       # BrokerConnState
│       ├── discovery_provider.dart
│       ├── printer_list_provider.dart
│       ├── farm_stats_provider.dart
│       └── batch_operation_provider.dart
├── presentation/
│   ├── pages/
│   │   ├── farm_dashboard_page.dart
│   │   ├── printer_detail_page.dart
│   │   ├── discovery_wizard_page.dart
│   │   ├── broker_setup_page.dart           # ← 新增：Broker 连接配置
│   │   └── settings_page.dart
│   └── widgets/
│       ├── printer_card.dart
│       ├── printer_grid.dart
│       ├── batch_toolbar.dart
│       ├── broker_status_indicator.dart
│       ├── deployment_mode_banner.dart       # ← 新增：模式提示横幅
│       ├── connection_type_badge.dart
│       └── discovery_result_list.dart
└── data/
    ├── farm_store.dart
    ├── farm_printer_state.dart
    ├── staleable.dart
    ├── farm_snapshot.dart
    ├── broker_connection_manager.dart        # ← 新：替代 MqttBrokerManager
    ├── broker_health_monitor.dart            # ← 新
    ├── credential_store.dart                 # ← 新
    ├── printer_registry.dart                 # ← 新
    ├── farm_mqtt_router.dart
    ├── config_push_service.dart
    ├── batch_operator.dart
    ├── batch_result.dart
    ├── printer_discovery.dart
    ├── http_poller.dart
    ├── file_uploader.dart
    ├── farm_connection_monitor.dart
    ├── request_tracker.dart
    ├── request_queue.dart
    ├── printer_info.dart
    └── farm_hub.dart
```

---

## 13. 错误处理与降级策略

### 13.1 降级决策树

```
打印机入网时:
  ConfigPushService.push(printer)
    ├─ 成功 → 等待 MQTT 连接 → Source.mqtt
    └─ 失败
        → 标记为 Source.http
        → HttpPoller.addPrinter(printer)
        → 15s 后自动重试 ConfigPush (最多 3 次)
        → 仍失败 → 5min 间隔后台持续重试
        → 成功后 → 切换为 Source.mqtt → HttpPoller.removePrinter()
```

### 13.2 MQTT/HTTP 数据竞争保护

```
写入 FarmPrinterState 前检查 lastDataTimestamp:
  MQTT 消息带 eventtime (来自打印机硬件时钟)
  HTTP 轮询带 pollTime (App 本地时钟)
  
  if (新数据时间戳 <= lastDataTimestamp) → 丢弃（防止旧数据覆盖新数据）
```

---

## 14. 项目结构

```
lava-farm/
├── ARCHITECTURE.md
├── openspec/
│   ├── config.yaml
│   └── changes/lava-farm/
│       ├── proposal.md
│       ├── design.md          ← 本文档
│       └── tasks.md
├── deployment/                ← 新增
│   ├── docker-compose.yml
│   ├── mosquitto.conf.template
│   ├── acl.template
│   └── setup-pi.sh
├── lib/
│   ├── main.dart
│   └── features/farm/
│       ├── application/       # Riverpod Providers
│       ├── presentation/      # Pages + Widgets
│       └── data/              # FarmStore + Services
├── test/
│   ├── data/farm_store_test.dart
│   ├── data/batch_operator_test.dart
│   ├── data/broker_connection_manager_test.dart  # ← 新增
│   ├── data/discovery_test.dart
│   └── data/http_poller_test.dart
├── pubspec.yaml
└── README.md
```

---

## 15. 关键设计决策汇总

| 决策 | 选择 | 理由 |
|------|------|------|
| 通信协议 | MQTT 优先 + HTTP 降级 | 100 台规模下 MQTT 是唯一实时方案 |
| Broker 部署 | 独立部署 (双模式) | 打印任务持续数小时，App 生命周期不应影响打印机通信 |
| 安全 | 用户名密码 + ACL | 局域网不等于可信网络 |
| 状态聚合 | FarmStore (单入口 + 时间戳保护) | 复用 DeviceMetadataStore 模式，加时间戳解决数据竞争 |
| 命令分发 | Fan-Out + Semaphore(20/40) | 20 并发常规，40 并发急停 |
| 打印机发现 | mDNS + TCP 扫描 | 双保险 |
| Config Push | POST /server/config + restart | Moonraker 原生 API |
| HTTP 降级恢复 | 后台 5min 间隔持续重试 | 不应永久卡在降级 |
| 通知优化 | 100ms 批处理窗口 | 100 台 × 1s 推送 ≤ 10 次/秒 UI 重建 |
| 文件上传 | HTTP multipart (5并发) | 保守并发保证稳定性 |
| 状态管理 | Riverpod StateNotifier + select() | 与现有项目一致，精确重建 |
| SDK 关系 | 依赖 lava_device_sdk 复用适配器 | 不重复造轮子 |
