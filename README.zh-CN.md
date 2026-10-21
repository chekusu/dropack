# Dropack

**大文件，批量快传。**

原生 iPhone / iPad 应用：把原始照片和视频打成包，通过系统分享菜单发送；收到后，有进度、可恢复地逐项存入系统相册。

[官网](https://dropack.app) · [加入 TestFlight](https://testflight.apple.com/join/yjrwM4vT) · [English](README.md) · [官网源码](https://github.com/chekusu/dropack.app)

## 功能

- 从照片或文件选择素材，整理分享相册；点击分享时再打包，更新包时复用未变化的资源。
- 默认导出 `.dropack` 包，也支持普通 ZIP。`.dropack` 本质上是带相册清单的 ZIP。
- 通过系统 AirDrop 分享；收到包后先浏览分享相册，再同步到自己的 Photos 相册。
- 从“文件”选择 ZIP、照片、视频或目录，包括系统支持的 U 盘、读卡器和云盘。
- 分开展示 iCloud 下载与打包进度，支持任务暂停、恢复及受系统条件限制的后台处理；支持 Live Activities。
- 依据内容散列和本地导入记录跳过已确认存入的内容；意外中断且结果不明的保存需要核对。
- 相册内预览照片、播放视频、增删项目、管理本地包；支持 16 种语言和主题切换。

最低系统版本为 iOS / iPadOS 17。素材处理在本机进行，无需 Dropack 账户。iCloud、AirDrop、文件提供者及检查更新可能使用网络。

## 本地构建

需要 macOS、**Xcode 26 或更新版本**和 Python 3。App 使用 Swift / SwiftUI；本地构建不需要 Expo 或 Node.js。

```sh
git clone https://github.com/chekusu/dropack.git
cd dropack
open Dropack.xcodeproj
```

选择 `Dropack` scheme 和 iPhone / iPad 模拟器即可构建。Xcode 会下载固定版本 ZIPFoundation 0.9.20。

真机运行使用自己的 Apple 开发团队，并为 App 和 Live Activity 扩展设置独立的 Bundle ID。修改 `app.dropack.ios` 前缀时，也要同步修改 `Dropack/Info.plist`、`Dropack/Services/PackageBackgroundExecution.swift` 和工程生成脚本中的相关标识。公开仓库不含官方签名凭据及 Expo 发布配置。

```sh
python3 scripts/generate_project.py --check
python3 scripts/localization_audit.py
python3 -m unittest discover -s scripts/tests
swift test --build-system native
swift test --build-system native --package-path Tests/ZIPIntegration
xcodebuild -project Dropack.xcodeproj -scheme Dropack \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath build/DerivedData CODE_SIGNING_ALLOWED=NO build
```

目录结构和贡献说明见 [英文 README](README.md)、[CONTRIBUTING.md](CONTRIBUTING.md) 和[本地化说明](localization/README.md)。

## 使用边界

AirDrop 的传输及接收行为由苹果系统控制；本项目没有自建跨平台传输协议，也不保证 AirDrop 的网络字节续传。接收文件可能先进入“文件”，再由用户选择用 Dropack 打开。

打包保留原件，不转码；原件中的位置等元数据可能随包发送。打包和 ZIP 解压按项目保存检查点，中断的当前项目可能需要重做；原始文件暂存支持按字节续做，Photos 写入则需要整项完成。iOS 决定后台执行时间，灵动岛本身不能维持后台运行。

导入需要足够的手机存储空间。云盘可能先下载完整 ZIP；媒体编码支持取决于 iOS。不支持加密 ZIP、分卷 ZIP 或自动展开嵌套 ZIP。大文件处理速度和容量受设备、存储与来源影响。

源码可能领先于当前 TestFlight 版本；构建源码不等于已完成苹果审核。

## 开源协议

代码采用 [MIT](LICENSE) 协议，版权归 CHEKUSU（2026）。第三方依赖说明见 [ThirdPartyNotices.txt](ThirdPartyNotices.txt)，应用插画与图标说明见 [ASSETS.md](ASSETS.md)。协议不授予以 Dropack / CHEKUSU 商标暗示官方出品或背书的权利。
