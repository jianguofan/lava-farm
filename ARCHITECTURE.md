# Lava Farm 架构文档

> 局域网 3D 打印机群控桌面端 — Flutter + Riverpod + MQTT
>
> 架构原则：Broker 独立于 App，App 是纯客户端。部署简单不等于架构简单。

---

## 目录

1. [项目概览](#1-项目概览)
2. [架构总图](#2-架构总图)
3. [分层设计](#3-分层设计)
4. [数据流](#4-数据流)
5. [组件详解](#5-组件详解)
6. [状态管理](#6-状态管理)
7. [通信协议](#7-通信协议)
8. [路由设计](#8-路由设计)
9. [目录清单](#9-目录清单)

---

## 1. 项目概览

**Lava Farm** 是一个基于 Flutter Desktop 的 3D 打印机群控系统，通过局域网管理 1-100 台 Snapmaker（Moonraker 固件）打印机。App 作为纯 MQTT 客户端连接至独立部署的 Mosquitto Broker，以 MQTT 为主动通道、HTTP 轮询为降级通道，实现实时监控、批量控制和文件分发。

| 属性 | 值 |
|------|-----|
| 框架 | Flutter 3.x (Desktop: Windows / macOS) |
| 语言 | Dart ≥3.2.0 |
| 状态管理 | Riverpod 2.x |
| 通信协议 | MQTT (Mosquitto) + HTTP (Moonraker REST API) |
| 安全存储 | flutter_secure_storage |
| 目标规模 | 1–100 台打印机 |

---

## 2. 架构总图

### 2.1 分层架构

```
┌──────────────────────────────────────────────────────────────────────┐
│                        PRESENTATION (UI)                             │
│   pages/  (7): Dashboard, Detail, BatchPrint, Discovery...           │
│   widgets/ (8): PrinterCard, PrinterGrid, StatsBar, CameraView...    │
│                                                                      │
│   依赖 → application/providers/ (Riverpod)                           │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
┌──────────────────────────────┴───────────────────────────────────────┐
│                       APPLICATION (装配 + 编排)                       │
│                                                                      │
│   providers/ (4): broker_state_provider, printer_list_provider,      │
│                   discovery_provider, credential_store_provider      │
│                                                                      │
│   services/ (2): FarmHub (群控入口), BatchPrintCoordinator (群控打印) │
│                                                                      │
│   依赖 → domain/ (接口) + data/ (实现)                                │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
┌──────────────────────────────┴───────────────────────────────────────┐
│                           DOMAIN (纯 Dart)                            │
│                                                                      │
│   services/ (1): PrinterStateMachine (状态转换纯逻辑)                 │
│   repositories/ (1): FarmRepository (仓储接口/抽象)                   │
│                                                                      │
│   零依赖：不依赖 Flutter、Riverpod、任何 IO                           │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
┌──────────────────────────────┴───────────────────────────────────────┐
│                            DATA (实现)                                │
│                                                                      │
│   核心:   FarmStore, FarmMqttRouter, FarmCommandGateway              │
│   MQTT:   MqttTransportImpl, MqttMessageProcessor (Isolate)          │
│   HTTP:   HttpPoller, FileUploader, ConfigPushService                │
│   本地:   CredentialStore, FarmLogger                                │
│   模型:   FarmPrinterState, PrinterInfo, Staleable<T>                │
│   连接:   BrokerConnectionManager, FarmConnectionMonitor             │
│   追踪:   UnifiedRequestTracker                                     │
│   部署:   DockerBrokerManager, BrokerConfigGenerator                 │
└──────────────────────────────────────────────────────────────────────┘
```

### 2.2 组件关系图

```
                         ┌──────────────────┐
                         │   Mosquitto       │
                         │   MQTT Broker     │
                         │   (独立部署)       │
                         └──────┬───────┬───┘
                                │       │
                   MQTT 订阅    │       │  MQTT 发布
                   (+/status,   │       │  (SN/request)
                    +/notif)    │       │
                                ▼       ▼
                   ┌─────────────────────────────┐
                   │    MqttTransportImpl         │
                   │    (mqtt_client 包装)         │
                   └────────┬────────────────────┘
                            │
                            │ MqttMessage Stream
                            ▼
                   ┌─────────────────────────────┐
                   │  MqttMessageProcessor        │
                   │  (后台 Isolate)               │
                   │  UTF-8 解码 + JSON 解析       │
                   │  50ms 批处理窗口              │
                   └────────┬────────────────────┘
                            │
                            │ ProcessedMessage 批次
                            ▼
        ┌───────────────────────────────────────────┐
        │          FarmMqttRouter                    │
        │                                           │
        │  ┌─────────────────────────────────────┐  │
        │  │  UnifiedRequestTracker               │  │
        │  │  requestId → SN → batchId 三层索引   │  │
        │  │  track()    ── 发送侧注册            │  │
        │  │  complete() ── 接收侧匹配            │  │
        │  └──────────┬──────────────────────────┘  │
        │             │                              │
        │  ┌──────────┴──────────────────────────┐  │
        │  │  FarmCommandGateway                  │  │
        │  │  sendToOne()  +  sendToMany()        │  │
        │  │  并发控制 (Semaphore 20/40)          │  │
        │  └─────────────────────────────────────┘  │
        │                                           │
        │  _handleStatus()       → FarmStore        │
        │  _handleNotification() → FarmStore        │
        │  _handleResponse()     → Tracker          │
        └──────────┬────────────────────────────────┘
                   │
                   │ onMqttStatus / onMqttNotification
                   ▼
        ┌───────────────────────────────────────────┐
        │            FarmStore                       │
        │                                           │
        │  Map<SN, FarmPrinterState>  _printers     │
        │  单入口写入 + 时间戳保护 + 值去重          │
        │  100ms 批处理窗口                          │
        │  dirtySns (精确脏标记)                     │
        │  onVersionChanged → Riverpod 通知          │
        └──────────┬────────────────────────────────┘
                   │
         ┌─────────┴──────────┐
         │                    │
         ▼                    ▼
  ┌─────────────┐   ┌────────────────────────┐
  │  HttpPoller  │   │  PrinterStateMachine    │
  │  (HTTP降级)  │   │  (状态转换纯逻辑)       │
  └──────┬───────┘   └────────────────────────┘
         │
         │ onHttpPollResult / onHttpPollFailed
         ▼
  (同样写入 FarmStore)
```

### 2.3 数据流全景

```
═══════════════════════════════════════════════════════════════════════
                          入站数据流
═══════════════════════════════════════════════════════════════════════

  MQTT +/status      ──→  Isolate 解码解析  ──→  Router._handleStatus
  MQTT +/notif       ──→  Isolate 解码解析  ──→  Router._handleNotification
  MQTT {SN}/response ──→  Isolate 解码解析  ──→  Tracker.complete()
  HTTP 轮询          ──→  HttpPoller         ──→  FarmStore.onHttpPollResult()

                              │
                              ▼
                         FarmStore
                 (单入口写入 + 批处理通知)
                              │
                       100ms 批处理窗口
                              │
                 ┌────────────┴────────────┐
                 ▼                         ▼
        onVersionChanged()          old listeners
        → farmStoreVersionProvider  (FarmConnectionMonitor)
           .state++
                 │
                 ▼
        Riverpod 依赖图触发重建
        printerListProvider → UI rebuild

═══════════════════════════════════════════════════════════════════════
                          出站数据流
═══════════════════════════════════════════════════════════════════════

  UI Action
      │
      ├── FarmCommandGateway.sendToOne(sn, method, params)
      │      │
      │      ├── Tracker.track(sn, requestId, method) → Future
      │      ├── Transport.publish(SN/request, JSON-RPC)
      │      │
      │      └── MQTT {SN}/response → Router._onMessage()
      │             └── Tracker.complete(sn, response)
      │                    └── Future.resolve() → CommandResult
      │
      └── FarmCommandGateway.sendToMany(sns, method, params)
             │
             └── Fan-out (Semaphore 20/40)
                  ├── 每台独立 track + publish + await
                  └── BatchHandle.progressStream / .results

  文件上传:
  UI → BatchPrintCoordinator
         ├── 1) FileUploader (HTTP multipart) → 打印机
         └── 2) FarmCommandGateway (MQTT start_local_print) → 打印机
```

---

## 3. 分层设计

### 3.1 Domain 层

> 纯 Dart，零依赖。不依赖 Flutter、Riverpod、任何 IO。

```
domain/
├── services/
│   └── printer_state_machine.dart    # 状态机纯函数
└── repositories/
    └── farm_repository.dart          # 仓储接口（抽象）
```

**PrinterStateMachine** — 从 FarmStore 提取的业务逻辑：

| 方法 | 职责 |
|------|------|
| `shouldAutoRegister()` | 判断是否应该自动注册新设备 |
| `detectTransitions()` | 检测打印状态转换并生成快照列表 |
| `isTimestampValid()` | MQTT 消息时间戳保护（乱序检测） |
| `createDefaultDisplayName()` | 从 SN 后 6 位生成默认显示名 |
| `createAutoDiscoveredInfo()` | 创建自动发现的 PrinterInfo |
| `isPrintingState()` | 判断打印状态是否为打印中 |

**FarmRepository** — 领域层抽象接口：

| 类别 | 方法 |
|------|------|
| 连接管理 | `connect()`, `disconnect()`, `isConnected`, `brokerStateStream` |
| 设备查询 | `getPrinter()`, `allPrinters` |
| 设备管理 | `registerPrinter()`, `removePrinter()` |
| 命令发送 | `sendCommand()`, `sendToMany()` |
| 发现入网 | `discover()`, `onboard()` |
| 生命周期 | `dispose()` |

### 3.2 Application 层

> 编排 + 装配。依赖 Domain 接口 + Data 实现。

```
application/
├── providers/
│   ├── broker_state_provider.dart       # 核心 Providers 装配
│   ├── printer_list_provider.dart       # 派生 Providers（列表/统计/筛选）
│   ├── discovery_provider.dart          # 发现流程 Provider
│   └── credential_store_provider.dart   # 凭据存储 Provider
└── services/
    ├── farm_hub.dart                    # 群控系统入口（生命周期 + 入网 + 发现）
    └── batch_print_coordinator.dart     # 群控打印协调器（上传 + 启动）
```

**Provider 层次图：**

```
farmStoreProvider (Provider<FarmStore>)
  └── onVersionChanged() → farmStoreVersionProvider (StateProvider<int>)

brokerConnMgrProvider (Provider<BrokerConnectionManager>)
  └── brokerStateProvider (StreamProvider<BrokerConnState>)

farmMqttRouterProvider (NotifierProvider<MqttRouterNotifier, FarmMqttRouter?>)
  ├── unifiedTrackerProvider (Provider<UnifiedRequestTracker?>)
  ├── farmCommandGatewayProvider (Provider<FarmCommandGateway?>)
  └── cameraServiceProvider (Provider<CameraService?>)

printerListProvider (Provider<List<FarmPrinterState>>)
  ├── printingPrintersProvider
  ├── offlinePrintersProvider
  ├── httpFallbackPrintersProvider
  ├── mqttOnlinePrintersProvider
  └── farmStatsProvider (Provider<FarmStats>)

discoveryProvider (StateNotifierProvider<DiscoveryNotifier, DiscoveryState>)
  └── selectedPrintersProvider

farmHubProvider (Provider<FarmHub>)
batchPrintCoordinatorProvider (Provider<BatchPrintCoordinator>)
```

### 3.3 Data 层

> 具体实现。17 个文件按职责分组：

| 分组 | 文件 | 职责 |
|------|------|------|
| **核心** | `farm_store.dart` | 多设备状态聚合，单入口写入 |
| | `farm_mqtt_router.dart` | MQTT 消息路由、订阅、分发 |
| | `farm_command_gateway.dart` | 统一命令网关 |
| **追踪** | `unified_request_tracker.dart` | 请求/响应追踪，三层索引 |
| | `request_tracker.dart` | 早期版本（遗留） |
| | `request_queue.dart` | 通用异步任务队列 |
| **MQTT** | `mqtt_transport_impl.dart` | MqttTransportAdapter 实现 |
| | `mqtt_message_processor.dart` | Isolate 消息处理器 |
| **HTTP** | `http_poller.dart` | HTTP 降级轮询 |
| | `file_uploader.dart` | HTTP 文件上传 |
| | `config_push_service.dart` | MQTT 配置推送 |
| **连接** | `broker_connection_manager.dart` | MQTT 连接管理 + 重连 |
| | `farm_connection_monitor.dart` | 连接监控 + Broker 健康监控 |
| **模型** | `farm_printer_state.dart` | 打印机状态模型 |
| | `printer_info.dart` | 注册信息 + 枚举 |
| **服务** | `camera_service.dart` | 摄像头 MQTT 控制 |
| | `batch_operator.dart` | 批量操作引擎 |
| | `printer_discovery.dart` | mDNS + TCP 扫描 |
| **本地** | `credential_store.dart` | 安全凭据存储 |
| | `farm_logger.dart` | JSONL 本地日志 |
| **部署** | `docker_broker_manager.dart` | Docker Broker 生命周期 |
| | `broker_config_generator.dart` | Mosquitto 配置文件生成 |
| | `broker_mode.dart` | Docker 状态枚举 |

---

## 4. 数据流

### 4.1 MQTT 状态消息 → UI 更新

```
MQTT Broker ──→ +/status (每台打印机约 1s 推送)
    │
    ▼
MqttTransportAdapter.messageStream
    │
    ▼
FarmMqttRouter._onMessage()
    │
    ├── 提取 SN (topic 前缀)
    ├── 诊断日志（首次 topic / 30s 统计）
    └── _processor.enqueue(topic, payload)
    │
    ▼
MqttMessageProcessor (后台 Isolate)
    │
    ├── UTF-8 解码
    ├── JSON 解析
    ├── Map 展平 (嵌套 → 扁平键)
    └── 50ms 批处理 → SendPort → 主 Isolate
    │
    ▼
FarmMqttRouter._onBatchProcessed()
    │
    ├── status → FarmStore.onMqttStatus(sn, expandedStatus, eventTime)
    │     ├── PrinterStateMachine.shouldAutoRegister()
    │     ├── PrinterStateMachine.isTimestampValid()
    │     ├── printer.updateTelemetry(data)
    │     ├── PrinterStateMachine.detectTransitions() → snapshots
    │     ├── printer.markFresh(Source.mqtt)
    │     └── _dirtySns.add(sn) + _notify()
    │
    ├── notification → FarmStore.onMqttNotification(sn, rawJson)
    │     └── Last Will 遗嘱: online/offline 处理
    │
    └── response → UnifiedRequestTracker.complete(sn, rawJson)
          └── resolve completer → 调用方拿到 CommandResult
    │
    ▼
FarmStore._notify()  (100ms 批处理窗口)
    │
    ├── version++ + onVersionChanged()
    │   └── farmStoreVersionProvider.state++
    │       └── Riverpod 依赖图 → UI rebuild
    │
    └── onHeartbeat(sn) → FarmConnectionMonitor
```

### 4.2 HTTP 降级 → UI 更新

```
Moonraker HTTP API (/printer/objects/query)
    │
    │ 自适应间隔: 打印中 3s / 空闲 15s / 离线 30s
    ▼
HttpPoller._pollSingle()
    │
    │ HTTP GET + JSON 解析 + Map 展平
    ▼
FarmStore.onHttpPollResult(sn, data, pollTime)
    │
    ├── PrinterStateMachine.isTimestampValid()
    ├── printer.updateTelemetry(data)
    ├── printer.markFresh(Source.http)
    └── _notify() → UI 更新
```

### 4.3 命令发送 → 结果返回

```
UI ──→ FarmCommandGateway.sendToOne(sn, method, params)
    │
    ├── requestId = Tracker.generateRequestId()
    ├── future = Tracker.track(sn, requestId, method, timeout=30s)
    ├── Transport.publish(SN/request, JSON-RPC payload)
    │
    └── [等待...]
         │
         │ MQTT {SN}/response 到达
         │   → Router._onMessage()
         │   → Tracker.complete(sn, response)
         │   → future.resolve(response)
         │
         └── CommandResult.fromResponse(sn, method, duration, response)
```

### 4.4 群控打印流程

```
BatchPrintPage._startPrint()
    │
    ▼
BatchPrintCoordinator.execute()
    │
    ├── 1) File(localFilePath).readAsBytes()
    │
    ├── 2) Per-printer pipeline (Semaphore: 5 并发上传)
    │     │
    │     ├── Phase 1: FileUploader.uploadBytesToPrinter()
    │     │     └── HTTP POST /server/files/upload (multipart)
    │     │     └── 校验 + 重试 (最多 2 次)
    │     │
    │     └── Phase 2: FarmCommandGateway.sendToOne()
    │           └── MQTT server.files.start_local_print
    │
    ├── 3) Stream 实时上报
    │     ├── printerUpdateStream → 每台打印机状态
    │     └── progressStream → 总体进度
    │
    └── 4) 失败记录 → retryFailed() 重试
```

---

## 5. 组件详解

### 5.1 FarmStore — 唯一状态存储

```
┌─────────────────────────────────────────────┐
│               FarmStore                      │
│                                             │
│  _printers: Map<SN, FarmPrinterState>       │
│  _dirtySns: Set<String>    (脏标记)          │
│  version: int              (单调递增)         │
│  _batchTimer: Timer        (100ms 窗口)      │
│                                             │
│  写入方法 (所有数据源唯一入口):                │
│  ├── onMqttStatus(sn, data, eventTime)       │
│  ├── onMqttNotification(sn, data)            │
│  ├── onHttpPollResult(sn, data, pollTime)    │
│  ├── onHttpPollFailed(sn)                    │
│  ├── forceOffline(sn, reason)                │
│  ├── onPrinterRegistered(info)               │
│  ├── onPrinterRemoved(sn)                    │
│  ├── onBatchResult(sn, result)               │
│  └── updatePrinter(sn, updateFn)             │
│                                             │
│  读取方法:                                    │
│  ├── getPrinter(sn) → FarmPrinterState?      │
│  ├── allPrinters, mqttPrinters              │
│  ├── onlineCount, printingCount             │
│  └── exportToRegistry()                      │
│                                             │
│  通知机制:                                    │
│  ├── _notify() → 100ms 批处理                │
│  ├── onVersionChanged() → Riverpod           │
│  └── onHeartbeat(sn) → FarmConnectionMonitor │
└─────────────────────────────────────────────┘
```

### 5.2 FarmMqttRouter — MQTT 消息路由器

```
生命周期 (MqttRouterNotifier):
  brokerState.connected  → 创建 Router → start() + startProbing()
  brokerState.disconnected → stop() + 销毁 Router

启动时:
  1. 订阅 +/status (QoS 1)  — 覆盖所有设备的通配符
  2. 订阅 +/notification (QoS 1)
  3. 对已注册设备发送 printer.objects.subscribe (激活推送)
  4. 启动定期探活 (每 10min)
  5. 启动 IP 解析定时器 (每 30s)

运行时:
  _onMessage()
    ├── response topic → 立即 flush isolate (低延迟)
    └── status/notif   → enqueue isolate

  _onBatchProcessed()
    ├── status       → FarmStore.onMqttStatus()
    │   ├── 新设备 → 自动 _subscribeDeviceObjects()
    │   └── 无有效IP → 后台 _resolveIpInBackground()
    ├── notification → FarmStore.onMqttNotification()
    └── response     → Tracker.complete()
```

### 5.3 FarmCommandGateway — 命令网关

```
sendToOne(sn, method, params, timeout=30s)
  → requestId = Tracker.generateRequestId()
  → future = Tracker.track(sn, requestId, method, timeout)
  → Transport.subscribe(SN/response)  (首次自动订阅)
  → Transport.publish(SN/request, JSON-RPC payload)
  → await future → CommandResult

sendToMany(sns, method, params)
  → batchId = Tracker.registerBatch()
  → Fan-out: 每台独立 sendToOne()
  → Semaphore: 常规 20 并发 / 急停 40 并发
  → BatchHandle
      ├── progressStream → UI 实时进度
      └── await results  → List<CommandResult>
```

### 5.4 UnifiedRequestTracker — 请求追踪器

```
三层索引:
  ┌─────────────┬──────────────────────────┐
  │ requestId   │ _TrackedRequest           │  O(1) 响应匹配
  │ SN          │ Set<requestId>            │  离线批量取消
  │ batchId     │ _BatchContext             │  群控进度
  └─────────────┴──────────────────────────┘

请求生命周期:
  track()     → Timer(30s timeout) + Completer + 注册三层索引
  complete()  → cancel timer + resolve completer + 清理索引 + 更新批次进度
  timeout()   → resolve(null) + 标记 failed

批次进度:
  _BatchContext
    ├── completed / failed / total
    └── StreamController.broadcast()
        └── 每次 complete/fail → notifyProgress()
        └── isDone → 延迟清理上下文
```

### 5.5 FarmPrinterState — 打印机状态模型

```
FarmPrinterState
├── 身份信息
│   ├── sn, displayName, ip, port, group
│   └── model, firmwareVersion
│
├── Moonraker 元数据
│   ├── hostname, softwareVersion, cpuInfo
│   └── klippyState, moonrakerVersion, apiVersionString
│
├── 通信模式
│   ├── source: Source (MQTT / HTTP)
│   └── connectionState: FarmConnectionState
│
├── 实时遥测 (Staleable<T> — 断连自动标记过期)
│   ├── 挤出机: List<ExtruderState> (index, temperature, target)
│   ├── 热床:   bedTemp, bedTarget, bedPower
│   ├── 打印:   printState, progress, currentFile, layerNum, totalLayers
│   ├── 工具头: toolheadPosition, homedAxes, maxAccel, maxVelocity
│   ├── 风扇:   fanSpeed, fanRpm
│   ├── 净化器: purifierMode, purifierPowerDetValue
│   └── 其他:   printDuration, fileSize, printingTime, moveSpeed
│
├── 数据保护
│   ├── lastDataTimestamp (时间戳，防止 MQTT/HTTP 竞争)
│   └── rawStateSnapshot (最近一次完整状态，用于值去重)
│
├── 快照历史: List<FarmSnapshot> (环形缓冲 50 条)
└── 原始消息: List<Map> (环形缓冲 200 条)
```

---

## 6. 状态管理

### 6.1 通知机制

```
                     ┌──────────────────────┐
                     │     FarmStore         │
                     │  (唯一数据源)          │
                     │  version: int         │
                     └──────────┬───────────┘
                                │
                     写入 → _notify() (100ms batch)
                                │
                     ┌──────────┴───────────┐
                     │                      │
               onVersionChanged    _listeners.forEach()
                     │                      │
                     ▼                      ▼
           farmStoreVersionProvider   FarmConnectionMonitor
             .state++                    (心跳记录)
                     │
                     ▼
           Riverpod 依赖图重建
                     │
          ┌──────────┼──────────┐
          ▼          ▼          ▼
    printerList  farmStats   printerBySn
    Provider     Provider     (via farmStore)
          │          │          │
          ▼          ▼          ▼
       PrinterGrid  StatsBar  PrinterCard
```

### 6.2 性能优化

| 优化 | 机制 | 效果 |
|------|------|------|
| **批处理通知** | 100ms Timer 窗口 | 100台×1次/秒 → ≤10次/秒 UI重建 |
| **值去重** | rawStateSnapshot 逐字段比较 | 设备重复推送不变值时跳过通知 |
| **脏标记** | _dirtySns: Set<String> | 精确追踪变更范围 |
| **时间戳保护** | eventTime.isAfter(lastDataTimestamp) | 丢弃乱序到达的旧消息 |
| **Isolate 处理** | MQTT JSON 解析在后台线程 | 不阻塞 UI 线程 |
| **自适应轮询** | HttpPoller 按打印状态调间隔 | 打印中3s / 空闲15s / 离线30s |
| **并发控制** | Semaphore: 命令20 / 急停40 / 上传5 | 避免网络拥塞 |
| **Riverpod select** | printerCard 只读取单台打印机 | 精确重建 |

---

## 7. 通信协议

### 7.1 MQTT Topic 设计

| Topic | 方向 | QoS | 用途 |
|-------|------|-----|------|
| `+/status` | Printer → App | 1 | 状态推送（通配符订阅） |
| `+/notification` | Printer → App | 1 | 通知消息（Last Will 遗嘱） |
| `{SN}/response` | Printer → App | 1 | JSON-RPC 响应 |
| `{SN}/request` | App → Printer | 1 | JSON-RPC 请求 |

### 7.2 JSON-RPC 格式

```jsonc
// 请求 (App → Printer)
{
  "jsonrpc": "2.0",
  "method": "printer.print.pause",
  "params": {},
  "id": 1234567890
}

// 响应 (Printer → App)
{
  "jsonrpc": "2.0",
  "result": { "status": "ok" },
  "id": 1234567890
}
```

### 7.3 常用 Moonraker 方法

| 方法 | 用途 |
|------|------|
| `printer.objects.subscribe` | 激活对象状态推送 |
| `printer.objects.query` | 一次拉取全量状态 |
| `printer.print.pause` | 暂停打印 |
| `printer.print.resume` | 恢复打印 |
| `printer.print.cancel` | 取消打印 |
| `printer.emergency_stop` | 紧急停止 |
| `server.files.start_local_print` | 启动本地打印 |
| `machine.system_info` | 获取网络信息（含 IP） |
| `server.info` | Moonraker 版本信息 |
| `printer.info` | 打印机固件信息 |
| `camera.start_monitor` | 开启摄像头流 |
| `camera.stop_monitor` | 停止摄像头流 |

### 7.4 HTTP API（Moonraker REST）

| 端点 | 方法 | 用途 |
|------|------|------|
| `/server/files/upload` | POST | 上传 3MF/GCode 文件 |
| `/printer/objects/query` | GET | 轮询遥测状态 |
| `/access/login` | POST | 登录验证 |
| `/server/info` | GET | Moonraker 版本信息 |
| `/machine/update/mqtt` | POST | 推送 MQTT 配置 |

---

## 8. 路由设计

| 路由 | 页面 | 参数 | 导航方式 |
|------|------|------|----------|
| `'/'` | `FarmDashboardPage` | — | 命名路由 |
| `'/discovery'` | `DiscoveryWizardPage` | — | 命名路由 |
| `'/broker-setup'` | `BrokerSetupPage` | — | 命名路由 (fullscreenDialog) |
| `'/settings'` | `SettingsPage` | — | 命名路由 |
| `'/batch-print'` | `BatchPrintPage` | `Set<String> initialSns` | 命名路由 |
| `'/logs'` | `LogViewerPage` | — | 命名路由 |
| — | `PrinterDetailPage` | `String sn` | Navigator.push |

---

## 9. 目录清单

```
lib/
└── main.dart                                    # 入口: ProviderScope + MaterialApp + 路由

features/farm/
│
├── domain/                                      # 领域层 (纯 Dart, 零依赖)
│   ├── services/
│   │   └── printer_state_machine.dart           # 状态机纯函数 (6 个静态方法)
│   └── repositories/
│       └── farm_repository.dart                 # 仓储接口 (13 个抽象方法)
│
├── application/                                 # 应用层 (编排 + 装配)
│   ├── providers/
│   │   ├── broker_state_provider.dart           # 15 个核心 Provider
│   │   ├── printer_list_provider.dart           # 7 个派生 Provider
│   │   ├── discovery_provider.dart              # 发现流程 StateNotifier
│   │   └── credential_store_provider.dart       # 凭据存储单例
│   └── services/
│       ├── farm_hub.dart                        # 群控入口 (生命周期/入网/发现)
│       └── batch_print_coordinator.dart         # 群控打印 (上传+启动 pipeline)
│
├── data/                                        # 数据层 (具体实现, 17 文件)
│   ├── farm_store.dart                          # 核心状态聚合 (单入口写入)
│   ├── farm_mqtt_router.dart                    # MQTT 消息路由器
│   ├── farm_command_gateway.dart                # 统一命令网关
│   ├── unified_request_tracker.dart             # 请求/响应追踪 (三层索引)
│   ├── broker_connection_manager.dart           # Broker 连接管理 (重连/健康检测)
│   ├── mqtt_transport_impl.dart                 # MQTT 传输实现
│   ├── mqtt_message_processor.dart              # Isolate 消息处理
│   ├── farm_connection_monitor.dart             # 连接监控 + Broker 健康
│   ├── farm_printer_state.dart                  # 打印机状态模型 (Staleable<T>)
│   ├── printer_info.dart                        # 注册信息 + 枚举
│   ├── http_poller.dart                         # HTTP 降级轮询
│   ├── file_uploader.dart                       # HTTP 文件上传
│   ├── config_push_service.dart                 # MQTT 配置推送
│   ├── camera_service.dart                      # 摄像头 MQTT 控制
│   ├── credential_store.dart                    # 安全凭据存储
│   ├── printer_discovery.dart                   # 打印机发现 (mDNS+TCP)
│   ├── batch_operator.dart                      # 批量操作引擎
│   ├── request_queue.dart                       # 异步任务队列
│   ├── request_tracker.dart                     # 早期版请求追踪 (遗留)
│   ├── farm_logger.dart                         # JSONL 本地日志
│   ├── broker_config_generator.dart             # Mosquitto 配置生成
│   ├── docker_broker_manager.dart               # Docker Broker 生命周期
│   └── broker_mode.dart                         # Docker 状态枚举
│
└── presentation/                                # 展示层 (UI, 15 文件)
    ├── pages/
    │   ├── farm_dashboard_page.dart             # 主仪表盘
    │   ├── printer_detail_page.dart             # 单打印机详情
    │   ├── batch_print_page.dart                # 群控打印
    │   ├── broker_setup_page.dart               # Broker 连接设置
    │   ├── discovery_wizard_page.dart           # 发现向导 (3 步)
    │   ├── settings_page.dart                   # 应用设置
    │   └── log_viewer_page.dart                 # 日志查看器
    └── widgets/
        ├── printer_card.dart                    # 打印机状态卡片
        ├── printer_grid.dart                    # 自适应网格布局
        ├── batch_toolbar.dart                   # 批量操作工具栏
        ├── stats_bar.dart                       # 统计栏
        ├── broker_status_indicator.dart         # Broker 状态指示器
        ├── deployment_mode_banner.dart          # 状态横幅
        ├── discovery_result_list.dart           # 发现结果列表
        ├── print_section.dart                   # 上传并打印组件
        ├── camera_view.dart                     # 摄像头实时画面
        └── upload_progress_widget.dart          # 上传进度面板

部署:
deployment/
├── docker-compose.yml                          # Mosquitto Broker 生产部署
└── mosquitto/config/                           # Broker 配置目录
```

---

## 附录 A：设计原则

| # | 原则 | 实现 |
|---|------|------|
| 1 | **单一数据源** | FarmStore 是所有打印机状态的唯一写入入口 |
| 2 | **单入口写入** | 所有数据源只能通过 FarmStore 的 write 方法写入 |
| 3 | **时间戳保护** | eventTime 比较，丢弃乱序到达的旧消息 |
| 4 | **批处理通知** | 100ms Timer 窗口合并高频更新 |
| 5 | **Isolate 隔离** | JSON 解析在后台线程，不阻塞 UI |
| 6 | **自适应降级** | MQTT 不可用时自动切换 HTTP 轮询 |
| 7 | **领域逻辑分离** | 业务规则在 domain/services/ 中，纯函数可测试 |
| 8 | **依赖倒置** | FarmHub 依赖 FarmRepository 接口而非具体类 |

## 附录 B：性能关键路径

```
100 台打印机 × 1 次状态推送/秒 = 100 MQTT 消息/秒
    │
    └──→ Isolate 批处理 (50ms) → 每批约 5 条
         │
         └──→ FarmStore 写入 (时间戳保护 + 值去重)
              │
              └──→ 100ms 批处理通知 → ≤10 次 Riverpod 通知/秒
                   │
                   └──→ 100 张 PrinterCard 更新
                        (Flutter 增量布局, 实际渲染 < 16ms)
```

## 附录 C：故障处理矩阵

| 故障场景 | 检测方式 | 检测延迟 | 处理策略 |
|----------|---------|---------|---------|
| 打印机断电 | Last Will offline | 1–3s | FarmStore.forceOffline() |
| 打印机网络断连 | Last Will offline | 1–3s | FarmStore.forceOffline() |
| 打印机假在线 | Heartbeat 超时 | 60s | FarmConnectionMonitor → forceOffline |
| Broker 崩溃 | PING 连续失败 | 15–45s | BrokerHealthMonitor → 触发重连 |
| 打印机 MQTT 不通 | HTTP 降级 | 即时 | HttpPoller 接管轮询 |
| 命令超时 | Tracker 定时器 | 30s (可配) | 返回 CommandResult(timeout) |
