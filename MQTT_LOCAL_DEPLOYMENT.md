# 本地部署 MQTT 服务器（Mosquitto Broker）完整指南

> 基于 [ARCHITECTURE.md](./ARCHITECTURE.md) 整理

---

## 1. 架构概览

lava-farm 支持两种连接模式，共享同一套 Topic 结构：

```
═══════════ LAN 模式（单机直连）═══════════    ═══════════ 群控模式（中央 Broker）═══════════

App ──1884 匿名──► 打印机                      打印机 Mosquitto ──bridge──► 中央 Broker
     ↓ 握手拿证书     ↑                              ↑ 出厂预装             ↑ Docker 7×24
     8883 TLS+cert──┘                               │ 自动连接              │
                                                    │                       │
 moonraker ──127.0.0.1:1883──► 本地 mosquitto      hostname 发现         群控 App ──► 中央 Broker
 （无认证，不动）                                  lava-central.local       lava_app 身份
                                                                            订阅 +/status
```

**LAN 模式**：App 在局域网内直连打印机，证书认证。适合现场调试、单机操作。

**群控模式**：打印机通过 Mosquitto Bridge 连接中央 Broker，群控 App 连中央 Broker 就能看到所有打印机。Bridge 故障时 App 通过 LAN 远程修复。

**核心原则**：两种模式独立运行、互不干扰。LAN 模式完全不动，moonraker 一行代码不改。

**为什么选 Mosquitto Bridge 而不是改 moonraker？**
- moonraker 连本地 `127.0.0.1:1883` 无认证，不需要动
- Bridge 是 Mosquitto 内建能力，本地 broker 做认证代理转发消息
- 中央 Broker 离线不影响打印机本地工作

---

## 2. 前置条件

### 2.1 安装 Docker

**macOS：**
```bash
brew install --cask docker
# 或从 https://docs.docker.com/desktop/mac/install/ 下载安装
```

**Linux：**
```bash
sudo apt update
sudo apt install docker.io docker-compose-v2
sudo systemctl enable docker --now
sudo usermod -aG docker $USER  # 免 sudo 运行 Docker，需要重新登录生效
```

**Windows：**
从 https://docs.docker.com/desktop/windows/install/ 下载安装 Docker Desktop。

### 2.2 验证 Docker 可用

```bash
docker --version
docker compose version
```

---

## 3. 最简验证（无认证，仅测试用）

一行启动，不持久化，不认证，重启后数据全部丢失：

```bash
docker run -d --name mosquitto-test \
  -p 1883:1883 \
  eclipse-mosquitto:2.0 \
  mosquitto -c /dev/null -v
```

验证是否启动成功：

```bash
# 终端 1：订阅
docker exec -it mosquitto-test mosquitto_sub -h localhost -t 'test/hello'

# 终端 2：发布
docker exec -it mosquitto-test mosquitto_pub -h localhost -t 'test/hello' -m 'world'

# 终端 1 应收到 "world"
```

清理测试容器：

```bash
docker rm -f mosquitto-test
```

---

## 4. 生产部署：Docker Compose（完整）

### 4.1 创建目录结构

```bash
mkdir -p ~/mosquitto-deploy/mosquitto/{config,data,log}
cd ~/mosquitto-deploy
```

最终目录结构：

```
~/mosquitto-deploy/
├── devices.txt               # 设备 SN 列表（唯一需要手动维护的文件）
├── generate_passwd.sh        # 从 devices.txt 批量生成密码文件
└── mosquitto/
    ├── docker-compose.yml
    ├── config/
    │   ├── mosquitto.conf    # 主配置
    │   ├── passwd            # 用户密码文件（脚本生成，不手动编辑）
    │   └── acl               # 访问控制列表（一次配置，永久不变）
    ├── data/                 # 持久化数据
    └── log/
```

### 4.2 编写 mosquitto.conf

创建 `~/mosquitto-deploy/mosquitto/config/mosquitto.conf`：

