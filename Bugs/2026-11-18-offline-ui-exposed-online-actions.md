# offline-only UI 暴露无效在线入口

## 错误证据

`offline-only` 已把 Sparkle、硬件公告和外部链接的运行时目标替换为禁用值，但生产
`SettingsView` 仍渲染“检查更新”、预发布开关、手机/手表/网页遥控和 App Store 入口。
这些入口不会完成公网请求，但与用户要求的
“不可用在线行为应隐藏”不一致。

## 根因

早期离线改造只替换了 URL 和请求实现，没有把同一产品能力边界用于 UI 可见性；页面仍按
完整在线产品的信息架构组装。

## 修复

- 在 `OfflineRuntimePolicy` 明确更新、在线伴随遥控、硬件公告和普通外部链接的禁用边界。
- 设置、连接和 Onboarding 使用同一边界隐藏对应入口。
- 诊断区移除上传状态，改为明确说明日志只保存在本机。
- 用户明确点击的第三方语音工具官方下载链接保留，但 App 不预取或直接请求。
- 从包内 `SayAllSourceCommit` 生成 About commit 链接；只接受 40 位小写十六进制 SHA，
  只在用户点击时交给系统浏览器。
- App 与状态菜单的“关于”改为打开含追溯信息的设置页。

## 验证

- `OfflineRuntimePolicyTests`：覆盖能力开关、在线控制源过滤、commit 校验/目标 URL、诊断上传
  隐藏和生产 UI 结构。
- 静态网络审计：产品源码唯一 `URLSession.shared.data` 调用只接受 `ws://127.0.0.1`、
  `localhost` 或 `::1` 并转换为同主机 HTTP；Apple Remote 音频 Helper 的 `NWListener` 设置
  `acceptLocalOnly` 且绑定 `127.0.0.1`，客户端也只连接 `127.0.0.1`。公开兼容层的手机、
  手表和网页遥控实现均为无网络 no-op。
- 公开构建脚本现在拒绝 Sentry、诊断公钥/客户端证明、云中继和 Early Access 配置；产物校验
  同时拒绝这些字段、Sparkle、Bonjour、本地网络描述及 `Sentry.framework`。Intel 公开包也不再
  写入 `SUFeedURL`。
- `./scripts/test.sh`：48/48 通过。
- `swift test --disable-keychain`：1464 项、106 个 suite 通过。
- `verify-repository-governance.sh`、`verify-localizations.sh`、脚本语法与 `git diff --check`
  通过。
- 生产设置页已在 `1020 × 772` 下检查中/英文、浅色/深色：commit 链接可见，更新、公告、
  在线伴随遥控和诊断上传状态不可见；真实运行的连接页也只显示本地遥控器与音频状态。
- 最终干净 commit 的 App/Installer/DMG 身份和运行时网络观察在 DMG 构建后回填。

## 边界

语音工具下载与 commit 链接都是用户明确点击的公网例外。静态渲染不会请求外网；用户点击后的浏览器
网络活动属于该明确操作，必须与 App 后台行为分开记录。
