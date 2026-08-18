import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session (可变状态，重识别时原地更新)

enum OCRResultErrorAction: Equatable {
    case retry
    case rescreen
    case openSettings
}

@MainActor
final class OCRResultSession: ObservableObject {
    @Published var image: NSImage
    @Published var cgImage: CGImage
    @Published var lines: [OCRLine]
    @Published var text: String
    @Published var isPinned = false
    @Published var showLeftPanel = true
    @Published var showOCRBoxes = true
    @Published var fontSize: CGFloat = 14
    @Published var statusHint: String?
    @Published var isRecognizing = false
    @Published var errorMessage: String?
    @Published var errorAction: OCRResultErrorAction?
    @Published var languageMode: OCRLanguageMode = .auto
    /// 当前选用的 OCR 服务 ID（与设置默认联动）
    @Published var selectedServiceID: String = OCRServiceEntry.visionID
    /// 当前识别内容是否已收藏（顶栏星号实心态）
    @Published var isContentFavorited = false
    /// >0 时忽略失焦关闭（如弹出 NSOpenPanel）
    var suppressFocusDismissCount = 0
    private(set) var operationID = UUID()

    init(
        image: NSImage,
        cgImage: CGImage,
        lines: [OCRLine],
        text: String,
        selectedServiceID: String = OCRServiceEntry.visionID
    ) {
        self.image = image
        self.cgImage = cgImage
        self.lines = lines
        self.text = text.isEmpty ? OCRTextLayout.makeText(from: lines) : text
        self.selectedServiceID = selectedServiceID
    }

    @discardableResult
    func beginOperation() -> UUID {
        operationID = UUID()
        isRecognizing = true
        errorMessage = nil
        errorAction = nil
        statusHint = nil
        return operationID
    }

    func isCurrent(_ id: UUID) -> Bool {
        operationID == id
    }

    var isEmptyResult: Bool {
        !isRecognizing
            && errorMessage == nil
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func applyRecognition(image: NSImage, cgImage: CGImage, lines: [OCRLine]) {
        self.image = image
        self.cgImage = cgImage
        self.lines = lines
        self.text = OCRTextLayout.makeText(from: lines)
        isRecognizing = false
        errorMessage = nil
        errorAction = nil
        statusHint = nil
    }

    func applyError(_ message: String, action: OCRResultErrorAction) {
        isRecognizing = false
        errorMessage = message
        errorAction = action
        statusHint = nil
    }

    /// OCR 窗内顶栏状态提示（非全局 Toast）
    func flash(_ message: String) {
        statusHint = message
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            if statusHint == message {
                statusHint = nil
            }
        }
    }
}

// MARK: - Actions from host

struct OCRResultActions {
    var onClose: () -> Void = {}
    var onTogglePin: () -> Void = {}
    var onRetry: () -> Void = {}
    var onRescreen: () -> Void = {}
    var onOpenFile: () -> Void = {}
    var onRerecognize: (OCRLanguageMode) -> Void = { _ in }
    var onSelectService: (String) -> Void = { _ in }
    var enabledServices: () -> [OCRServiceEntry] = { [.vision()] }
    /// 打开偏好设置（默认 OCR 服务页）
    var onOpenSettings: () -> Void = {}
    /// 将当前识别结果转为截图翻译窗（不重跑 OCR）
    var onTranslate: () -> Void = {}
    /// 一键收藏（文本 + 图，剪切板同构）
    var onFavorite: () -> Void = {}
    /// 当前内容是否已收藏（驱动实心星）
    var isFavorited: () -> Bool = { false }
}

// MARK: - View

