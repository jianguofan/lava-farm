# Spec: 预打印配置页

## ADDED Requirements

### Requirement: Preprint workflow shall guide production setup

系统 SHALL 提供产品选择、耗材确认、设备选择、批量投产四步流程。

#### Scenario: Batch produce a product

- **GIVEN** 产品库中已有产品定义
- **WHEN** 操作员选择产品并选择多台兼容设备
- **THEN** 系统 SHALL 上传产品文件并启动打印
- **AND** 系统 SHALL 展示每台设备的成功或失败结果。
