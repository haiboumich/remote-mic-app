# Chromecast 遥控器深色模式白底与电量未接入

## 现场证据

- 环境：`offline-only` build 322，Chromecast 语音和 IOHID 普通按键已经在另一台 Mac 上可用。
- 用户切到深色外观后，主按键映射页的 Chromecast 遥控器周围出现完整白色矩形；同一资源还用于 Onboarding 控制来源缩略图和遥控器主图，因此三处都有相同风险。
- 原资源 `Resources/Chromecast-remote-photo.png` 为 `360 × 800` RGB PNG，没有 alpha 通道。SwiftUI 只能绘制整张白底图片，无法从像素中推断遥控器轮廓。
- build 322 的公开适配器没有发现标准 Battery Service `180F`，没有读取 Battery Level `2A19`，能力声明也始终不含 battery；界面因此主动隐藏 Chromecast 电量。此前日志只证明 CoreBluetooth 隐藏 HID service `1812`，不能据此判断 `180F` 是否同样不可用。

## 根因

图片问题是资源本身缺少透明通道，不是 macOS 深色模式或屏幕变黑造成。只在视图外层加圆角或背景色仍会保留原图内部白底，也会让主画布、缩略图和 Onboarding 出现不一致。

电量问题属于公开适配器功能缺口：硬件是否向目标 macOS 暴露标准电池服务尚无真机证据，但代码此前完全没有请求该服务，因此“没有显示”不能证明“无法读取”。

## 修复

- 使用 macOS Apple Vision 在本机离线生成前景遮罩，把原图转换为保持 `360 × 800` 画布和既有主体位置的 RGBA PNG；不裁切、不重心平移，避免破坏已校准的 Chromecast 按键连线锚点。
- 公共 CoreBluetooth 连接在既有 ATVV、DIS、可选 HID 发现之外，同时可选发现 `180F/2A19`。服务或特征缺失、读取失败、值不在 `0...100` 时只写脱敏诊断，不使语音或按键连接失败。
- 有效值到达后才增加动态 battery 能力并写入当前 Chromecast 档案；Battery Service 早于 ATVV Ready 返回时先缓存，档案建立后再显示。
- 断连、停用或重连时移除旧电量。相同值不重复更新；首次读取失败即使当前缓存本来是 `nil` 也保留一条诊断，便于区分“服务不存在”和“读取失败”。
- UI 只在真实百分比存在时显示 Chromecast 电量，不显示“未知”占位。私有 Chromecast 包、小米/红米、Siri Remote、ATVV 语音与 IOHID 按键路径不变。
- build 号从 322 递增到 323。

## 静态验证

- 新 PNG 保持 `360 × 800`，包含 alpha 通道；前景 alpha 包围盒为 `(87, 20)–(324, 777)`，SHA-256 为 `15a0f6f5144b81b05ef3975016104ac30bc0db42c872bf085c63036975eb344a`。
- 已在仓库外把透明图分别合成到浅色和深色底进行人工查看；遥控器轮廓完整，深色底不再出现原始白色矩形。
- 按用户要求，本轮不运行 Swift 单测、不启动、退出、安装或替换正在运行的 SayAll，也不执行生产 App 离屏截图；只允许静态检查、编译打包和 DMG 结构/来源校验。

## 真机验证边界

当前开发 Mac 没有 Chromecast 遥控器。build 323 必须在用户的另一台 Mac 验证：主映射页、控制来源缩略图和 Onboarding 主图在深色外观下无白框；若系统暴露 `180F/2A19`，设备卡显示 `0...100%`。若仍不显示，只导出 `CHROMECAST BATTERY` 行即可判断是 `service_missing`、`level_missing`、`read_failed`、`invalid_value` 还是已读到百分比。该结果不能由编译或静态资源检查替代。