```ini
# ═══ 一、监听配置 ═══
listener 1883
# 不指定 bind_address，默认监听所有网卡 0.0.0.0

# ═══ 二、认证 ═══
allow_anonymous false
password_file /mosquitto/config/passwd

# ═══ 三、ACL ═══
acl_file /mosquitto/config/acl

# ═══ 四、连接限制 ═══
max_connections 200
max_inflight_messages 50
max_queued_messages 10000

# ═══ 五、持久化 ═══
persistence true
persistence_location /mosquitto/data/
autosave_interval 300

# ═══ 六、MQTT 协议参数 ═══
max_keepalive 300
message_size_limit 512000

# ═══ 七、日志 ═══
log_dest file /mosquitto/log/mosquitto.log
log_dest stdout
log_type error
log_type warning
log_type notice
connection_messages true
log_timestamp true
log_timestamp_format %Y-%m-%dT%H:%M:%S

# ═══ 八、系统监控（可选） ═══
sys_interval 10
```

### 4.3 设备管理：SN 列表 + 脚本批量生成密码

**设计理念**：设备 SN（序列号）是唯一身份标识，一台设备一个用户。不再逐台手动运行 `mosquitto_passwd`，而是维护一个 `devices.txt` 列表，脚本一把生成。

#### 4.3.1 创建设备列表

创建 `~/mosquitto-deploy/devices.txt`，每行一个设备 SN：

```txt
# ===== 打印机 SN 列表 =====
# 每行一个设备序列号，# 开头为注释
# 新增设备只需加一行，然后运行 generate_passwd.sh

# 切片工程 4台
8110026042710299B378
81100260503102537008
8110026050310266IC73
81100260503003514ZB5
# web全栈 2台
8110026050310190EKV9
8110026050310268AUFG
# 服务端、运维 2台
8110025060100049IXMZ
8110025070800048LD98
# 客户端 2台
8110025070800069BU7J
811002605310262H7H8
# 测试 1台
8110026050300191X4HB
```

#### 4.3.2 创建 App 管理用户

App 管理用户只此一个，手动创建一次即可：

```bash
cd ~/mosquitto-deploy

# 创建密码文件并添加 App 管理用户（-c 创建新文件）
mosquitto_passwd -c mosquitto/config/passwd lava_app
# 交互式输入密码，或：
# mosquitto_passwd -b -c mosquitto/config/passwd lava_app "your-secure-password"
```

#### 4.3.3 批量生成设备密码

```bash
cd ~/mosquitto-deploy

# 默认后缀 -iot2025，密码 = SN + 后缀
./generate_passwd.sh

# 自定义后缀
./generate_passwd.sh -suffix "!lava-prod"

# 生成后自动热重载 Broker（推荐）
./generate_passwd.sh -reload
```

**密码规则示例**（后缀 `-iot2025`）：

| SN | 密码 |
|----|------|
| 8110026042710299B378 | `8110026042710299B378-iot2025` |
| 81100260503102537008 | `81100260503102537008-iot2025` |

#### 4.3.4 脚本工作原理

```bash
devices.txt（你维护）
      │
      ▼
generate_passwd.sh
      │
      ├─ 逐行读取 SN，跳过空行和注释
      ├─ 对每个 SN: password = SN + 后缀
      ├─ 调用 mosquitto_passwd 写入 mosquitto/config/passwd
      ├─ 已存在的 SN 会被更新密码（幂等，可反复运行）
      └─ 可选 -reload: 自动 docker exec kill -HUP 1 热重载
```

**关键特性**：
- **幂等**：可反复运行，新增 SN 追加，已有 SN 密码更新
- **全量覆盖**：每次运行覆盖整个 passwd 文件（以 devices.txt 为准）
- **热重载**：`-reload` 参数发送 SIGHUP 信号，Broker 不中断现有连接
- **零 ACL 改动**：ACL 使用 `%u` 模式匹配，新增设备无需修改 ACL

> **注意**：如果没有安装 `mosquitto_passwd`，脚本会自动通过 Docker 调用：
> `docker run --rm -v ... eclipse-mosquitto:2.0 mosquitto_passwd ...`
> 也可以手动安装：macOS `brew install mosquitto` / Linux `sudo apt install mosquitto-clients`

