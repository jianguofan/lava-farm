# Spec: 产品定义

## ADDED Requirements

### Requirement: Product definitions shall represent printable products

系统 SHALL 保存可复用的产品定义，至少包含产品名、版本、机型、预计生产时长、物料总重、单盘数量、材料颜色/克重、源文件路径、缩略图路径。

#### Scenario: Import a printable file

- **WHEN** 操作员导入 G-code 或 Gcode.3MF
- **THEN** 系统 SHALL 创建一个产品定义
- **AND** 系统 SHALL 尽可能提取生产时长、物料重量和缩略图
- **AND** 缺失字段 SHALL 可由操作员手工补全

### Requirement: Product center shall display product cards

产品中心 SHALL 以网格卡片展示产品缩略图、生产参数、物料颜色/克重和投产入口。

#### Scenario: Start production from a product

- **WHEN** 操作员点击产品卡片上的“投产”
- **THEN** 系统 SHALL 进入预打印配置流程
- **AND** 当前产品 SHALL 作为预选产品传入。
