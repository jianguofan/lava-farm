# Design: 预打印配置页

## 1. 流程

```mermaid
graph LR
  Product[选择产品] --> Material[确认颜色/耗材]
  Material --> Printers[选择设备]
  Printers --> Execute[批量投产]
  Execute --> Result[结果面板/历史]
```

## 2. 复用现有能力

- `BatchPrintPage`：改造成四步表单容器。
- `BatchPrintCoordinator`：负责调度上传、启动打印、结果汇总。
- `FileUploader`：批量上传源文件。
- `BatchOperator`：启动打印/G-code 下发。
- `printerListProvider`：设备选择与过滤。
- `ProductDefinition`：投产对象。

## 3. 状态模型

`PreprintWorkflowState` 包含：
- selectedProduct
- materialConfirmations
- selectedPrinterSns
- executionProgress
- results

## 4. 结果与历史

阶段一可先以本地持久化保存投产记录：产品 id、设备 SN、开始时间、成功/失败、错误信息。
