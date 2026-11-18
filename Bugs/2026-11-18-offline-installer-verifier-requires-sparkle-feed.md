# 离线安装包校验器误要求 Sparkle 更新源

状态：已修复；公开 Apple Silicon 安装包已通过解包校验。

## 现象

`scripts/build-offline-dmg.sh native` 已完成 48 项源码自检、1461 项 Swift 测试、App 和双驱动构建，但在安装包解包校验时停止，报告 App 的 `Info.plist` 不存在 `SUFeedURL`。

## 证据与根因

- `scripts/verify-app.sh` 正确要求离线 App 不得包含 `SUFeedURL`、自动检查开关、更新周期和公钥等 Sparkle 字段。
- `scripts/verify-doubao-driver-pkg.sh` 随后却仍按历史联网包规则，强制提取 `SUFeedURL` 并与发布 feed 比较。
- 因此同一个离线 App 不可能同时通过两层校验，DMG 入盘前必然失败。

## 修复

安装包校验器不再要求 `SUFeedURL`，改为显式拒绝六个 Sparkle 更新字段。这与 App 校验器和 `offline-only` 不联网目标一致，且保留解包后对真实 payload 的独立检查。

## 回归

- `BuildSigningTests.publicOfflineDmgBuildUsesFreshPublicInputs` 确认安装包校验器拒绝 Sparkle 字段，且不再提取 `SUFeedURL`。
- 对已构建的 `dist/Install SayAll.pkg` 重跑完整解包检查，App、两份驱动、本地化、架构、安装器结构和无 Sparkle 字段全部通过。

## 边界

本修复只更正离线安装包的校验矛盾；不恢复网络更新，不放宽 Developer ID、Apple 公证或正式发布要求。
