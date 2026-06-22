# Tasks: lava-farm 实现计划

## Phase 1: 项目骨架 + Broker 连接管理 (Day 1-2)

### T1.1 创建 Flutter 项目
- `flutter create lava_farm` 在 `/Users/jgfan/code/lava-farm/`
- 配置 `pubspec.yaml`：添加 `lava_device_sdk` 依赖、Riverpod、Hive、flutter_secure_storage
- 设置 OpenSpec CI 集成
- 验证: `flutter run -d macos` 显示空白窗口

### T1.2 CredentialStore 实现
- `CredentialStore.generatePrinterPassword(sn)` — 安全随机密码生成
- `CredentialStore.saveBrokerCredentials()` / `loadBrokerCredentials()` — flutter_secure_storage 持久化
- 验证: 单元测试（密码生成/存储/读取/清除）

### T1.3 BrokerConnectionManager 实现
- `BrokerConnectionManager.connect(host, port, username, password)` — 连接外部 Broker
- MQTT 客户端连接 (`MqttTransport.connect`)
- 自动重连（指数退避: 2s → 4s → 8s → ... → 30s max）
- `disconnect()` — 断开连接
- `stateStream` — `BrokerConnState` 流
- 验证: 单元测试中连接/断开外部 mosquitto，确认状态流正确

### T1.4 Broker 状态 Provider
- `brokerConnMgrProvider` (Provider)
- `brokerStateProvider` (StreamProvider → BrokerConnState)
- `BrokerStatusIndicator` widget (UI 指示器)
- 验证: UI 中实时显示 Broker 连接状态

---

## Phase 2: 打印机发现 (Day 2-3)

### T2.1 mDNS 发现
- `PrinterDiscovery.discoverMdns()` — 扫描 `_moonraker._tcp.local`
- 解析 IP、端口、hostname
- 验证: 模拟 mDNS 响应的单元测试

### T2.2 TCP 端口扫描
- `PrinterDiscovery.discoverTcp()` — 扫描子网 :7125
- 并发连接 (50 并发)，500ms 超时
- HTTP GET `/server/info` 获取 SN、型号
- 合并去重
- 验证: 模拟 HTTP 响应的单元测试

### T2.3 发现向导 UI
- `DiscoveryWizardPage` — 步骤式向导
  1. 选择发现方式 (mDNS / TCP扫描 / 手动输入 / CSV导入)
  2. 扫描进度 + 结果列表
  3. 勾选打印机 + 输入 Access Code
- `discoveryProvider` (StateNotifier → DiscoveryState)
- `DiscoveryResultList` widget
- 验证: 实际局域网中扫描到打印机

---

## Phase 3: 配置推送 + 入网 (Day 3-5)

### T3.1 ConfigPushService
- `POST /server/config` 写入 `[mqtt]` 配置段（含 `username` + `password`）
- `POST /server/restart` 重启 Moonraker
- 等待重启完成 (轮询 `/server/info` 直到响应，超时 20s)
- 等待 MQTT Last Will online 消息（超时 20s）
- 失败处理：重试 3 次（15s 间隔）→ 标记 HTTP 降级 → 后台 5min 间隔持续重试
- **⚠️ 入网前检查**：如果打印机正在打印中，警告用户并确认
- 验证: 单元测试，模拟 Moonraker HTTP 响应

### T3.2 入网流程编排
- `FarmHub.onboard(ip, port, accessCode)` 编排完整入网流程
  - Step 1: `POST /access/login` 验证 Access Code
  - Step 2: `GET /server/info` 获取 SN
  - Step 3: 检查打印机状态（打印中则警告）
  - Step 4: `CredentialStore.generatePrinterPassword(sn)` 生成凭据
  - Step 5: `ConfigPushService.push(ip, sn, brokerConfig, mqttCreds)`
  - Step 6: 等待 MQTT Last Will online 消息
  - Step 7: `FarmStore.onPrinterRegistered(info)`
  - Step 8: `PrinterRegistry.save()` 持久化
- 验证: 端到端入网流程测试

### T3.3 CSV 批量导入
- 解析 CSV 格式 (ip, sn, access_code, group)
- 逐台入网
- 进度显示 + 失败汇总
- 验证: CSV 解析 + 批量入网测试

---

## Phase 4: FarmStore + 状态聚合 (Day 5-7)

