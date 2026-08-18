<!-- version-pointer: kept in sync by scripts/bump-version.sh -->
<p align="center">
  <img src="macos/icon-variants/app-icon.png" alt="SnapFlow app icon" width="144">
</p>

<h1 align="center">SnapFlow</h1>

<p align="center">
  A native macOS menu bar utility for capturing, reading, translating, and organizing on-screen content.
</p>

<p align="center">
  <a href="https://zeycode.cn/snapflow/">User Guide</a> ·
  <a href="https://github.com/abingtang/snap-flow/releases/latest">Download</a> ·
  <a href="https://github.com/abingtang/snap-flow">GitHub</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Version 0.0.4" src="https://img.shields.io/badge/version-0.0.4-orange">
</p>

SnapFlow is a macOS-first desktop utility for turning screen content into useful, reusable information. Capture a region, recognize text, translate it, annotate the result, and keep what matters for later.

## Features

| Feature | Description |
|---------|-------------|
| Region capture | Freeze the screen, select a region or window, use the magnifier, annotate, copy, save, or pin the result. |
| Scrolling capture | Capture a manually scrolled area and stitch it into a long image. |
| Pinboard | Keep screenshots on screen and copy, save, favorite, or OCR them when needed. |
| OCR | Use on-device Vision or configure Baidu, Youdao, Tencent, Volcengine, Google, and custom HTTP services. |
| Translation | Translate selected text or screenshots with Apple Translation and configured cloud or model services. |
| History and favorites | Search, restore, and favorite screenshots, OCR results, translations, and clipboard entries. |

## Download

Most users should download the latest package from [GitHub Releases](https://github.com/abingtang/snap-flow/releases/latest). Open the ZIP or DMG and move `SnapFlow.app` to `Applications`.

The published package targets Apple Silicon (`arm64`) and requires macOS 15.0 or later. Intel Macs can build the app from source.

An unsigned or unnotarized build may require a right-click **Open** action in Finder or approval in **System Settings → Privacy & Security**.

## Permissions and services

| Permission | Used for |
|------------|----------|
| Screen Recording | Region capture, OCR, screenshot translation, and scrolling capture. |
| Accessibility | Reading selected text from other apps for selection translation. |

On-device Vision OCR and system translation can be used without a cloud account.

Cloud OCR and translation services require API keys configured in the app. Keys are stored in local settings; SnapFlow does not provide a backend account system.

## Build from source

### Requirements

- macOS 15.0 or later
- Xcode 16 or later
- Swift 6
- An Apple Development Team for local signing and permission testing

### Open the project

```bash
git clone https://github.com/abingtang/snap-flow.git
cd snap-flow
open macos/SnapFlow.xcodeproj
```

Select the **SnapFlow** target in Xcode, configure **Signing & Capabilities**, and run with `⌘R`.

### Debug build from the command line

Run this from the repository root:

```bash
xcodebuild \
  -project macos/SnapFlow.xcodeproj \
  -scheme SnapFlow \
  -configuration Debug \
  build
```

For a local signing configuration, use [`macos/Configurations/Signing.xcconfig.example`](macos/Configurations/Signing.xcconfig.example). Keep the local `Signing.xcconfig` file and API keys out of Git.


## Documentation

| Document | Contents |
|----------|----------|
| [Online user guide](https://zeycode.cn/snapflow/) | Installation, permissions, features, shortcuts, and service setup. |
| [`README.zh-CN.md`](README.zh-CN.md) | Simplified Chinese project overview. |
| [`macos/README.md`](macos/README.md) | macOS development, local running, and packaging notes. |
| [`macos/docs/RELEASE.md`](macos/docs/RELEASE.md) | Versioning, packaging, signing, and GitHub Releases. |

## Repository conventions

Source code and documentation belong in Git. Installers belong in [GitHub Releases](https://github.com/abingtang/snap-flow/releases). Do not commit build products, app bundles, signing configuration, credentials, or API keys.

Commit messages use the repository convention `Type: short description`, for example:

```text
Feature: add screenshot translation entry
Fix: adjust OCR result window state
Docs: improve project build notes
```

Contributions should keep changes focused and update the relevant user or development documentation when behavior changes.

## License

This project is released under the [MIT License](LICENSE). Third-party brand icons and other attributions are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