/// 离线文本识别：左图（含 OCR 框）+ 右文（可编辑），对齐参考布局。
struct OCRResultView: View {
    @ObservedObject var session: OCRResultSession
    let actions: OCRResultActions
    /// 用于把字号等 tooltip 显示成用户配置的 chord（可空则用默认）
    var settings: SettingsStore? = nil
    @FocusState private var isTextFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider().opacity(0.35)
            mainSplit
        }
        .resultPanelChrome()
        // 顶部留一点拖拽区手感（borderless 浮窗靠标题栏拖）
        .frame(minWidth: session.showLeftPanel ? 720 : 360, minHeight: 420)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                isTextFocused = true
            }
        }
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            // 钉住整个结果窗
            OCRChromeIconButton(
                symbol: session.isPinned ? "pin.fill" : "pin",
                tooltip: ocrTooltip(
                    session.isPinned ? L10n.string("取消钉住窗口") : L10n.string("钉住窗口"),
                    .ocrTogglePin
                ),
                isAccent: session.isPinned
            ) {
                actions.onTogglePin()
            }

            if session.isRecognizing {
                ProgressView()
                    .controlSize(.small)
            }

            if let hint = session.statusHint {
                ResultChromeStatusHint(text: hint)
            }

            Spacer(minLength: 8)

            // 右上角：服务下拉 + 操作图标
            HStack(spacing: 6) {
                OCRServiceMenu(
                    selectedID: session.selectedServiceID,
                    services: actions.enabledServices(),
                    onSelect: { id in
                        guard id != session.selectedServiceID else { return }
                        actions.onSelectService(id)
                    },
                    onMenuOpenChange: { open in
                        // 打开 popover 时抑制 OCR 浮窗失焦关闭
                        if open {
                            session.suppressFocusDismissCount += 1
                        } else {
                            session.suppressFocusDismissCount = max(0, session.suppressFocusDismissCount - 1)
                        }
                    }
                )

                // 重试 / 翻译 / 显隐左栏 移至右栏底栏，避免与下方操作重复堆在顶栏
                OCRChromeIconButton(symbol: "camera.viewfinder", tooltip: L10n.string("重新截图")) {
                    actions.onRescreen()
                }
                OCRChromeIconButton(symbol: "folder", tooltip: L10n.string("从本地文件识别")) {
                    actions.onOpenFile()
                }
                OCRChromeIconButton(
                    symbol: (session.isContentFavorited || actions.isFavorited())
                        ? "star.fill" : "star",
                    tooltip: (session.isContentFavorited || actions.isFavorited())
                        ? L10n.string("取消收藏") : L10n.string("添加到收藏"),
                    isAccent: session.isContentFavorited || actions.isFavorited()
                ) {
                    actions.onFavorite()
                }
                OCRChromeIconButton(symbol: "gearshape", tooltip: L10n.string("偏好设置")) {
                    actions.onOpenSettings()
                }
            }
            // 无关闭按钮：未钉住时失焦自动关闭；关闭键见配置 ocrClose / ocrCloseCommandW
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: Split

    private var mainSplit: some View {
        HStack(spacing: 0) {
            if session.showLeftPanel {
                leftImagePane
                    .frame(minWidth: 280)
                    .layoutPriority(1)
                Divider().opacity(0.35)
            }
            rightTextPane
                .frame(minWidth: 280)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var leftImagePane: some View {
        VStack(spacing: 0) {
            OCRImageCanvas(
                image: session.image,
                pixelSize: CGSize(width: session.cgImage.width, height: session.cgImage.height),
                lines: session.lines,
                showBoxes: session.showOCRBoxes
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.25))

            // 图片下方：显隐 OCR 识别框
            HStack(spacing: 8) {
                OCRChromeTextButton(
                    title: session.showOCRBoxes ? L10n.string("隐藏识别框") : L10n.string("显示识别框"),
                    symbol: session.showOCRBoxes ? "eye.slash" : "eye",
                    tooltip: session.showOCRBoxes ? L10n.string("隐藏 OCR 识别框") : L10n.string("显示 OCR 识别框")
                ) {
                    session.showOCRBoxes.toggle()
                }

                Spacer()

                Text(String(format: L10n.string("%lld 块"), session.lines.count))
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textTertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.textPrimary.opacity(0.04))
        }
    }

    private var rightTextPane: some View {
        VStack(spacing: 0) {
            if let errorMessage = session.errorMessage {
                errorBanner(message: errorMessage)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $session.text)
                    .font(.system(size: session.fontSize))
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .focused($isTextFocused)
                    .disabled(session.isRecognizing)

                if session.isEmptyResult {
                    emptyState
                } else if session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.isRecognizing ? L10n.string("正在识别…") : L10n.string("未识别到文字"))
                        .font(.system(size: session.fontSize))
                        .foregroundStyle(AppTheme.textTertiary)
                        .padding(18)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.surface.opacity(0.55))
            // 点进右侧即可编辑
            .contentShape(Rectangle())
            .onTapGesture { isTextFocused = true }

            // 文本框下方：复制 + 重试/翻译/显隐左栏 + 字号（± 与 LocalShortcut ⌘+/⌘- 同范围 10...36、步长 1）
            HStack(spacing: 8) {
                OCRChromeIconButton(symbol: "doc.on.doc", tooltip: L10n.string("复制全部文本")) {
                    copyAll()
                }
                OCRChromeIconButton(
                    symbol: "arrow.clockwise",
                    tooltip: ocrTooltip(L10n.string("重试识别（对当前图）"), .ocrRetry)
                ) {
                    actions.onRetry()
                }
                OCRChromeIconButton(
                    symbol: "globe",
                    tooltip: L10n.string("翻译（打开截图翻译窗，不重新识别）")
                ) {
                    actions.onTranslate()
                }
                OCRChromeIconButton(
                    symbol: session.showLeftPanel
                        ? "rectangle.lefthalf.filled"
                        : "rectangle.leadinghalf.inset.filled",
                    tooltip: session.showLeftPanel ? L10n.string("隐藏左侧图片") : L10n.string("显示左侧图片"),
                    isAccent: !session.showLeftPanel
                ) {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        session.showLeftPanel.toggle()
                    }
                }

                Spacer(minLength: 0)

                // 不用 textformat.size.smaller/larger：中文环境下会显示成「小」「大」文字
                HStack(spacing: 4) {
                    OCRChromeIconButton(
                        symbol: "minus",
                        tooltip: ocrTooltip(L10n.string("减小字号"), .ocrFontSmaller),
                        isDisabled: session.fontSize <= 10
                    ) {
                        session.fontSize = max(session.fontSize - 1, 10)
                    }

                    Text(String(format: L10n.string("字号 %lld"), Int(session.fontSize)))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(minWidth: 44)
                        .help(ocrFontSizeShortcutHelp)

                    OCRChromeIconButton(
                        symbol: "plus",
                        tooltip: ocrTooltip(L10n.string("增大字号"), .ocrFontLarger),
                        isDisabled: session.fontSize >= 36
                    ) {
                        session.fontSize = min(session.fontSize + 1, 36)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(AppTheme.textPrimary.opacity(0.04))
        }
    }

    private func errorBanner(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(AppTheme.warning)

            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.string("识别失败"))
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(errorActionTitle) {
                performErrorAction()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(AppTheme.warning.opacity(0.10))
    }

    private var errorActionTitle: String {
        switch session.errorAction {
        case .rescreen:
            return L10n.string("重新截图")
        case .openSettings:
            return L10n.string("打开 OCR 设置")
        case .retry, .none:
            return L10n.string("重试识别")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.viewfinder")
                .font(.system(size: 24))
                .foregroundStyle(AppTheme.textTertiary)
            Text(L10n.string("未识别到文字"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 8) {
                Button(L10n.string("重新识别")) {
                    actions.onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.string("重新截图")) {
                    actions.onRescreen()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(20)
    }

    private func performErrorAction() {
        switch session.errorAction {
        case .rescreen:
            actions.onRescreen()
        case .openSettings:
            actions.onOpenSettings()
        case .retry, .none:
            actions.onRetry()
        }
    }

    // MARK: Helpers

    private var ocrFontSizeShortcutHelp: String {
        let larger = ocrLabel(.ocrFontLarger)
        let smaller = ocrLabel(.ocrFontSmaller)
        return String(format: L10n.string("可用 %@ / %@ 调整字号"), larger, smaller)
    }

    private func ocrLabel(_ action: LocalShortcutAction) -> String {
        if let settings {
            return settings.shortcutLabel(for: action)
        }
        return ShortcutDisplay.label(chord: action.defaultChord)
    }

    private func ocrTooltip(_ title: String, _ action: LocalShortcutAction) -> String {
        if let settings {
            return settings.tooltip(title, action: action)
        }
        return ShortcutDisplay.tooltip(title, chord: action.defaultChord)
    }

    private func copyAll() {
        let value = session.text
        guard !value.isEmpty else {
            session.flash(L10n.string("没有可复制的内容"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        session.flash(L10n.string("已复制"))
    }
}

// MARK: - Chrome controls（hover / 手型光标）

/// 右上角 OCR 服务下拉：列出已启用服务，切换即改全局默认并重识别。
struct OCRServiceMenu: View {
    let selectedID: String
    let services: [OCRServiceEntry]
    var onSelect: (String) -> Void
    var onMenuOpenChange: (Bool) -> Void = { _ in }

    @State private var isOpen = false
    @State private var isHovered = false

    private var selectedTitle: String {
        services.first(where: { $0.id == selectedID })?.displayName
            ?? OCRServiceKind.vision.displayName
    }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            HStack(spacing: 3) {
                Text(selectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textPrimary.opacity(0.92))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered || isOpen ? AppTheme.textPrimary.opacity(0.10) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(L10n.string("选择 OCR 服务（将设为默认）"))
        .onHover { hovering in
            isHovered = hovering
            updateHandCursor(hovering)
        }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.15), value: isOpen)
        .onChange(of: isOpen) { _, open in
            onMenuOpenChange(open)
        }
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            OCRServiceMenuPanel(
                selectedID: selectedID,
                services: services,
                onSelect: { id in
                    onSelect(id)
                    isOpen = false
                }
            )
            .frame(width: 236)
            .padding(2)
        }
        .accessibilityLabel(String(format: L10n.string("OCR 服务，当前：%@"), selectedTitle))
    }
}

struct OCRServiceMenuPanel: View {
    let selectedID: String
    let services: [OCRServiceEntry]
    var onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string("文本识别"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(services) { entry in
                OCRServiceMenuRow(
                    title: entry.displayName,
                    kind: entry.kind,
                    isSelected: selectedID == entry.id,
                    trailingBadge: entry.badgeTitle
                ) {
                    onSelect(entry.id)
                }
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfaceMuted)
        )
    }
}

struct OCRServiceMenuRow: View {
    let title: String
    let kind: OCRServiceKind
    let isSelected: Bool
    let trailingBadge: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.textPrimary)
                    .frame(width: 14)
                    .opacity(isSelected ? 1 : 0)

                OCRServiceIconView(kind: kind, size: 22)

                Text(title)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(AppTheme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let trailingBadge {
                    Text(trailingBadge)
                        .font(.system(size: 11))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? AppTheme.textPrimary.opacity(0.08) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(OCRServiceMenuRowButtonStyle())
    }
}

struct OCRServiceMenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        OCRServiceMenuRowButtonBody(configuration: configuration)
    }
}

struct OCRServiceMenuRowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? AppTheme.textPrimary.opacity(0.12)
                            : (isHovered ? AppTheme.textPrimary.opacity(0.08) : Color.clear)
                    )
            )
            .onHover { hovering in
                isHovered = hovering
                updateHandCursor(hovering)
            }
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// 共用 chrome：`Features/Shared/ResultChromeControls.swift`
// `updateHandCursor`：`App/PointerCursor.swift`