### 4.4 编写 ACL 文件（动态设备版）

创建 `~/mosquitto-deploy/mosquitto/config/acl`：

```ini
# ═══════════════════════════════════════════════
# lava-farm ACL — 权限控制（动态设备版）
# ═══════════════════════════════════════════════

# App 管理客户端：全局 topic 读写权限
user lava_app
topic readwrite +/#

# ── 打印机客户端（一条 pattern 规则覆盖所有设备）──
# %u = 当前登录用户名（即设备 SN）
# 每个设备自动拥有自己 SN 下的 4 个 topic 权限
# 新增设备只需添加到密码文件，ACL 永远不用改
pattern read %u/request
pattern write %u/status
pattern write %u/notification
pattern write %u/response
```

**与传统 ACL 的对比**：

```ini
# ❌ 传统方式（每台设备 1 个 user 块 + 4 条 topic 规则）
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

# ... N 台设备 = 5N 行 ACL，无法维护

# ✅ 动态方式（4 行 pattern 覆盖所有设备）
pattern read %u/request
pattern write %u/status
pattern write %u/notification
pattern write %u/response

# 无论多少台设备，ACL 文件永远是 8 行（含注释头）
```

**权限规则解析**（以设备 `8110026042710299B378` 为例）：

- `pattern read %u/request` → 设备可订阅 `8110026042710299B378/request`，接收发给自己的命令
- `pattern write %u/status` → 设备可发布 `8110026042710299B378/status`，上报状态
- `pattern write %u/notification` → 设备可发布 `8110026042710299B378/notification`，上报上线/离线
- `pattern write %u/response` → 设备可发布 `8110026042710299B378/response`，返回命令结果
- **设备 A 无法发布/订阅设备 B 的 topic** → `%u` 模式天然隔离

**权限模型说明**：
- 打印机 A 不能订阅/发布打印机 B 的 topic → 防止误操作或恶意干扰
- App (`lava_app`) 有全局读写权限 → 可以管理所有打印机
- 每台打印机 4 个 topic（request/status/notification/response）→ 最小权限原则
- ACL 文件写完后**永久不变**，新增设备只需修改 `devices.txt` 并运行 `generate_passwd.sh`

### 4.5 编写 docker-compose.yml

创建 `~/mosquitto-deploy/docker-compose.yml`：

```yaml
version: '3.8'

services:
  mosquitto:
    image: eclipse-mosquitto:2.0
    container_name: lava-farm-broker
    restart: always
    network_mode: host                 # 使用宿主机网络，零 NAT 开销
    volumes:
      - ./mosquitto/config:/mosquitto/config:ro   # :ro 只读挂载
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
| `network_mode: host` | 是 | 零 NAT 开销，打印机直连宿主机 IP |
| `restart: always` | 是 | 宿主机重启后 Broker 自动恢复，7×24 可用 |
| 配置 `:ro` 挂载 | 是 | 防止容器内篡改配置 |
| healthcheck | 是 | Docker 自动检测 Broker 健康状态 |
| `max-size: 10m` | 是 | 日志轮转，防止磁盘写满 |

### 4.6 启动

```bash
cd ~/mosquitto-deploy

# 启动（后台运行）
docker compose up -d

# 查看日志
docker compose logs -f mosquitto

# 查看状态
docker compose ps
# 期望输出: lava-farm-broker  Up (healthy)
```

---

### 4.7 打印机端：出厂预装 Bridge 脚本

打印机出厂时预装一个 bridge 管理脚本和配置文件，开机自动桥接到中央 Broker。

#### 4.7.1 出厂脚本

每台打印机出厂前执行一次（所有打印机通用）：

```bash
#!/bin/bash
# 出厂预装 — 所有打印机通用
SN=$(cat /home/lava/printer_data/.lava.sn)

