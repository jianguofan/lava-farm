# Proposal: 桌面控制中心

## Summary

定义 Flutter 桌面控制中心的壳层能力：Broker 配置、运行模式、系统托盘、窗口管理、开机自启、安装包和日志入口。

## Motivation

版本计划模块⑥是所有业务功能的基础。现有项目已具备 Broker 设置、日志页和 Flutter 桌面骨架，但 OpenSpec 需要把桌面壳层与业务模块拆开描述，避免和产品/控制面板混在一起。

## What It Does

- 连接独立 MQTT Broker。
- 提供生产模式/评估模式提示。
- 系统托盘、窗口管理、开机自启。
- 安装包包含控制中心和 Broker 部署指引。
- 提供日志查看和诊断入口。

## Non-goals

- 不管理云端账号。
- 不实现多用户权限。
- 不把 Broker 强绑定为 App 子进程；生产模式仍以独立 Broker 为主。

## Success Criteria

- App 启动后能连接 Broker 并恢复设备列表。
- Broker 异常时 UI 有明确提示。
- Windows/macOS/Linux 安装包流程可验证。
