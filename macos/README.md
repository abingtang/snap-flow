<!-- version-pointer: kept in sync by scripts/bump-version.sh -->
<p align="center">
  <img src="icon-variants/app-icon.png" alt="SnapFlow app icon" width="128">
</p>

<h1 align="center">SnapFlow macOS</h1>

<p align="center">
  A native macOS menu bar utility for capturing, reading, translating, and organizing on-screen content.
</p>

<p align="center">
  <a href="../README.md">Project README</a> ·
  <a href="https://zeycode.cn/snapflow/">User Guide</a> ·
  <a href="https://github.com/abingtang/snap-flow/releases/latest">Download</a> ·
  <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img alt="macOS 15+" src="https://img.shields.io/badge/macOS-15%2B-111827?logo=apple&logoColor=white">
  <img alt="Swift 6" src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white">
  <img alt="Version 0.0.5" src="https://img.shields.io/badge/version-0.0.5-orange">
</p>

SnapFlow macOS is built with Swift 6, SwiftUI, AppKit, ScreenCaptureKit, Vision, and Translation. The app keeps the capture-to-result flow close to the menu bar while storing useful results locally for later reuse.

## At a glance

| Item | Current value |
|------|---------------|
| Version | **0.0.5** |
| System requirement | macOS 15.0 or later |
| Technology | Swift 6 · SwiftUI + AppKit · ScreenCaptureKit · Vision · Translation |
| Published architecture | Apple Silicon (`arm64`) |
| Distribution | [GitHub Releases](https://github.com/abingtang/snap-flow/releases) |

## Download and install

Download the latest arm64 ZIP or DMG from [GitHub Releases](https://github.com/abingtang/snap-flow/releases/latest), then move `SnapFlow.app` to `Applications`.

Intel Macs can build the app from source. System translation availability follows the capabilities of the installed macOS version.

An unsigned or unnotarized build may require a right-click **Open** action in Finder or approval in **System Settings → Privacy & Security**.

## Features

| Feature | Description |
|---------|-------------|
| Region capture | Freeze the screen, select a region or window, use the magnifier, annotate, copy, save, or pin the result. |
| Scrolling capture | Capture a manually scrolled area and stitch it into a long image with preview, save, copy, and pin actions. |
| Pinboard | Keep screenshots on screen and copy, save, favorite, or OCR them when needed. |
| OCR | Use on-device Vision or configure Baidu, Youdao, Tencent, Volcengine, Google, and custom HTTP services. |
| Translation | Translate selected text or screenshots with Apple Translation and configured cloud or model services. |
| Clipboard history | Search text, rich text, images, and files; pin, favorite, restore, and paste entries when needed. |
| History and favorites | Search and restore screenshots, OCR results, translations, and saved content from one place. |

## Recommended shortcuts

Shortcuts can be changed in **Settings**. Use **Restore Recommended Feature Shortcuts** to return to the defaults.

| Action | Shortcut |
|--------|----------|
| Region capture | **⌃⌥A** |
| Pin to screen | ⌃⌥P |
| Region OCR | ⌥⌘O |
| Screenshot translation | ⌥⌘T |
| Selection translation | ⌥⌘S |
| Clipboard history | ⌥⌘V |

After selecting a region, the toolbar provides annotation, scrolling capture, OCR, screenshot translation, and original-image translation actions. In-window shortcuts are listed in the corresponding Settings section.

## Permissions and services

| Permission | Used for |
|------------|----------|
| Screen Recording | Region capture, scrolling capture, OCR, and screenshot translation. |
| Accessibility | Reading selected text from other apps for selection translation. |

Manage system translation language packs in **System Settings → General → Language & Region → Translation Languages**. Cloud OCR and translation services require API keys configured in the app.

Keys are stored in local settings and are not uploaded to a SnapFlow server. SnapFlow does not provide a backend account system.

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

For a local signing configuration, use [`Configurations/Signing.xcconfig.example`](Configurations/Signing.xcconfig.example). Keep the local `Signing.xcconfig` file and API keys out of Git.

### Debug build from the command line

Run this from the repository root:

```bash
xcodebuild \
  -project macos/SnapFlow.xcodeproj \
  -scheme SnapFlow \
  -configuration Debug \
  build
```

### Package a release build

Run the packaging script from the `macos/` directory:

```bash
cd macos
./scripts/package-release.sh
```

The script reads `MARKETING_VERSION` from the Xcode project and writes the App and installer archives to `macos/dist/`. Packaging, signing, notarization, tags, and GitHub Releases are documented in [`docs/RELEASE.md`](docs/RELEASE.md).

## Documentation

| Document | Contents |
|----------|----------|
| [`../README.md`](../README.md) | English project overview and common build entry points. |
| [`../README.zh-CN.md`](../README.zh-CN.md) | Simplified Chinese project overview. |
| [Online user guide](https://zeycode.cn/snapflow/) | Installation, permissions, features, shortcuts, and service setup. |
| [`docs/RELEASE.md`](docs/RELEASE.md) | Versioning, packaging, signing, and GitHub Releases. |

## Source layout

| Path | Contents |
|------|----------|
| `SnapFlow/` | App entry points, features, services, persistence, and AppKit bridges. |
| `SnapFlowTests/` | Unit and regression tests. |
| `SnapFlow.xcodeproj/` | Xcode project and shared scheme. |
| `Configurations/` | Signing configuration example; local signing files stay ignored. |
| `docs/` | Development and release documentation. |
| `scripts/` | Packaging, icon, and local build scripts. |

## Repository conventions

Source code and documentation belong in Git. Installers belong in [GitHub Releases](https://github.com/abingtang/snap-flow/releases).

Do not commit `build/`, `dist/`, app bundles, installer archives, signing configuration, credentials, or API keys.

Commit messages use the repository convention `Type: short description`, for example:

```text
Feature: improve the OCR result window
Fix: adjust the capture toolbar layout
Docs: improve the macOS build notes
```
