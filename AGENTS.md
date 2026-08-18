# SnapFlow 协作规则

本仓库包含 SnapFlow 的源码、公开文档和发布资料。规则只描述本仓库内可验证的内容。

## 版本与 Tag

每次创建或推送 `vX.Y.Z` Tag 前，必须先同步项目版本号和当前版本文档：

- `macos/SnapFlow.xcodeproj/project.pbxproj` 中的 `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`
- 根目录及 `macos/` 下的中英文 README 版本标识
- `macos/docs/RELEASE.md` 和本次发布对应的变更说明

Tag 必须指向包含这些同步内容的发布提交。至少执行：

```bash
xcodebuild -project macos/SnapFlow.xcodeproj -scheme SnapFlow -configuration Debug build
git diff --check
```

## 提交说明

提交说明只写本次实际改动内容，保持简洁、聚焦，不添加仓库背景、过程性说明或其他与改动无关的信息。沿用仓库现有的 `类型：简短说明` 格式，例如：

```text
功能：新增检查更新入口
修复：调整 OCR 结果窗口状态
文档：完善 macOS 发布说明
```

## 发布文件

源码和文档进入 Git；`.app`、`.zip`、`.dmg` 等安装包通过 GitHub Releases 分发，不提交到仓库。
