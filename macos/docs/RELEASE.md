# SnapFlow 发布与版本管理（方案 A）

> **原则**：源代码只进 Git；安装包（`.app` / `.zip` / `.dmg` / `.pkg`）只进 **GitHub Releases**。  
> 本地构建输出目录为 `dist/`，已由根目录 `.gitignore` 忽略，**禁止提交**。

**当前版本**：**0.0.4**（与工程 `MARKETING_VERSION` 同步；用下方 `bump-version` 改）  
**仓库**：https://github.com/abingtang/abingtang-snap-flow  

---

## 1. 为什么这样分发

| 做法 | 结果 |
|------|------|
| 把 `.app` / zip 提交进主仓库 | 历史膨胀、clone 变慢、二进制难合并 |
| 源码 Git + 安装包 Releases（推荐） | 仓库干净；用户只打开 Releases 下载 |

不使用 Git LFS 存放安装包（除非未来有私有归档硬需求）。

---

## 2. 版本号约定

采用语义化版本 **`MAJOR.MINOR.PATCH`**（下文记作 `X.Y.Z`）：

| 字段 | 含义 | 0.0.x 阶段说明 |
|------|------|----------------|
| `MAJOR` | 不兼容大改 | 预发布阶段保持 `0` |
| `MINOR` | 功能增量 | 功能面明显扩大时递增 |
| `PATCH` | 修复与小改 | 默认递增位 |

### 单一事实来源（SSOT）

| 用途 | 权威位置 | 说明 |
|------|----------|------|
| **App / tag / 安装包** | `macos/SnapFlow.xcodeproj` → `MARKETING_VERSION` | 打包脚本读取；Git tag 为 `vX.Y.Z` |
| **Build 号** | 同工程 `CURRENT_PROJECT_VERSION` | 每次公开发版可递增 |
| **用户文档「当前对应版本」** | `docs-site/package.json` → `version` | 页脚由 VitePress 注入，无需手改多处 Markdown |
| **Info.plist** | `$(MARKETING_VERSION)` / `$(CURRENT_PROJECT_VERSION)` | 构建时展开，勿再手写数字 |

### 一键改版本（推荐）

完整参数与边界说明见仓库根 **[`scripts/README.md`](../../scripts/README.md)**。

在**仓库根目录**：

```bash
# App + 文档线 + README / PROGRESS / RELEASE 顶部指针一并改到 X.Y.Z
./scripts/bump-version.sh 0.0.5

# 仅 App / 仅文档
./scripts/bump-version.sh 0.0.5 --app-only
./scripts/bump-version.sh 0.0.5 --docs-only

# 指定 build 号（默认取 PATCH）
./scripts/bump-version.sh 0.0.5 --build 12

# 校验指针是否与 SSOT 一致（文档线可略超前 App，仅警告）
./scripts/check-version-sync.sh
./scripts/check-version-sync.sh --strict-same   # 要求 Docs == App
```

脚本**不会**改写 changelog 历史章节、PROGRESS 变更日志旧行、FAQ「某版本起…」等历史叙述。  
升用户可见版本时，请**人工**在 `docs-site/changelog.md` 与 `en/changelog.md` **顶部追加**新章节。

### 工程与产物命名

| 位置 | 规则 |
|------|------|
| Git tag | `vX.Y.Z`（与 MARKETING_VERSION 一致） |
| 安装包文件名 | `SnapFlow-X.Y.Z-arm64.zip` / `.dmg` |
| 设置 → 关于 | 从 Bundle 读取 |

镜像指针（由 `bump-version` 维护，不必手改）：根目录 README badge、`macos/README.md` 版本表、`PROGRESS.md` / 本文件顶部「当前版本」。

---

## 3. 分支与 Tag

| 引用 | 用途 |
|------|------|
| `develop` | 日常开发与功能合并 |
| `main` | 相对稳定、可打 release tag 的线 |
| `vX.Y.Z`（annotated tag） | 与一次 GitHub Release **一一对应**，发布后勿改写 tag |

建议流程：

```text
develop 功能完成 → 合并到 main → ./scripts/bump-version.sh X.Y.Z → 写 changelog
  → 打 tag → 打包 → 创建 GitHub Release
```

---

## 4. 本机打包

### 4.1 一键脚本（推荐）

在 `macos/` 目录：

```bash
# 使用工程内 MARKETING_VERSION
./scripts/package-release.sh

# 或显式指定版本与架构后缀
VERSION=X.Y.Z ARCH=arm64 ./scripts/package-release.sh
```

默认行为：

1. `xcodebuild -scheme SnapFlow -configuration Release` 构建  
2. 将 `SnapFlow.app` 复制到 `dist/SnapFlow.app`  
3. 生成 `dist/SnapFlow-${VERSION}-${ARCH}.zip`  
4. 生成 **拖拽安装** `dist/SnapFlow-${VERSION}-${ARCH}.dmg`  
5. 打印上传 Releases 的提示  

环境变量：

| 变量 | 作用 |
|------|------|
| `SKIP_DMG=1` | 不生成 DMG，只打 zip |
| `SKIP_ZIP=1` | 不生成 zip，只打 DMG |
| `VERSION` / `ARCH` | 覆盖版本号与架构后缀 |