cat > /etc/mosquitto/conf.d/bridge-central.conf << EOF
connection lava-central
address lava-central.local:1883
remote_username ${SN}
remote_password ${SN}-iot2025
keepalive_interval 60
start_type automatic
bridge_attempt_unsubscribe false
topic ${SN}/status out 1
topic ${SN}/notification out 1
topic ${SN}/response out 1
topic ${SN}/request in 1
EOF
```

> **关键设计**：`address` 使用主机名 `lava-central.local` 而不是 IP。中央 Broker 机器通过 mDNS（Bonjour/Avahi）广播此主机名，打印机启动后自动解析。同一局域网内零配置发现。

#### 4.7.2 bridge-ctl 管理脚本

出厂预装 `/usr/local/bin/bridge-ctl`，生产环境修复用：

```bash
#!/bin/bash
# bridge-ctl — Bridge 管理工具（出厂预装）
# 用法:
#   bridge-ctl setup <central-host>   # 初始化/更换中央 Broker 地址
#   bridge-ctl up                     # 启动 bridge
#   bridge-ctl status                 # 查看状态

SN=$(cat /home/lava/printer_data/.lava.sn)
CONF="/etc/mosquitto/conf.d/bridge-central.conf"

case "${1:-}" in
  setup)
    CENTRAL="${2:-lava-central.local}"
    cat > "$CONF" << EOF
connection lava-central
address ${CENTRAL}:1883
remote_username ${SN}
remote_password ${SN}-iot2025
keepalive_interval 60
start_type automatic
bridge_attempt_unsubscribe false
topic ${SN}/status out 1
topic ${SN}/notification out 1
topic ${SN}/response out 1
topic ${SN}/request in 1
EOF
    /etc/init.d/S50mosquitto restart
    ;;

  up)
    /etc/init.d/S50mosquitto restart
    ;;

  status)
    if grep -q "Connecting bridge" /home/lava/printer_data/logs/mosquitto.log 2>/dev/null; then
      tail -5 /home/lava/printer_data/logs/mosquitto.log | grep -E "bridge|error"
    else
      echo "bridge log not found — check mosquitto status"
      ps aux | grep mosquitto | grep -v grep
    fi
    ;;
esac
```

#### 4.7.3 中央 Broker mDNS 主机名配置

```bash
# macOS（Bonjour 自带，无需额外安装）
# 设置共享名称即可：系统设置 → 共享 → 电脑名称 → lava-central

# Linux
sudo apt install avahi-daemon -y
sudo hostnamectl set-hostname lava-central
sudo systemctl restart avahi-daemon
```

验证 mDNS 解析（从打印机或其他设备测试）：

```bash
ping lava-central.local
# 应解析到中央 Broker 的局域网 IP
```

---

### 4.8 Bridge 故障修复：App LAN 远程修复

Bridge 故障时打印机不会出现在群控列表中。App 通过 LAN 直连打印机进行远程修复，**不需要 SSH**。

#### 4.8.1 检测 + 修复流程

```
群控 App 发现某打印机不在线
  │
  ├─ 用户点「LAN 修复」
  │
  ├─ App LAN 握手（现有流程，不动）
  │     1884 匿名 → confirm_lan_status → 拿证书 → 8883 TLS
  │
  ├─ App 通过 LAN MQTT 调 system/request
  │     {"method": "bridge_ctl.setup", "params": ["192.168.1.100"]}
  │
  ├─ 打印机的 repeater 转发到系统服务
  │     bridge-ctl setup 192.168.1.100
  │     → 写 bridge conf → 重启 mosquitto
  │
  └─ Bridge 恢复 ✅ → 打印机在群控中重新上线
```

#### 4.8.2 为什么不需要改 moonraker

```
App ──LAN MQTT (8883)──► printer mosquitto
                              │
                              ├─ system/request ──► repeater 监听
                              │                        │
                              │                        └─ 转发给系统服务
                              │                              │
                              │                   bridge-ctl setup <ip>
                              │
                              └─ {SN}/notification ──► moonraker（不动）
