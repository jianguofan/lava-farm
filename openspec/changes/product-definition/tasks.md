# Tasks: 产品定义与产品中心

## 1. 数据模型与解析

- [x] 新增 `ProductDefinition` / `ProductMaterial` 模型。
- [x] 新增 `GcodeParser`：提取预计时长、物料重量、颜色注释等可得字段。
- [x] 新增 `ThreeMfParser`：读取 ZIP/XML 中的缩略图和 plate 信息。
- [x] 为解析失败保留手工录入 fallback。

## 2. 持久化与 Provider

- [x] 新增 `ProductRepository`，支持 CRUD、同名版本自增、搜索。
- [x] 新增 `productProvider` / `productListProvider`。
- [x] 重启应用后恢复产品库。

## 3. 产品中心 UI

- [x] 新增 `ProductCenterPage`。
- [x] 新增 `ProductCard`，按参考图展示缩略图、生产参数、颜色克重。
- [x] 新增上传/导入面板，支持拖拽或文件选择。
- [x] 在主界面加入"产品信息/产品中心"入口。

## 4. 投产衔接

- [x] 产品卡片"投产"跳转预打印流程。
- [x] `BatchPrintPage` 支持接收初始产品。

## 5. 验证

- [ ] `flutter analyze`
- [ ] `flutter test`
- [ ] 手工导入一个 G-code/3MF，确认卡片字段、缩略图、投产入口可用。