// MARK: - Image + boxes

/// 原图 + OCR 框画布（OCR 窗 / 截图翻译窗复用）
struct OCRImageCanvas: View {
    enum ContentAlignment {
        /// 居中（OCR 结果窗默认）
        case center
        /// 顶对齐水平居中（截图翻译左栏）
        case top
    }

    let image: NSImage
    /// 与 OCR boundingBox 同一像素坐标系
    let pixelSize: CGSize
    let lines: [OCRLine]
    let showBoxes: Bool
    var contentAlignment: ContentAlignment = .center

    var body: some View {
        GeometryReader { geo in
            let fit = fittedRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                Color.clear
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: fit.width, height: fit.height)
                    .position(x: fit.midX, y: fit.midY)

                if showBoxes, pixelSize.width > 0, pixelSize.height > 0 {
                    ForEach(lines) { line in
                        let box = displayRect(for: line.boundingBox, fit: fit)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .stroke(AppTheme.accent.opacity(0.95), lineWidth: 1.2)
                            .background(
                                RoundedRectangle(cornerRadius: 2, style: .continuous)
                                    .fill(AppTheme.accent.opacity(0.12))
                            )
                            .frame(width: max(box.width, 2), height: max(box.height, 2))
                            .position(x: box.midX, y: box.midY)
                    }
                }
            }
        }
        .padding(8)
    }

    private func fittedRect(in container: CGSize) -> CGRect {
        let iw = max(pixelSize.width, 1)
        let ih = max(pixelSize.height, 1)
        let scale = min(container.width / iw, container.height / ih)
        let w = iw * scale
        let h = ih * scale
        let y: CGFloat = switch contentAlignment {
        case .center: (container.height - h) / 2
        case .top: 0
        }
        return CGRect(
            x: (container.width - w) / 2,
            y: y,
            width: w,
            height: h
        )
    }

    /// Vision/OCR 像素坐标：原点左上、y 向下 → 视图坐标（y 向下，与 SwiftUI 一致）
    private func displayRect(for pixelBox: CGRect, fit: CGRect) -> CGRect {
        let sx = fit.width / max(pixelSize.width, 1)
        let sy = fit.height / max(pixelSize.height, 1)
        return CGRect(
            x: fit.minX + pixelBox.minX * sx,
            y: fit.minY + pixelBox.minY * sy,
            width: pixelBox.width * sx,
            height: pixelBox.height * sy
        )
    }
}