```

- 现有 `repeater` 组件已监听 `system/request`，转发系统请求
- bridge 管理脚本出厂预装，不依赖 moonraker 代码
- App 只需在 LAN 握手成功后多发一条 `system/request` 即可触发修复

---

### 4.9 已部署打印机：SSH 批量部署

对于已经出厂的旧打印机（没有预装 bridge 脚本），通过 SSH 批量推送一次即可，之后跟新机一样。

#### 4.9.1 准备：本地保存部署脚本

在群控机器（Mac / 运维电脑）上保存一个部署脚本：

```bash
# ~/mosquitto-deploy/deploy-bridge.sh — 本地保存
#!/bin/bash
# 批量部署 bridge 到已出厂的打印机
# 用法: ./deploy-bridge.sh <printer-ip> [central-host]

PRINTER_IP="${1:?Usage: deploy-bridge.sh <printer-ip> [central-host]}"
CENTRAL_HOST="${2:-lava-central.local}"
IDENTITY="${IDENTITY:-~/.ssh/id_rsa}"

# 1. 推 bridge-ctl 脚本
ssh -o ConnectTimeout=5 -i "$IDENTITY" root@"$PRINTER_IP" \
  'cat > /usr/local/bin/bridge-ctl' < ./bridge-ctl

ssh -o ConnectTimeout=5 -i "$IDENTITY" root@"$PRINTER_IP" \
  'chmod +x /usr/local/bin/bridge-ctl'

# 2. 执行初始化
ssh -o ConnectTimeout=5 -i "$IDENTITY" root@"$PRINTER_IP" \
  "/usr/local/bin/bridge-ctl setup $CENTRAL_HOST"

echo "✅ $PRINTER_IP done"
```

#### 4.9.2 单台部署

```bash
cd ~/mosquitto-deploy
./deploy-bridge.sh 192.168.1.101 lava-central.local
```

#### 4.9.3 批量部署（100 台）

```bash
# 准备 IP 列表
cat > printer_ips.txt << EOF
192.168.1.101
192.168.1.102
192.168.1.103
...
EOF

# 一键批量部署
while read ip; do
  ./deploy-bridge.sh "$ip" &
done < printer_ips.txt
wait
echo "全部完成"
```

**部署后效果跟新机完全一样**：`bridge-ctl` 已安装，后续 bridge 故障可直接用 App LAN 修复（§4.8），不需要再 SSH。

---

## 5. 启动后验证

### 5.1 基础连通性检查

```bash
# 1. 检查容器状态
docker compose ps

# 2. 检查端口监听（在宿主机上）
ss -tlnp | grep 1883          # Linux
# 或
lsof -i :1883                 # macOS

# 3. 查看 Broker 当前连接数
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/clients/connected' -C 1 -W 3
```

### 5.2 认证订阅/发布测试

需要先安装 mosquitto 客户端工具（`brew install mosquitto` / `apt install mosquitto-clients`）：

```bash
# 终端 1：以 App 身份订阅通配符 topic
mosquitto_sub -h localhost -p 1883 \
  -u lava_app -P "<你的App密码>" \
  -t '+/status' -t '+/notification' -v

# 终端 2：模拟打印机发布状态（用户名 = 设备 SN）
mosquitto_pub -h localhost -p 1883 \
  -u 8110026042710299B378 -P "<设备密码>" \
  -t '8110026042710299B378/status' \
  -m '{"jsonrpc":"2.0","method":"notify_status_update","params":[{"extruder":{"temperature":210},"heater_bed":{"temperature":60}}]}'

# 终端 1 应收到: 8110026042710299B378/status {"jsonrpc":"2.0","method":"notify_status_update",...}
```

### 5.3 权限隔离验证

验证打印机 A 不能写入打印机 B 的 topic（安全测试）：

```bash
# 尝试用设备 A 的身份发布设备 B 的 topic → 应被拒绝
# 设备 811...B378 试图发布 811...7008 的 topic
mosquitto_pub -h localhost -p 1883 \
  -u 8110026042710299B378 -P "<密码>" \
  -t '81100260503102537008/status' -m 'malicious data' \
  -d