### T4.1 FarmPrinterState 模型
- 实现 `FarmPrinterState` 数据类
- `Staleable<T>` 新鲜度标记
- `FarmSnapshot` 快照模型 (环形缓冲 **50 条**)
- `FarmConnectionState` 枚举
- `Source` 枚举 (mqtt / http)
- **新增字段**: `lastDataTimestamp` (DateTime?) — 数据竞争保护
- **新增字段**: `_lastReportedDuration` — 累积指标增量计算
- 验证: 模型单元测试 (序列化/反序列化/staleness/时间戳保护)

### T4.2 FarmStore 核心
- `Map<String, FarmPrinterState>` 存储
- 写入方法:
  - `onMqttStatus(sn, status, {eventTime})` — 含时间戳保护
  - `onMqttNotification(sn, data)` — Last Will 处理
  - `onHttpPollResult(sn, data, {pollTime})` — 含时间戳保护（丢弃比 MQTT 旧的数据）
  - `onHttpPollFailed(sn)` — 仅记录，不改变状态
  - `forceOffline(sn, reason)` — 连接监控触发
  - `onPrinterRegistered(info)` / `onPrinterRemoved(sn)`
  - `onBatchResult(sn, result)`
- 中间件: 时间戳比较 · 字段合并 · staleness 标记 · 快照触发
- **批处理通知**: 100ms 窗口合并 `notifyListeners()`
- 读取方法: `getPrinter`, `allPrinters`, `getByGroup`
- 统计: `onlineCount`, `printingCount`, `mqttCount`, `httpCount`, `httpPrintingCount`
- 验证: FarmStore 单元测试（模拟 MQTT/HTTP 竞争写入、时间戳保护、批处理通知）

### T4.3 FarmStoreNotifier + Riverpod
- `FarmStoreNotifier extends StateNotifier<Map<String, FarmPrinterState>>`
- `farmStoreProvider` 注册
- 派生 providers: `printerListProvider`, `printingPrintersProvider`, `offlinePrintersProvider`, `httpFallbackPrintersProvider`, `farmStatsProvider`
- **精确重建**: 在 UI Widget 中使用 `ref.watch(provider.select(...))` 减少不必要的 rebuild
- 验证: Provider 单元测试 (状态更新 → UI 精确重建)

---

## Phase 5: MQTT 消息处理 (Day 7-9)

### T5.1 FarmMqttRouter
- 连接到外部 Broker（凭据认证）
- 通配符订阅: `+/status` (qos 1), `+/notification` (qos 1)
- 消息分发:
  - `+/status` → 提取 SN + eventtime → MoonrakerAdapter 解析 → FarmStore.onMqttStatus
  - `+/notification` → 提取 SN → 解析 → FarmStore.onMqttNotification
  - `{sn}/response` → RequestTracker 匹配 → 完成 Future
- 发布 topic: `{sn}/request`
- 动态订阅: `{sn}/response` (按需，命令完成后取消)
- **订阅生效延迟**: publish 前 delay 50ms 确保 Broker 端订阅已生效
- 验证: 消息路由单元测试

### T5.2 RequestTracker (命令响应匹配)
- JSON-RPC 请求 ID 生成
- `Map<id, Completer>` 管理等待中的请求
- 超时处理 (30s)
- 验证: RequestTracker 单元测试

### T5.3 MQTT PING 健康检测
- `FarmMqttRouter.ping()` — 发送 MQTT PINGREQ
- 期待 PINGRESP
- 验证: 模拟 PING 超时场景

---

## Phase 6: 批量操作引擎 (Day 9-11)

### T6.1 BatchOperator 核心
- `_fanOut()` 通用 Fan-Out 方法
- `Semaphore(maxConcurrency: 20)` 常规并发控制
- `Semaphore(maxConcurrency: 40)` 急停等优先级场景
- 每台打印机独立超时
- 结果聚合: `List<BatchResult>`
- 验证: 单元测试 (模拟 50 台打印机并发操作)

### T6.2 批量命令实现
- `batchGcode` — 批量 GCode 发送 (20 并发)
- `batchPause` / `batchCancel` / `batchResume` — 批量打印控制 (20 并发)
- `batchEmergencyStop` — 全部 M112 急停 (**40 并发**, 5s 超时)
- `batchSetNozzleTemp` — 批量设置喷嘴温度 (20 并发)
- **命令路由**: MQTT（主力）或 HTTP（降级 + probeSingle 即时确认）
- 验证: 集成测试 (模拟多台打印机 MQTT 响应)

### T6.3 批量操作 UI
- `BatchToolbar` — 筛选 + 操作按钮
- 确认对话框 + 实时进度
- 单打印机失败不阻塞整体
- 验证: UI 测试

