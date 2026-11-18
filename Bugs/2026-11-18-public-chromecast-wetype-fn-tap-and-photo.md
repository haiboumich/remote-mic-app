# 公开 Chromecast 配对误用 Fn 点按且主界面显示错误遥控器图片

状态：代码修复完成；真机语音文字链路已通过，新图片待本地包视觉复核。

## 现象

1. `offline-only` 公开构建选择 Chromecast 语音遥控器和微信输入法后，引导把遥控器的物理按住转换成开始、结束各一次 Fn 点按。
2. SayAll 能连接遥控器、解码并播放完整音频，但微信输入法在 Fn-down 开始后被 120 ms 后的 Fn-up 立即停止，文本框没有文字。
3. 主设置的设备卡显示 Chromecast 已连接，按键映射画布却继续显示 RC003 小米遥控器图片。

## 证据

- 失败会话中 SayAll 按计划发出开始和结束两次完整 Fn 点按，音频样本全部播放且输入框保持焦点，微信输入法仍没有持续识别。
- 恢复微信输入法默认配置后，确认“启动语音输入 = Fn + 空格”“按住说话 = Fn”，麦克风为 SayAll。
- 临时关闭 `voiceFnTapModeEnabled` 后重启生产 App，主设置显示 Fn、按住说话和关闭 Fn 点按。
- 真机通过会话中 Fn 保持约 4.2 秒，58,240 个样本全部接收、调度并播放，零中断、零入队失败，`PUBLIC_EVENT` 结果为 passed；文本框写入“无线麦 C2 已经连接成功”。此前同一环境的 Onboarding 会话还通过了 94,080 个样本。

## 根因

- `OnboardingVoicePairingPlan.gestureCandidates` 对所有 Chromecast 无条件优先 `.toggle`。公开适配器实际只支持 `.hold`，但 `canDrive` 又允许 hold-only 来源通过 Fn 点按驱动 toggle 工具，于是微信输入法本来可直接使用的原生 Fn 按住被不必要地转换。
- `RemoteMappingCanvas` 的图片解析器只加载 `VoiceRemoteCatalog` 中的小米资源；当公开 Chromecast 走共享画布时，没有专属资源映射而回退为 RC003。

## 修复

- 只有 Chromecast 适配器真实声明 `supportsToggleVoiceGesture` 时才保持 toggle-first；公开 hold-only Chromecast 按工具推荐模式排序。微信输入法因此解析为 `hold + Fn`、`fnTapModeEnabled=false`、Chromecast `.hold`。
- `RemoteMappingCanvas` 显式加载并选择 `Chromecast-remote-photo.png`，不改变 `VoiceRemoteCatalog` 的小米设备采用边界；未知型号继续显示缺图占位。
- App 固定资源清单新增 Chromecast 图片，缺图产物由 `scripts/verify-app.sh` 拒绝。

## 回归

- `OnboardingVoicePairingPlanTests` 覆盖公开 hold-only 与支持 toggle 的私有适配器两种编译边界。
- `VoiceRemoteCatalogTests` 覆盖 Chromecast 画布资源、RC001/RC003 原映射、未知型号 nil 以及资源文件存在。
- 本地包视觉复核必须确认主映射页显示真实 Chromecast 图片，且默认设置为 Fn 按住、关闭 Fn 点按。

## 边界

- 自动化不能证明第三方输入法接受合成事件；通过结论依赖本次真实遥控器、真实虚拟麦克风和真实文字上屏证据。
- 本次不宣称普通 HID、触控、电量、断连/睡眠恢复、其他 macOS/固件、严格断网审计或正式签名 DMG 已完成。
- 微信输入法配置属于用户可见的第三方设置；SayAll 不读取或修改其私有文件。