# 预期结果: Connection Refused: not authorised
# ACL 的 %u pattern 拒绝跨设备写入，消息被静默丢弃
```

### 5.4 遗嘱消息（Last Will）测试

```bash
# 模拟打印机连接并设置遗嘱消息
# 启动一个带遗嘱的客户端，然后 Ctrl+C 中断
mosquitto_pub -h localhost -p 1883 \
  -u 8110026042710299B378 -P "<密码>" \
  -t '8110026042710299B378/status' -m 'online' \
  --will-topic '8110026042710299B378/notification' \
  --will-payload '{"server":"offline"}' \
  -d
# 按 Ctrl+C 终止 → App 订阅端会在 1.5 × keepalive 时间内收到 offline 通知
```

---

## 6. 运维命令速查

```bash
# ─── 容器生命周期 ───
docker compose up -d                    # 启动（后台）
docker compose down                     # 停止并删除容器
docker compose restart mosquitto        # 重启
docker compose ps                       # 查看状态

# ─── 日志 ───
docker compose logs -f mosquitto        # 实时日志
docker compose logs --tail=100 mosquitto  # 最近 100 行

# ─── 监控 ───
# 当前连接数
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/clients/connected' -C 1 -W 3

# 消息吞吐量
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/messages/received' -t '$SYS/broker/messages/sent' -C 2 -W 3

# 内存使用
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/heap/current' -C 1 -W 3

# ─── 用户管理（不中断服务） ───
# 新增设备：在 devices.txt 加一行 SN，然后：
./generate_passwd.sh -reload

# 删除设备：在 devices.txt 删除对应行，然后：
./generate_passwd.sh -reload

# 批量更新所有设备密码（更换后缀等）：
./generate_passwd.sh -suffix "!new-suffix" -reload

# ─── 持久化文件 ───
ls -lh mosquitto/data/
```

---

## 7. 常见问题排查

### 7.1 容器启动失败

```bash
docker compose logs mosquitto

# 常见错误：
# "Unable to open config file"       → volumes 路径错误，检查 docker-compose.yml
# "Address already in use"           → 1883 端口被占用，lsof -i :1883 检查
# "password_file: No such file"      → passwd 文件未创建，执行 mosquitto_passwd
```

### 7.2 客户端连不上 Broker

```bash
# 1. 检查防火墙
sudo ufw status                    # Linux
sudo ufw allow 1883                # 放行端口

# 2. 从目标机器测试 TCP 连通性
nc -zv <broker_ip> 1883

# 3. 检查 Broker 是否监听正确接口
docker exec lava-farm-broker netstat -tlnp | grep 1883

# 4. 查看 ACL 拒绝日志
docker compose logs mosquitto | grep "denied"
```

### 7.3 App 连接后收不到消息

```bash
# 1. 确认有消息在流动
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -u lava_app -P "<密码>" \
  -t '+/status' -C 5

# 2. 检查订阅数
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/subscriptions/count' -C 1 -W 3

# 3. 检查持久化队列堆积
docker exec lava-farm-broker mosquitto_sub -h localhost \
  -t '$SYS/broker/messages/stored' -C 1 -W 3
```

---

## 8. 安全加固（可选）

生产环境建议追加以下配置到 `mosquitto.conf`：

```ini
# 限制客户端 ID 长度
max_clientid_length 128

# 限制单包最大大小
max_packet_size 65536

# TLS 加密（公网部署时必须）
# listener 8883
# cafile /mosquitto/config/ca.crt
# certfile /mosquitto/config/server.crt
# keyfile /mosquitto/config/server.key
# require_certificate true
```

---

## 9. 资源估算

| 打印机数量 | 推荐内存 | 磁盘（持久化） |
|-----------|---------|---------------|
| ≤ 10 | 64 MB | 1 GB |
| ≤ 50 | 128 MB | 2 GB |
| ≤ 100 | 256 MB | 5 GB |
| ≤ 200 | 512 MB | 10 GB |

Mosquitto 极其轻量，树莓派 4B (4GB) 即可支撑 200 台打印机。

---

## 10. 核心概念总结

### Topic 结构

```
App 订阅（通配符）:
  +/status           → 所有打印机状态推送
  +/notification     → 所有打印机上下线通知

