# Proposal: lava-farm — 局域网 3D 打印机群控系统

## Summary

基于独立 MQTT Broker + Moonraker 协议，为 Snapmaker 打印机构建 Flutter 桌面端群控应用（lava-farm）。支持最多 100 台打印机在同一局域网内的实时监控、批量控制、文件分发。采用 MQTT 优先 + HTTP 降级的双模通信架构。Broker 独立部署（7×24 运行），桌面 App 作为纯 MQTT 客户端（可随时开关）。同时提供内嵌 Broker 模式用于快速评估。

本 change 作为底层通信与群控底座。产品级能力按版本计划拆分到以下 OpenSpec change：

- `product-definition`：产品/模型定义与产品中心。
- `control-panel`：全屏控制面板与批量控制抽屉。
- `preprint-workflow`：预打印四步流程与投产结果。
- `alert-pinning`：异常置顶提示。
- `printer-detail-control`：单设备详情与控制。
- `desktop-shell`：桌面壳层、Broker 配置、安装部署。

## Motivation

现有 `lava_device_sdk` + `flutter_zero_copy` 架构面向**单设备连接**设计：`DeviceSessionImpl` 同时只管理一个活跃设备，MQTT 连接是一对一的。对于拥有数十台打印机的农场场景，需要：

- **多设备同时在线**：所有打印机实时推送状态，而非逐个切换
- **批量操作**：一键暂停所有打印机、批量上传 GCode、群组急停
- **实时性**：MQTT 通配符订阅实现 100 台打印机 1 秒内状态同步
- **零配置降级**：对无法远程改配置的打印机，自动降级为 HTTP 轮询

参考了 FDM Monster（并行 Fan-Out + 协议适配器工厂）和 OctoFarm（SSE 聚合推送 + 遍历式群控），结合 Snapmaker Moonraker 的完整 MQTT 组件能力。

## What It Does

```
┌──────────────────────────┐     ┌─────────────────────────────────────┐
│  Mosquitto Broker        │     │  lava-farm (Flutter Desktop)        │
│  独立部署，固定 IP       │     │                                     │
│  7×24 运行 :1883         │◄═══ │  ┌──────────────┐ ┌──────────────┐ │
│  认证 + ACL              │ MQTT│  │ 打印机发现    │ │ 批量操作引擎  │ │
└──────────────────────────┘     │  │ mDNS+端口扫描 │ │ Fan-Out+限流 │ │
                                 │  └──────┬───────┘ └──────┬───────┘ │
                                 │  ┌──────┴─────────────────┴───────┐ │
                                 │  │ FarmStore (多设备状态聚合)       │ │
                                 │  │ Map<sn,PrinterState>+时间戳保护  │ │
                                 │  └────────────────────────────────┘ │
                                 │                                     │
                                 │  MQTT (主力): 通配符 +/status       │
                                 │  HTTP (降级): 轮询 + 后台升级       │
                                 └─────────────────────────────────────┘
```

## Public API (核心概念)

| 概念 | 职责 |
|------|------|
| `FarmHub` | 群控入口：连接 Broker → 发现打印机 → 推送配置 → 建立群控会话 |
| `FarmStore` | 多设备状态聚合：MQTT 通配符消息 → 按 SN 分拣 → 时间戳保护 → Riverpod |
| `BrokerConnectionManager` | 外部 Broker 连接管理（连接/断开/自动重连/健康检测） |
| `CredentialStore` | 凭据安全存储 + 打印机密码生成（flutter_secure_storage） |
| `ConfigPushService` | 通过 Moonraker HTTP API 远程写入 [mqtt] 配置（含凭据） + 重启生效 + 后台升级重试 |
| `BatchOperator` | 批量命令 Fan-Out：优先级并发控制 + 超时 + 结果聚合 |
| `PrinterDiscovery` | mDNS (_moonraker._tcp) + HTTP 端口扫描 (7125) 双重发现 |
| `HttpPoller` | HTTP 降级通道：请求队列 + 自适应间隔 + probeSingle 即时确认 + 后台 MQTT 升级 |
| `BrokerHealthMonitor` | Broker 假活检测（MQTT PING） + 连续失败告警 |
| `PrinterCard` | UI 组件：单台打印机状态卡片（可嵌入网格/列表，精确重建） |

## Non-goals

- 不处理 Bambu Lab / OctoPrint / PrusaLink 打印机（仅 Moonraker）
- 不处理云端远程访问（纯局域网）
- 不处理摄像头视频流
- 不处理耗材管理 / 打印历史统计
- 不处理用户权限系统（单用户桌面应用）
- 不处理 GCode 切片（由外部切片软件完成）
- 不内置 7×24 告警通知（Broker 独立运行为此类扩展提供基础）

## Target Platforms

| 平台 | 方式 |
|------|------|
| macOS Desktop | Flutter macOS + 连接外部 Broker（或内嵌 Mosquitto 评估模式） |
| Windows Desktop | Flutter Windows + 连接外部 Broker（或内嵌 Mosquitto 评估模式） |
| Linux Desktop | Flutter Linux + 连接外部 Broker（或内嵌 Mosquitto 评估模式） |

**Broker 部署平台**（独立于 App）：
| 平台 | 方式 |
|------|------|
| Docker (通用) | `docker compose up -d` 一键部署 |
| Raspberry Pi | 一键安装脚本 |
| Linux 服务器 | `apt install mosquitto` + App 生成配置 |
| NAS (群晖/QNAP) | Docker 部署 |

## Success Criteria

- 100 台打印机通过 MQTT 实时状态更新延迟 < 1s
- 批量暂停 50 台打印机从点击到全部响应 < 3s
- HTTP 降级模式下单台打印机命令确认延迟 < 500ms（probeSingle）
- Broker 崩溃后打印机自动重连（Moonraker 端） + App 自动重连（指数退避）
- App 崩溃/重启后 2s 内恢复所有打印机状态
- 单个 GCode 文件批量上传到 10 台打印机 < 30s
- Broker 部署时间 < 5 分钟（Docker 方案）