// MARK: - 按图布局拼文本

enum OCRTextLayout {
    /// 按行排序结果拼成可读文本：同行用空格分隔，换行按图上纵向位置。
    static func makeText(from lines: [OCRLine], sameRowThreshold: CGFloat = 12) -> String {
        guard !lines.isEmpty else { return "" }
        var sorted = lines
        sorted.sort {
            if abs($0.boundingBox.minY - $1.boundingBox.minY) < sameRowThreshold {
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            return $0.boundingBox.minY < $1.boundingBox.minY
        }

        var parts: [String] = []
        var row: [OCRLine] = []
        var rowY: CGFloat?

        func flushRow() {
            guard !row.isEmpty else { return }
            row.sort { $0.boundingBox.minX < $1.boundingBox.minX }
            var lineText = ""
            var prevMaxX: CGFloat?
            for item in row {
                if let prev = prevMaxX {
                    let gap = item.boundingBox.minX - prev
                    // 较大空隙用双空格区分文本块
                    lineText += gap > 36 ? "  " : " "
                }
                lineText += item.text
                prevMaxX = item.boundingBox.maxX
            }
            parts.append(lineText)
            row.removeAll(keepingCapacity: true)
        }

        for line in sorted {
            if let y = rowY, abs(line.boundingBox.minY - y) >= sameRowThreshold {
                flushRow()
                rowY = line.boundingBox.minY
            } else if rowY == nil {
                rowY = line.boundingBox.minY
            }
            row.append(line)
        }
        flushRow()
        return parts.joined(separator: "\n")
    }
}

// MARK: - Modes

enum OCRLanguageMode: String, CaseIterable, Identifiable, Sendable {
    case auto
    case zhHans
    case zhHant
    case en
    case ja
    case ko

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: L10n.string("自动检测")
        case .zhHans: L10n.string("简体中文")
        case .zhHant: L10n.string("繁體中文")
        case .en: "English"
        case .ja: L10n.string("日本語")
        case .ko: "한국어"
        }
    }

    var visionLanguages: [String]? {
        switch self {
        case .auto: nil
        case .zhHans: ["zh-Hans", "en-US"]
        case .zhHant: ["zh-Hant", "en-US"]
        case .en: ["en-US"]
        case .ja: ["ja-JP", "en-US"]
        case .ko: ["ko-KR", "en-US"]
        }
    }
}

#Preview {
    Text("OCRResultView — run app to preview with real capture")
        .frame(width: 400, height: 200)
}