DMG 制作：若本机已安装 [`create-dmg`](https://github.com/create-dmg/create-dmg)（`brew install create-dmg`）则优先使用；否则用系统 `hdiutil` + Finder 布局脚本。资源在 `scripts/dmg-resources/background.png`。

**产物只在本机 `dist/`，不要 `git add`。**

### 4.2 手动等价命令（参考）

```bash
xcodebuild \
  -scheme SnapFlow \
  -configuration Release \
  -derivedDataPath build/SnapFlowReleaseDerivedData \
  build

APP=$(find build/SnapFlowReleaseDerivedData/Build/Products/Release -name 'SnapFlow.app' -maxdepth 1 | head -1)
mkdir -p dist
rm -rf dist/SnapFlow.app
cp -R "$APP" dist/SnapFlow.app
# 将 X.Y.Z 换成当前 MARKETING_VERSION
ditto -c -k --keepParent dist/SnapFlow.app dist/SnapFlow-X.Y.Z-arm64.zip
# DMG 请直接跑 package-release.sh
```

### 4.3 签名与公证（对外分发时）

| 阶段 | 说明 |
|------|------|
| 内测 / 自用 | Development 签名或本地 ad-hoc 即可；他人机器可能需「右键打开」 |
| 公开下载 | **Developer ID Application** 签名 → `notarytool` 公证 → `stapler staple` |
| 安装体验 | 脚本默认产出拖拽式 `.dmg` |

证书、App 专用密码、Team ID **不得**提交进仓库。本地可用被 ignore 的 `Configurations/Signing.xcconfig`。

---

## 5. 创建 GitHub Release（用户下载入口）

### 5.1 打 tag 并推送

在**已包含目标代码的提交**上（通常为 `main`）：

```bash
git checkout main
git pull origin main

# 确认 MARKETING_VERSION 已是 X.Y.Z（./scripts/check-version-sync.sh）
git tag -a vX.Y.Z -m "SnapFlow X.Y.Z"
git push origin main
git push origin vX.Y.Z
```

### 5.2 在网页上发布

1. 打开 https://github.com/abingtang/abingtang-snap-flow/releases/new  
2. **Choose a tag**：`vX.Y.Z`  
3. **Release title**：`SnapFlow X.Y.Z`  
4. **Describe**：系统要求、本版要点、已知限制、权限说明（可用下方模板）  
5. **Attach binaries**：上传 `dist/SnapFlow-X.Y.Z-arm64.dmg`（推荐）与可选 zip  
6. 若仍为预览：勾选 **Set as a pre-release**  
7. Publish release  

用户入口：

- 最新：https://github.com/abingtang/abingtang-snap-flow/releases/latest  
- 列表：https://github.com/abingtang/abingtang-snap-flow/releases  

### 5.3 Release 说明模板

```markdown
## SnapFlow X.Y.Z

预发布构建。源码在仓库；本页仅提供安装包。

### 系统要求
- macOS 15.0+
- Apple Silicon（arm64）包

### 安装
1. 下载下方 `SnapFlow-X.Y.Z-arm64.dmg`（推荐）
2. 打开 DMG，将 **SnapFlow** 拖到右侧 **应用程序** 文件夹
3. 首次使用授权「屏幕录制」；划词翻译另需「辅助功能」

也可下载 `.zip` 解压后手动移入「应用程序」。

### 本版包含
- （填写要点）

### 已知限制
- 未做完整公证时可能提示无法验证开发者
- 云服务需自备 Key
- 详见仓库 README 与 macos/docs/PROGRESS.md
```

---

## 6. 什么可以提交、什么不能

### 可以进 Git

- `SnapFlow/`、`SnapFlowTests/`、`SnapFlow.xcodeproj/`
- `docs/`、`scripts/`、`README.md`、`AGENTS.md`、`Configurations/*.example`
- 资源图（`Assets`、`icon-variants` 等源文件）

### 禁止进 Git

- `dist/`、`build/`、`DerivedData/`
- `*.app`、`*.dmg`、`*.pkg`、发行用大体积 zip
- `Configurations/Signing.xcconfig`（含 Team 的本地文件）
- 证书、私钥、API Key、公证凭据

若误跟踪过 `dist/`：

```bash
git rm -r --cached dist/
# 确认 .gitignore 已包含 dist/
git commit -m "维护：停止跟踪 dist/ 下的发布产物"
```

---

## 7. 自动化（后续）

在证书与 Secrets 就绪后，可用 GitHub Actions：

```text
push tag v* → macOS runner → Release 构建 → 签名 → 公证 → 上传 Release Asset
```

当前阶段以 **本机 `package-release.sh` + 手动上传** 为准。

---

## 8. 发版检查清单

- [ ] `./scripts/bump-version.sh X.Y.Z` 已执行（或确认 MARKETING_VERSION 正确）
- [ ] `./scripts/check-version-sync.sh` 通过
- [ ] `docs-site/changelog.md`（及 en）已**追加**本版章节
- [ ] `develop` 变更已合并到拟发版分支
- [ ] `macos/docs/PROGRESS.md` 变更日志已追加
- [ ] `cd macos && ./scripts/package-release.sh` 成功，zip / dmg 可启动
- [ ] 未将 `dist/` 加入 git
- [ ] 已推送 annotated tag `vX.Y.Z`
- [ ] GitHub Release 已挂上 dmg（及可选 zip），并写清权限与系统要求
- [ ] （公开版）Developer ID 签名 + 公证 + staple

---

## 9. 相关文档

| 文档 | 内容 |
|------|------|
| [../README.md](../README.md) | 用户下载入口 + 开发者构建 |
| [PROGRESS.md](./PROGRESS.md) | 功能进度与变更日志 |
| [PLAN.md](./PLAN.md) | 架构与阶段规划 |
| [../../scripts/README.md](../../scripts/README.md) | 版本脚本用法索引 |
| 仓库根 `scripts/bump-version.sh` | 一键同步版本指针 |
| 仓库根 `scripts/check-version-sync.sh` | 校验 SSOT 与镜像 |
| `Configurations/Signing.xcconfig.example` | 本地 Team 配置示例 |
