# Design: 单设备详情与控制

## 1. 页面分区

- 顶部：设备名、SN、机型、连接方式、状态 badge。
- 左侧：打印进度、当前产品/文件、剩余时间。
- 中部：喷嘴/热床温度和 30 分钟曲线。
- 右侧：远程操作按钮和温度设置。
- 底部：任务日志时间线、耗材余量、摄像头区域。

## 2. 数据来源

- `FarmStore.getPrinter(sn)`：当前状态。
- `FarmSnapshot`：历史温度曲线。
- `BatchOperator` / 单设备 command gateway：远程命令。
- `camera_service.dart` / `camera_view.dart`：摄像头画面。

## 3. 命令

详情页命令与批量命令共享底层发送逻辑，避免两套协议实现。
