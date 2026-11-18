# Chromecast 确定键打开 Music：公开包的按键边界

## 现象

在公开 `offline-only` App 中按 Chromecast Voice Remote 圆盘确定键，macOS 会把它解释为
播放/暂停；没有媒体会话时会拉起 Music。旧设置页仍允许把确定键配置为 Return，但公开适配器当时
没有普通按键输入，因此界面承诺与运行时能力不一致。

## 根因与证据

该遥控器通过 BT-AACP 暴露虚拟 HID。真机报告中左、右、确定分别是 Menu Up `0x44`、
Menu Down `0x45`、Menu Left `0x41`；macOS 在 CGEvent 之外直接消费为上一首、下一首、播放/暂停。
`IOHIDDeviceOpen(seize)`、CGEventTap、`hidutil` 设备属性和 usage 重映射均不能阻止这条系统路径。
完整历史证据见 `Testing/ChromecastVoicePitfalls.md`。

静音键不同：报告值 `0x08` 会产生可由现有输入监控事件抑制器捕获的 `systemKey(7)`，因此可作为
无需 DriverKit/Karabiner 的 Return 替代键。用户明确不希望在公司电脑安装系统扩展。

## 修复

- 用户在失败包 `d6b7debe` 上传的真机日志给出直接证据：ATVV 语音协商成功后立刻记录
  `CHROMECAST GATT ... reason=hid_service_missing`。macOS 会对这只已配对的正品遥控器隐藏
  CoreBluetooth HID service `1812`，因此 `2A4D` 只能保留为系统确实暴露该服务时的回退，不能作为主路径。
- 公开适配器改由独立 IOHID 源精确匹配正品虚拟设备 VID/PID `0x18D1:0x9450`，读取已实测的
  Report ID 1（`01 XX 00`）并按 A0 usage 表产生配对的按下/抬起边沿；语音仍走 CoreBluetooth ATVV。
  IOHID 优先于 GATT，避免同一物理按键被两个传输重复分发。
- 每个 Report characteristic 使用独立解码状态，避免其他报告通道的零值错误释放活动按键。
- 左、右、确定在公开构建固定为 macOS 管理；旧全局/逐键豁免不能解锁，设置页显示系统实际行为。
- 新 Chromecast 档案静音键默认 Return；旧 `volumeMute` 默认只迁移一次，保存迁移前档案备份；
  后续用户手动改回系统静音不会再次被覆盖。
- IOHID 报告线程在主线程执行映射前，为静音和音量的 `systemKey(7)` / 音量事件提前登记现有抑制器；
  断连、替换传输或异常报告会取消活动按键。Onboarding 只要求
  静音、返回、主页、上/下等安全键，不统计左、右、确定。

## 验证边界

自动化覆盖精确 VID/PID、IOHID Report 归一化、A0 usage 解码、成对边沿、重复报告、异常/断连取消、
IOHID/GATT 去重、系统管理策略、一次性迁移、Onboarding 门禁及中英文文案。自动化不能证明
目标 Mac 的 IOHID 打开权限，也不能替代原生事件与报告回调的真机时序；交付前仍需真机确认：

1. 静音键在文本框只产生一次 Return，系统音量不变；
2. 返回、主页、上/下与音量的物理键位不串位；
3. 左、右、确定只保留 macOS 行为，不执行 SayAll 映射；
4. 断连不会残留按下态，语音链路仍可完成微信输入法文字闭环。
