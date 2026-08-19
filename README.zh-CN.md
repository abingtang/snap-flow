<p align="center">
  <img src="macos/icon-variants/app-icon.png" alt="SnapFlow 应用图标" width="144">
</p>

<h1 align="center">SnapFlow</h1>

<p align="center">
  原生 macOS 菜单栏工具：截图、识别、翻译，并整理屏幕上的重要内容。
</p>

<p align="center">
  <a href="https://zeycode.cn/snapflow/">用户手册</a> ·
  <a href="https://github.com/abingtang/snap-flow/releases/latest">下载安装</a> ·
  <a href="https://github.com/abingtang/snap-flow">GitHub</a> ·
  <a href="README.md">English</a>
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="版本 0.0.6" src="https://img.shields.io/badge/version-0.0.6-orange">
</p>

SnapFlow 是一款以 macOS 为主线的桌面工具，用于把屏幕内容转换为可使用、可复用的信息。框选内容后，可以识别文字、翻译、标注，并保存重要结果供之后查找。

## 核心功能

| 功能 | 说明 |
|------|------|
| 区域截图 | 冻结屏幕，框选区域或窗口，使用放大镜，完成标注、复制、保存或贴图。 |
| 滚动截屏 | 手动滚动采集内容，并拼接成长图。 |
| 贴图 | 将截图固定在屏幕上，支持复制、保存、收藏和 OCR。 |
| OCR | 使用本机 Vision，也可以配置百度、有道、腾讯、火山、Google 和自定义 HTTP 服务。 |
| 翻译 | 使用 Apple Translation，以及已配置的云服务或模型服务翻译选中文本和截图。 |
| 历史与收藏 | 搜索、还原和收藏截图、OCR 结果、翻译结果及剪切板记录。 |

## 下载安装

普通用户请从 [GitHub Releases](https://github.com/abingtang/snap-flow/releases/latest) 下载最新安装包。打开 ZIP 或 DMG 后，将 `SnapFlow.app` 移入「应用程序」。

当前发行包面向 Apple Silicon（`arm64`），系统要求为 macOS 15.0 或更高版本。Intel Mac 可以从源码构建。

未签名或未公证的构建首次打开时，可能需要在 Finder 中右键选择「打开」，或在「系统设置 → 隐私与安全性」中允许打开。

## 权限与服务配置

| 权限 | 用途 |
|------|------|
| 屏幕录制 | 区域截图、OCR、截图翻译和滚动截屏。 |
| 辅助功能 | 读取其它应用中的选中文本，用于划词翻译。 |

本机 Vision OCR 和系统翻译不需要云端账号。云 OCR 和云翻译服务需要在应用内配置 API Key。密钥保存在本机设置中，SnapFlow 没有后端账号体系。

## 从源码构建

### 环境要求

- macOS 15.0 或更高版本
- Xcode 16 或更高版本
- Swift 6
- 用于本地签名和权限测试的 Apple Development Team

### 打开工程

```bash
git clone https://github.com/abingtang/snap-flow.git
cd snap-flow
open macos/SnapFlow.xcodeproj
```

在 Xcode 中选择 **SnapFlow** Target，配置 **Signing & Capabilities**，然后按 `⌘R` 运行。

### 使用命令行构建 Debug 版本

请在仓库根目录执行：

```bash
xcodebuild \
  -project macos/SnapFlow.xcodeproj \
  -scheme SnapFlow \
  -configuration Debug \
  build
```

本地签名配置可参考 [`macos/Configurations/Signing.xcconfig.example`](macos/Configurations/Signing.xcconfig.example)。本地 `Signing.xcconfig` 和 API Key 不要提交到 Git。


## 文档导航

| 文档 | 内容 |
|------|------|
| [在线用户手册](https://zeycode.cn/snapflow/) | 安装、权限、功能、快捷键和服务配置。 |
| [`README.md`](README.md) | English 项目总览。 |
| [`macos/README.md`](macos/README.md) | macOS 开发、本地运行和打包说明。 |
| [`macos/docs/RELEASE.md`](macos/docs/RELEASE.md) | 版本、打包、签名和 GitHub Releases 流程。 |

## 仓库约定

源码和文档进入 Git，安装包通过 [GitHub Releases](https://github.com/abingtang/snap-flow/releases) 分发。不要提交构建产物、App 包、本地签名配置、凭据或 API Key。

提交说明使用仓库约定的 `类型：简短说明` 格式，例如：

```text
功能：新增截图翻译入口
修复：调整 OCR 结果窗状态
文档：完善项目构建说明
```

提交改动时请保持范围聚焦；功能行为变化后，及时更新对应的用户文档或开发文档。

## 许可证

本项目以 [MIT License](LICENSE) 发布。第三方品牌图标及其它归属见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