单设备通信:
  {SN}/request       → App 向打印机发送 JSON-RPC 命令
  {SN}/response      ← 打印机返回命令结果
  {SN}/status        ← 打印机定时状态推送（1s 间隔）
  {SN}/notification  ← 打印机上线/离线通知
```

### 连接流程

**LAN 模式（App 直连打印机）**：

```
App → 1884 匿名 MQTT（access_code 验证）
  → confirm_lan_status → 打印机弹窗 → 用户同意
  → 设备下发 CA + cert + key
  → App 8883 TLS + client cert 连接
  → SUBSCRIBE {SN}/response, {SN}/status, {SN}/notification
  → PUBLISH {SN}/request（发送命令）
```

**群控模式（打印机 Bridge → 中央 Broker）**：

```
打印机开机
  → mosquitto 读取 /etc/mosquitto/conf.d/bridge-central.conf
  → 解析 lava-central.local（mDNS → 中央 Broker IP）
  → Bridge CONNECT (username=SN, password=SN+后缀)
  → 中央 Broker 验证 passwd + ACL pattern %u
  → 上行: {SN}/status, {SN}/notification, {SN}/response → 中央
  → 下行: {SN}/request ← 中央
  → 群控 App 连中央 Broker (lava_app)，订阅 +/status, +/notification
```

**Bridge 故障 → App LAN 修复**：

```
群控 App 发现打印机离线
  → App LAN 握手（1884 → 证书 → 8883）
  → App 发送 system/request: bridge-ctl setup <新IP>
  → 打印机 repeater 转发 → 执行 bridge-ctl → 写 conf → 重启 mosquitto
  → Bridge 恢复
```

> **ACL 动态匹配说明**：`pattern read %u/request` 中的 `%u` 在连接时被替换为当前登录用户名（即设备 SN）。设备 `8110026042710299B378` 登录后，实际 ACL 检查为 `read 8110026042710299B378/request`，其他设备的 topic 自动拒绝。一台设备一条规则都不用写。

### 遗嘱消息（Last Will）

- 打印机 CONNECT 时预设 will 消息：`topic={SN}/notification`, `payload={"server":"offline"}`
- 正常断开 → Broker 清除 will，不发布离线通知
- 异常断开（断电/断网）→ Broker 检测心跳超时（1.5 × keepalive ≈ 45s），自动发布离线通知

### 持久化

- `persistence true` + `autosave_interval 300` → 每 5 分钟刷盘
- Broker 重启后自动恢复：订阅关系 + QoS ≥ 1 的未投递消息
- 最坏情况：崩溃时最多丢失 5 分钟内未确认的 QoS 消息

### QoS 策略

| 消息类型 | QoS | 说明 |
|---------|-----|------|
| 状态推送 (/status) | QoS 1 | 至少送达一次，需要可靠 |
| 通知 (/notification) | QoS 1 | 遗嘱消息不能丢 |
| 命令 (/request) | QoS 1 | 命令必须送达 |
| 响应 (/response) | QoS 1 | 确保结果被接收 |

### 故障检测矩阵

| 故障类型 | 检测方式 | 检测延迟 | 恢复方式 |
|---------|---------|---------|---------|
| 打印机断电 | Last Will offline | 1-3s | 用户手动重连 |
| 打印机 MQTT 断连 | Last Will offline | 1-3s | Moonraker 自动重连 |
| 打印机假在线 | 60s 无状态更新 | 60s | 标记离线 + 通知用户 |
| Broker 崩溃 | BrokerHealthMonitor | < 15s | App 等待 Broker 恢复后重连 |
| Broker 假活 | MQTT PINGREQ 无响应 | 15s | App 触发重连 |
| App 断连 Broker | MQTT 连接断开 | < 5s | 自动重连（指数退避） |
| **Bridge 断开** | 中央 Broker 收不到 `{SN}/notification` | < keepalive (60s) | **App LAN 远程修复**（见 §4.8） |
| 中央 Broker IP 变更 | Bridge 无法连接 | 重试间隔递增 | App LAN 更新 `bridge-ctl setup <新IP>` |

---

## 11. Flutter App 客户端连接

### 11.1 代码架构

```
BrokerSetupPage (UI)
    │
    ├─→ CredentialStore.saveBrokerCredentials(...)  ← 持久化凭据到 Keychain
    │
    └─→ BrokerConnectionManager.connect(host, port, username, password)
         │
         ├─→ MqttTransportImpl (mqtt_client 包封装)
         │    ├─ MqttClient.withPort(host, username, port)
         │    ├─ MqttConnectMessage.authenticateAs(username, password)
         │    ├─ client.connect()
         │    └─ client.updates?.listen(_onUpdates)  → 消息流
         │
         └─→ FarmMqttRouter (连接消息到业务层)
              ├─ start()
              │   ├─ transport.subscribe('+/status', qos: 1)
              │   └─ transport.subscribe('+/notification', qos: 1)
              │
              └─ _onMessage(msg)
                   ├─ +/status        → _handleStatus(sn, json)
                   │                    → FarmStore.onMqttStatus(sn, expanded, eventTime)
                   ├─ +/notification  → _handleNotification(sn, json)
                   │                    → FarmStore.onMqttNotification(sn, json)
                   └─ {SN}/response   → RequestTracker.complete(sn, json)
                                            │
                                        FarmStore._notify()
                                            │
                                        PrinterRegistryNotifier.addPrinter()
                                            │
                                        Riverpod → UI 重建
