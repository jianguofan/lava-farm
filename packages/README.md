# Packages

本目录存放项目依赖的本地子仓库（git submodule）。

## agent_core

- **仓库**: `git@gitlab.lan.snapmaker.com:client_dev_team/agent_core.git`
- **说明**: 与宿主无关（host-agnostic）的 LLM Agent 内核，纯 Dart，零 Flutter 依赖。提供单循环 function-calling 引擎、可插拔 LLMProvider、工具注册、权限门控、上下文管理、会话持久化等能力。
- **接入方式**: git submodule

### 初始化/更新

```bash
# 首次克隆主仓库后初始化 submodule
git submodule update --init --recursive

# 更新 submodule 到远程最新
git submodule update --remote packages/agent_core
```