---

## Phase 7: HTTP 降级通道 (Day 11-12)

### T7.1 HttpPoller 实现
- 请求队列 `RequestQueue(maxConcurrency: 20)`
- 自适应轮询间隔:
  - HTTP 打印中打印机 > 0 → 3s
  - HTTP 在线打印机 > 0 → 15s
  - 全部 HTTP 离线 → 30s
- HTTP GET `/printer/objects/query` + 结果解析
- 超时处理 (10s)
- 验证: 单元测试

### T7.2 HTTP 即时确认
- `HttpPoller.probeSingle(sn)` — 命令发送后立即触发一次即时轮询
- HTTP 命令确认延迟从 3s（等下一轮）降到 ~200ms
- 验证: 单元测试

### T7.3 后台 MQTT 升级
- `HttpPoller._startUpgradeRetries()` — 每 5 分钟尝试推送 MQTT 配置
- 成功 → `source = Source.mqtt` → `HttpPoller.removePrinter(sn)`
- 失败 → 继续 HTTP 降级，5 分钟后重试
- 验证: 降级→恢复流程测试

### T7.4 HTTP 命令通道
- `_sendHttpCommand()` — HTTP POST 发送命令
- Moonraker REST API 封装
- 验证: 单元测试 (模拟 HTTP 响应)

---

## Phase 8: 连接监控与故障恢复 (Day 12-13)

### T8.1 FarmConnectionMonitor
- 每 30s 检查所有在线打印机的 `lastStatusTime`
- 超过 60s → `FarmStore.forceOffline(sn, 'heartbeat_timeout')`
- Last Will 监听（1-3s 延迟检测断电）
- 验证: 单元测试 (模拟超时/恢复)

### T8.2 BrokerHealthMonitor
- 每 15s 调用 `FarmMqttRouter.ping()` 检测 Broker 连通性
- 连续 3 次失败 → 判定 Broker 假活 → 通知 UI → 触发重连
- 验证: 模拟 Broker 假活场景

### T8.3 Broker 连接恢复
- BrokerConnectionManager 自动重连（含指数退避）
- App 崩溃恢复：重启后自动连接 Broker + 从 Hive 恢复状态
- 验证: 故障注入测试

---

## Phase 9: 安全 + 部署 (Day 13-14)

### T9.1 Broker 配置生成器
- App 内生成 `mosquitto.conf`（生产模式）
- App 内生成 `passwd` 文件（mosquitto_passwd 格式）
- App 内生成 `acl` 文件（每打印机独立 user + topic 权限）
- 提供复制命令 / 下载文件
- 验证: 生成的配置能被 mosquitto 正确加载

### T9.2 部署指南 + 脚本
- Docker Compose 模板
- RPi 一键部署脚本 `setup-pi.sh`
- Broker 设置页面 UI (`BrokerSetupPage`)
  - 输入: 部署方式 + Broker IP
  - 输出: 配置文件和部署指令
- 验证: Docker 部署端到端测试

### T9.3 快速体验模式（内嵌 Broker）
- `MqttBrokerManager` 保留但标记为 `@deprecated`，仅用于快速体验
- 启动时检测：无外部 Broker 配置 → 提示选择模式
- 内嵌模式限制：
  - 橙色警告横幅："评估模式 — 关闭应用将断开所有打印机"
  - 阻止系统休眠
  - 关闭 App 前检测活跃打印并确认
- 验证: 内嵌模式启动/停止测试

### T9.4 部署模式迁移
- 从快速体验模式迁移到生产模式
- 保留已注册打印机列表
- 重新推送 MQTT 配置（含新 Broker 地址和凭据）
- 验证: 迁移流程端到端测试

---

## Phase 10: 文件分发 (Day 14-15)

### T10.1 FileUploader 实现
- HTTP multipart 上传 (`/server/files/upload`)
- 并发控制 (max 5 concurrent)
- 上传进度回调
- 文件大小限制 (200MB)
- 验证: 单元测试

### T10.2 批量上传 + 打印
- `batchUploadAndPrint` — 上传后自动启动打印
- 文件读取 → 内存缓存 → 并发上传
- 失败重试 (每台最多 2 次)
- 验证: 集成测试

---

## Phase 11: UI 主界面 (Day 15-17)

### T11.1 打印机卡片
- `PrinterCard` — 单打印机状态卡片
  - 显示: 名称, 状态图标, 喷嘴/热床温度, 打印进度
  - 颜色编码: 绿(在线) / 蓝(打印中) / 黄(暂停) / 红(错误) / 灰(离线)
  - MQTT/HTTP 连接类型 badge（HTTP 降级用橙色突出显示）
  - 选中状态 + 右键菜单
