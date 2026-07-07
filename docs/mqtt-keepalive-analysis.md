# MQTT Keepalive 机制与批量打印断连分析

## 故障现象

群控批量打印时，文件 HTTP 上传完成（耗时 ~65s）后，通过 MQTT 发送 `server.files.start_local_print` 命令时报错：

```
mqtt-client::ConnectionException: The connection must be in the Connected state
in order to perform this operation.
```

同时 Broker 发布了 Last Will 遗嘱消息：

```
lava_app/notification {"server":"offline"}
```

## 根因分析

### Lava Farm 的 MQTT 拓扑

```
┌──────────┐              ┌──────────┐
│ Printer1 │──MQTT──────→ │          │
│ (H7H8)  │←──MQTT────── │ Mosquitto│
└──────────┘              │  Broker  │
                          │          │
┌──────────┐              │          │      ┌──────────┐
│ Printer2 │──MQTT──────→ │          │←MQTT→│ Lava App │
│ (Z7AM)  │←──MQTT────── │          │      │ (客户端) │
└──────────┘              └──────────┘      └──────────┘
                                          
┌──────────┐              HTTP Upload
│ Printer3 │←═══════════════════════════════ Lava App
│ (BU7J)  │              (25MB, ~65s)
└──────────┘
```

关键：HTTP 上传是 App → Printer 直连，不经过 Broker；MQTT 控制命令是 App → Broker → Printer。

### MQTT Keepalive 协议机制

MQTT keepalive 是**客户端单向承诺**：

- 客户端在 CONNECT 包中声明 `keepAlive` 秒数
- 承诺最多每隔 N 秒至少发一个 MQTT 控制包（PINGREQ / PUBLISH / SUBSCRIBE 等）
- Broker 在 1.5 × keepAlive 秒内没收到任何包 → 判定客户端死亡 → 断开 TCP + 发布 Last Will

```
正常情况（有业务消息）:
  客户端 ──PUBLISH──→ Broker     ← 业务消息算 keepalive，重置计时器

空闲情况（无业务消息）:
  客户端 ──PINGREQ──→ Broker     ← keepalive 计时器到期，发心跳
  客户端 ←──PINGRESP── Broker    ← Broker 应答

只有 客户端→Broker 方向 的包才重置计时器
收消息（Broker→客户端）不重置！
```

### mqtt_client 库的实现

```dart
// 简化的内部逻辑
Timer _keepAliveTimer;

void _onMessageSent() {
  _lastSentTime = DateTime.now();
  _keepAliveTimer.cancel();
  _keepAliveTimer = Timer(keepAlivePeriod, _sendPingReq);  // 重置倒计时
}

void _sendPingReq() {
  _socket.add([0xC0, 0x00]);  // MQTT PINGREQ 固定两字节
  _pingTimer = Timer(disconnectOnNoResponsePeriod, _onPingTimeout);
}

void _onPingResp() {
  _pingTimer.cancel();
  _keepAliveTimer = Timer(keepAlivePeriod, _sendPingReq);  // 继续下一轮
}

void _onPingTimeout() {
  // disconnectOnNoResponsePeriod 秒内没收 PINGRESP → 主动断开
  _disconnect('No PINGRESP received');
}
```

### 断连时序

```
T=0      FarmMqttRouter 发了 probe query（printer.objects.query）
         重置 mqtt_client 的 keepalive 计时器

T=0~65   HTTP 上传中（25MB, 385KB/s）
         Router 的探活查询有间隔（不是持续不断的）
         上传高峰期，网络/CPU 拥塞

T≈55     Router 又发了 probe query（重置计时器）

T≈85     keepalive 计时器检查：已经 30s  没发包
         → 发送 PINGREQ
         → 启动 disconnectOnNoResponsePeriod 计时器（10s）

         此时：
         - 3 台打印机持续推 status 消息 → 大量入站 MQTT 流量
         - HTTP 上传仍在跑 → 大量 TCP 出站流量
         - 网络/CPU 拥塞

T≈95     PINGRESP 仍没收到！（正常 < 50ms，但高峰期延迟增大）
         → mqtt_client 主动断开 TCP 连接  ← 根因

T=65     此时上传完成
         → 尝试 publish MQTT 命令
         → 连接已死 → ConnectionException
```

**核心原因：`disconnectOnNoResponsePeriod = 10` 太短**。正常局域网 PINGRESP < 50ms，但上传高峰期延迟可能 >10s。

### 为什么收消息不能重置 Keepalive

这是 MQTT 协议的设计决策：

```
Broker ──PUBLISH──→ 客户端  (持续推送 status)
客户端：没有任何 MQTT 层回应

Broker 视角：
  TCP ACK 证明 TCP 连接还活着？
  → 但 MQTT 协议不信任 TCP ACK
  → 应用层可能已经死了但 TCP 还在（半开连接）
  → 必须有 MQTT 层的包从客户端发出才算数
```

## 修复方案

### 参数调整（已实施）

| 参数 | 修复前 | 修复后 | 说明 |
|------|--------|--------|------|
| `keepAlivePeriod` | 60s | 120s | Broker 容忍 1.5×120=180s，远超上传时长 |
| `disconnectOnNoResponsePeriod` | 10s | 40s | 给 PINGRESP 充足到达时间 |

文件：`lib/features/farm/data/mqtt_transport_impl.dart`

### 为什么没有做"publish 前检查重连"

当前 `BrokerConnectionManager` 已有自动重连机制（指数退避），如果连接断开，`onDisconnected` 回调会触发重连。问题是重连需要时间（先等退避间隔），而 `BatchPrintCoordinator` 的 `sendToOne` 等待超时是独立的。

publish 前做连接检查的方案可以考虑但不做：
- 会增加 publish 路径的复杂度
- 重连期间 HTTP 上传已完成，文件已在打印机上，可以后续重试

## 相关文件

- `lib/features/farm/data/mqtt_transport_impl.dart` — MQTT 连接配置
- `lib/features/farm/data/broker_connection_manager.dart` — 连接管理 + 自动重连
- `lib/features/farm/application/services/batch_print_coordinator.dart` — 批量打印协调器
- `lib/features/farm/data/farm_command_gateway.dart` — MQTT 命令网关

## 参考资料

- [MQTT v3.1.1 规范 — Keep Alive](http://docs.oasis-open.org/mqtt/mqtt/v3.1.1/os/mqtt-v3.1.1-os.html#_Toc398718081)
- [Mosquitto — max_keepalive 配置](https://mosquitto.org/man/mosquitto-conf-5.html)
