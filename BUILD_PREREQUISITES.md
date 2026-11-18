# Offline-only 构建前置条件

本文只列出从全新 checkout 构建、安装公开 `offline-only` 版本时，代码仓库之外必须
提前具备的机器条件和人工步骤。构建脚本本身不得依赖旧 `.build`、已安装的 SayAll、
已安装的虚拟音频驱动、私有组件或本机遗留环境变量。

## 构建机

- 支持 Apple Silicon（目标 macOS 14 或更高）和 Intel（目标 macOS 13 或更高）。
- 安装完整 Xcode，且 Xcode 自带的 Swift 必须支持仓库的 `swift-tools-version: 6.2`；
  当前应使用 Xcode 26 或更高版本。只有 Command Line Tools 不够，因为虚拟音频驱动
  需要 `xcodebuild`，完整测试还需要 Swift Testing。
- 至少预留 15 GB 可用磁盘空间。
- 首次取得仓库、SwiftPM 公开依赖和固定版本 BlackHole 源码时需要互联网。生成后的
  App 正常运行不需要互联网；offline-only 的运行时边界见
  [`OFFLINE_ONLY.md`](OFFLINE_ONLY.md)。

安装 Xcode 后至少启动一次，然后在终端执行：

```zsh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
xcrun swift --version
```

如果 Xcode 安装在其他位置，把第一条命令中的路径替换为实际
`Xcode.app/Contents/Developer` 路径。

## 从干净源码生成 DMG

先提交并 Push 要打包的源码，切到没有未提交或未跟踪文件的 checkout，再执行统一入口：

```zsh
make dmg
```

默认只生成当前 Mac 架构的产物。需要同时生成 Apple Silicon 和 Intel 两套产物时执行：

```zsh
make dmg DMG_VARIANT=all
```

也可将 `DMG_VARIANT` 设为 `apple-silicon` 或 `intel`。Makefile 会动态读取当前完整
Git HEAD，调用 `scripts/build-offline-dmg.sh`，并在复制产物前再次验证 DMG 包内
`SayAllSourceCommit` 与该 HEAD 完全一致；不使用手写 commit 文案。

底层脚本会先运行公开模式 self-test 和完整 Swift 测试，再从新的临时 SwiftPM
scratch/cache 构建 App；虚拟音频驱动也会从固定 BlackHole commit 重新构建。脚本强制
使用 `SAYALL_PRIVATE_PLATFORM_MODE=public`、清除私有包和诊断配置，并在打包后校验
DMG、Installer payload 与包内源码 commit。它不会读取已有 `.build`、已安装 App 或
已安装驱动作为构建输入。

输出位置：

- `make dmg` 的最终交付物：`build/SayAll-<version>-<build>.dmg`
- Intel：`build/SayAll-<version>-<build>-Intel.dmg`
- `build/` 中同时生成对应的 `.sha256` 文件；该目录被 `.gitignore` 忽略。
- `dist/` 继续保留底层 App、驱动、Installer PKG 和架构中间产物，供完整校验使用。

入口要求干净 checkout，是为了让 DMG 内记录的源码 commit 可复现。需要修改代码时，
先完成测试、提交并 Push，再从该 commit 执行 `make dmg`。

本机真机联调时，可先安装刚构建出的虚拟音频驱动，不必等待 DMG：

```zsh
./scripts/install-virtual-audio-driver.sh
```

该脚本会请求管理员密码并写入系统音频驱动目录；校验过程只使用 macOS 自带工具，
目标 Mac 不需要预装 Homebrew 或 `rg`。旧的 `install-doubao-driver.sh` 名称仅为历史兼容
入口，安装的仍是 SayAll 使用的 `MiRemoteV2ch` 虚拟音频驱动，不依赖豆包 App。

## 安装到另一台 Mac

1. 将对应芯片架构的 DMG 和 `.sha256` 一起复制到目标 Mac，并核对 SHA-256。
2. 打开 DMG，运行其中唯一的 `Install SayAll.pkg`（Intel 包名称带 `Intel`）。
3. 安装系统级虚拟音频驱动时，macOS 会要求管理员授权；这一步不能由构建脚本代替。
4. 安装完成后，在“系统设置 → 蓝牙”中配对 Chromecast Remote。
5. 首次启动 SayAll 后，按系统提示授予蓝牙权限。Fn/地球键注入和普通按键控制还需要
   输入监控与辅助功能权限；授权后完全退出并重新打开 App。

不要求目标 Mac 预先安装 SayAll、MiRemoteV 2ch、Homebrew、Swift、Xcode 或 Command
Line Tools。安装器会把 App 放到 `/Applications/SayAll.app`，并安装随包构建的兼容
虚拟麦克风。

## 本地包的信任边界

`build-offline-dmg.sh` 为可复现的开发者自建入口，固定使用 ad-hoc App/驱动签名和未
签名 Installer；它不是 Apple 公证的官方发行包。复制到另一台 Mac 后，Gatekeeper
可能要求在 Finder 中按住 Control 点按 Installer 并选择“打开”，或在“系统设置 →
隐私与安全性”中明确选择“仍要打开”。不要关闭 Gatekeeper，也不要降低系统安全设置。

如果需要双击即可安装、可公开分发的无警告产物，必须使用项目正式发布流程完成
Developer ID Application / Installer 签名、Apple 公证和 staple；证书与公证凭据不
属于源码 checkout，也不得写入本文件或构建脚本。

## 仍需人工完成的真机验收

构建和静态校验不能替代以下现场步骤：

- 在系统蓝牙中完成遥控器配对；
- 在系统设置中确认蓝牙、输入监控和辅助功能权限；
- 确认 SayAll/MiRemoteV 2ch 虚拟麦克风已就绪；
- 按住 Chromecast 语音键说话、松开结束，验证 Fn 按下/释放、首字、尾字、连续会话、
  断连和睡眠恢复；
- 断开互联网后检查运行期间没有 DNS、HTTP(S)、WebSocket、Bonjour 或非回环连接。

公开适配器当前只支持物理 hold-to-talk 语音链路；普通 HID 按键、触控、电量和
toggle/MIC_OPEN 不属于这次可移植 DMG 的已验收范围。