- **精确重建**: 使用 `select()` 只重建变化的卡片
- 验证: UI 快照测试

### T11.2 打印机网格
- `PrinterGrid` — 自适应网格布局 (响应式列数)
- 虚拟化滚动（100 个卡片性能优化）
- 批量选择 (勾选 / 全选 / 按群组选)
- 验证: UI 快照测试

### T11.3 Farm Dashboard
- 顶部统计栏: 总数 / 在线 / 打印中 / MQTT / HTTP
- **部署模式横幅**: 快速体验(橙色) / 生产(绿色)
- 群组筛选器
- 批量操作工具栏
- 验证: UI 快照测试

### T11.4 单打印机详情页
- 实时温度曲线图
- 打印进度条 + 预估剩余时间
- 快照历史时间线
- 手动控制面板 (移动轴 / 设置温度 / 发送 GCode)
- 验证: UI 测试

### T11.5 Broker 设置页
- Broker 连接配置表单
- 部署模式选择
- 配置生成器 + 部署指令
- 连接测试按钮
- 验证: UI 测试

---

## Phase 12: 测试与调优 (Day 17-18)

### T12.1 压力测试
- 模拟 100 台打印机 MQTT 连接
- 模拟 100 台打印机状态推送 (每秒 100 条)
- 批量操作 100 台打印机的响应时间
- 验证: 性能基准测试

### T12.2 故障恢复测试
- Broker 崩溃 → 打印机自动重连 → App 自动重连
- 打印机断网 → 标记离线 → 恢复 → 重新入网
- Config Push 失败 → HTTP 降级 → 后台重试 → MQTT 恢复
- MQTT/HTTP 数据竞争 → 时间戳保护验证
- 验证: 故障注入测试

### T12.3 内存与 CPU 分析
- FarmStore 100 台打印机内存占用 (目标 < 50MB)
- MQTT 消息处理 CPU 占用
- 批处理通知效果验证 (每秒 UI 重建次数)
- 验证: Dart DevTools 内存分析

---

## 依赖关系

```
Phase 1 (Broker连接+凭据) ──→ Phase 2 (发现) ──→ Phase 3 (入网)
                                                       │
                                              ┌────────┘
                                              ▼
                                        Phase 4 (FarmStore)
                                              │
                                    ┌─────────┼─────────┐
                                    ▼         ▼         ▼
                              Phase 5     Phase 7    Phase 8
                              (MQTT)      (HTTP降级) (连接监控)
                                    │         │         │
                                    └────┬────┘         │
                                         ▼              │
                                    Phase 6 (批量操作)   │
                                         │              │
                                         ▼              │
                                    Phase 10 (文件)     │
                                         │              │
                                         └──────┬───────┘
                                                ▼
                                          Phase 9 (安全+部署)
                                                │
                                                ▼
                                          Phase 11 (UI)
                                                │
                                                ▼
                                          Phase 12 (测试)
```

## 与旧版 tasks.md 的主要变更

| 旧 Phase | 新 Phase | 变更 |
|----------|----------|------|
| Phase 1: Broker 进程管理 | Phase 1: Broker 连接管理 + 凭据 | 不再管理子进程，改为连接管理 |
| — | Phase 1.2: CredentialStore | 新增：安全凭据存储 |
| — | Phase 1.4: BrokerStateProvider | 状态从进程状态变为连接状态 |
| Phase 3: Config Push | Phase 3: Config Push + 凭据下发 | MQTT 配置包含 username/password |
| Phase 4: FarmStore | Phase 4: FarmStore + 时间戳 + 批处理 | 新增时间戳保护和批处理通知 |
| — | Phase 5.3: MQTT PING 健康检测 | 新增：Broker 假活检测 |
| Phase 7: HTTP 降级 | Phase 7: HTTP 降级 + 即时确认 + 后台升级 | 新增 probeSingle + 5min 升级重试 |
| — | Phase 8.2: BrokerHealthMonitor | 新增 |
| — | Phase 9: 安全 + 部署 | 全新 Phase |
| — | Phase 9.3: 快速体验模式 | 保留内嵌 Broker 作为评估模式 |
| Phase 9: UI | Phase 11: UI | 新增 Broker 设置页 + 部署模式横幅 |
| Phase 10: 测试 | Phase 12: 测试 | 新增数据竞争/批处理/假活检测测试 |