```

### 11.2 App 端连接步骤

1. 打开 App → 进入 Broker 设置页
2. 填写连接信息：
   - Broker 地址: `localhost`（或 Broker 所在 IP）
   - 端口: `1883`
   - 用户名: `lava_app`
   - 密码: `<lava_app 的密码>`
3. 点击 **"连接"** 按钮
4. App 自动完成：
   - 保存凭据 → MQTT TCP 连接 → 订阅 `+/status`、`+/notification`
   - 注册预设设备（从 `devices.txt` 的 SN 列表）
   - 启动消息路由（MQTT 消息 → FarmStore → UI）
5. 返回 Dashboard，看到设备列表

### 11.3 关键类

| 类 | 文件 | 职责 |
|----|------|------|
| `MqttTransportImpl` | `mqtt_transport_impl.dart` | 包装 mqtt_client，实现 TCP 连接/订阅/发布 |
| `FarmMqttRouter` | `farm_mqtt_router.dart` | 解析 MQTT 消息，路由到 FarmStore |
| `BrokerConnectionManager` | `broker_connection_manager.dart` | 连接状态管理，自动重连（指数退避） |
| `FarmStore` | `farm_store.dart` | 多设备状态聚合，时间戳保护去重 |
| `BrokerSetupPage` | `broker_setup_page.dart` | 连接配置 UI + 一键连接 |

### 11.4 测试方法

App 连接成功后，在终端模拟设备发布消息验证：

```bash
# 模拟设备上线
mosquitto_pub -h localhost -p 1883 \
  -u "8110026042710299B378" -P "8110026042710299B378-iot2025" \
  -t '8110026042710299B378/notification' \
  -m '{"server":"online"}'

# 模拟设备推送状态（含温度、打印进度）
mosquitto_pub -h localhost -p 1883 \
  -u "8110026042710299B378" -P "8110026042710299B378-iot2025" \
  -t '8110026042710299B378/status' \
  -m '{"jsonrpc":"2.0","method":"notify_status_update","params":[{"extruder":{"temperature":210.5,"target":210},"heater_bed":{"temperature":60.0,"target":60},"print_stats":{"state":"printing","filename":"benchy.gcode"},"virtual_sdcard":{"progress":0.45}}]}'

# App Dashboard 中对应设备卡片将实时显示:
# 🟢 online | 210.5°C / 60.0°C | printing benchy.gcode 45%
```