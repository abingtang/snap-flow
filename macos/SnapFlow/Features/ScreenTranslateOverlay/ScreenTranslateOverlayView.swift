import AppKit
import Observation
import SwiftUI

// MARK: - Session

/// 原图翻译 / 原图 OCR 叠层模式。
enum ScreenTranslateOverlayMode: String, Sendable {
    /// 识别后自动翻译，默认叠译文
    case imageTranslate
    /// 只识别，默认叠原文，可一键翻译
    case imageOCR
}

enum ScreenTranslateOverlayErrorAction: Equatable {
    case retryOCR
    case retranslate
    case openOCRSettings
    case openTranslationSettings
}

/// 截图翻译浮层的可变会话。OCR / 翻译重试均在同一个浮层中原地更新。
@MainActor
@Observable
final class ScreenTranslateOverlaySession {
    let image: CGImage
    let imageSize: CGSize
    let selection: CaptureRegion
    /// 进入叠层时的模式（OCR 与翻译共用 UI，行为略有差异）
    let mode: ScreenTranslateOverlayMode
    var lines: [OverlayLine]
    var ocrServiceID: String
    var translationServiceID: String
    var sourceLanguage: String
    var targetLanguage: String
    /// 为 true 时隐藏叠字，露出下层原图（对齐「显示原图」）
    var isShowingOriginal = false
    var isProcessing = false
    /// 处理中文案：识别中… / 翻译中…
    var processingMessage = L10n.string("翻译中…")
    var emptyMessage: String?
    var errorMessage: String?
    var errorAction: ScreenTranslateOverlayErrorAction?
    var statusMessage: String?
    var isClosed = false
    /// 叠字相对「按识别框自适应」字号的缩放；1.0 为默认适配
    var fontScale: CGFloat = 1.0
    private(set) var operationID = UUID()

    static let fontScaleMin: CGFloat = 0.6
    static let fontScaleMax: CGFloat = 2.0
    static let fontScaleStep: CGFloat = 0.1

    init(
        image: CGImage,
        imageSize: CGSize,
        selection: CaptureRegion,
        lines: [OverlayLine],
        ocrServiceID: String,
        translationServiceID: String,
        sourceLanguage: String,
        targetLanguage: String,
        mode: ScreenTranslateOverlayMode = .imageTranslate
    ) {
        self.image = image
        self.imageSize = imageSize
        self.selection = selection
        self.mode = mode
        self.lines = lines
        self.ocrServiceID = ocrServiceID
        self.translationServiceID = translationServiceID
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        // 默认叠字：原图 OCR 叠识别原文，原图翻译叠译文（识别后自动译）
        self.isShowingOriginal = false
        self.processingMessage = mode == .imageOCR ? L10n.string("识别中…") : L10n.string("翻译中…")
        self.fontScale = 1.0
    }

    var canDecreaseFontScale: Bool { fontScale > Self.fontScaleMin + 0.001 }
    var canIncreaseFontScale: Bool { fontScale < Self.fontScaleMax - 0.001 }

    /// 调整叠字缩放（相对自动适配字号）
    func adjustFontScale(by delta: CGFloat) {
        let stepped = (fontScale / Self.fontScaleStep).rounded() * Self.fontScaleStep + delta
        let next = min(Self.fontScaleMax, max(Self.fontScaleMin, stepped))
        guard abs(next - fontScale) > 0.001 else { return }
        fontScale = (next * 10).rounded() / 10
        let percent = Int((fontScale * 100).rounded())
        flash(String(format: L10n.string("叠字 %lld%%"), percent))
    }

    var sourceMenuTitle: String {
        sourceLanguage == TranslationLanguage.autoSourceToken
            ? L10n.string("自动检测")
            : TranslatePopupLanguageOption.from(code: sourceLanguage).menuTitle
    }

    var targetMenuTitle: String {
        targetLanguage == TranslationLanguage.systemTargetToken
            ? L10n.string("自动选择")
            : TranslatePopupLanguageOption.from(code: targetLanguage).menuTitle
    }

    /// 是否已有任一非空译文
    var hasTranslatedContent: Bool {
        lines.contains {
            !$0.translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// 是否已有可展示的叠字（译文优先；原图 OCR 未译时用原文）
    var hasOverlayText: Bool {
        lines.contains { line in
            let text = displayText(for: line)
            return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    func displayText(for line: OverlayLine) -> String {
        let translated = line.translated.trimmingCharacters(in: .whitespacesAndNewlines)
        if !translated.isEmpty { return line.translated }
        // 原图 OCR：未翻译时叠原文；原图翻译未译完不叠空块
        if mode == .imageOCR {
            return line.source
        }
        return ""
    }

    @discardableResult
    func beginOperation(message: String? = nil) -> UUID {
        operationID = UUID()
        isProcessing = true
        emptyMessage = nil
        errorMessage = nil
        errorAction = nil
        statusMessage = nil
        if let message {
            processingMessage = message
        }
        return operationID
    }

    func applyError(_ message: String, action: ScreenTranslateOverlayErrorAction) {
        isProcessing = false
        emptyMessage = nil
        errorMessage = message
        errorAction = action
        statusMessage = nil
    }

    func isCurrent(_ id: UUID) -> Bool {
        !isClosed && operationID == id
    }

    func flash(_ message: String) {
        statusMessage = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.6))
            guard let self, statusMessage == message else { return }
            statusMessage = nil
        }
    }
}

// MARK: - Actions

struct ScreenTranslateOverlayActions {
    var enabledOCRServices: () -> [OCRServiceEntry] = { [.vision()] }
    var enabledTranslationServices: () -> [TranslationServiceEntry] = { [.system()] }
    var onSelectOCR: (ScreenTranslateOverlaySession, String) -> Void = { _, _ in }
    var onSelectTranslation: (ScreenTranslateOverlaySession, String) -> Void = { _, _ in }
    var onSourceLanguageChanged: (ScreenTranslateOverlaySession, String) -> Void = { _, _ in }
    var onTargetLanguageChanged: (ScreenTranslateOverlaySession, String) -> Void = { _, _ in }
    var onRetryOCR: (ScreenTranslateOverlaySession) -> Void = { _ in }
    var onRetranslate: (ScreenTranslateOverlaySession) -> Void = { _ in }
    var onOpenOCRSettings: () -> Void = {}
    var onOpenTranslationSettings: () -> Void = {}
    var onClose: () -> Void = {}
}

// MARK: - View

struct ScreenTranslateOverlayView: View {
    @Bindable var session: ScreenTranslateOverlaySession
    let actions: ScreenTranslateOverlayActions
    let toolbarAbove: Bool
    let toolbarWidth: CGFloat
    let toolbarHeight: CGFloat

    static let toolbarMaximumWidth: CGFloat = 760
    static let toolbarMinimumWidth: CGFloat = 280
    static let toolbarSingleRowMinimumWidth: CGFloat = 620
    /// 对齐截图工具栏：控件 26 + 上下 padding
    static let toolbarRowHeight: CGFloat = 26
    static let toolbarPadding: CGFloat = 4
    static let toolbarRowSpacing: CGFloat = 3
    static let toolbarGap: CGFloat = 6
    static let toolbarCornerRadius: CGFloat = 7
    /// 选区描边（与框选一致的显眼浅蓝）
    static let selectionBorderWidth: CGFloat = 2

    static func toolbarWidth(for availableWidth: CGFloat) -> CGFloat {
        min(toolbarMaximumWidth, max(toolbarMinimumWidth, availableWidth - 16))
    }

    static func toolbarHeight(for width: CGFloat) -> CGFloat {
        let rows = width >= toolbarSingleRowMinimumWidth ? 1 : 2
        return toolbarPadding * 2
            + CGFloat(rows) * toolbarRowHeight
            + CGFloat(max(0, rows - 1)) * toolbarRowSpacing
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Self.toolbarGap) {
            if toolbarAbove { toolbar }
            translatedSelection
            if !toolbarAbove { toolbar }
        }
        .frame(
            width: max(session.selection.rectInScreenPoints.width, toolbarWidth),
            height: session.selection.rectInScreenPoints.height + toolbarHeight + Self.toolbarGap,
            alignment: .topTrailing
        )
        .background(Color.clear)
    }

    private var translatedSelection: some View {
        let selW = session.selection.rectInScreenPoints.width
        let selH = session.selection.rectInScreenPoints.height
        return ZStack(alignment: .topLeading) {
            // 原图由下层提供；叠字态遮罩压低底层对比
            Color.black.opacity(session.isShowingOriginal ? 0 : 0.22)

            if !session.isShowingOriginal {
                ForEach(clusterTextBlocks(from: session.lines)) { block in
                    translationBlockView(block, viewSize: CGSize(width: selW, height: selH))
                }
            }

            if session.isProcessing {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(session.processingMessage)
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .foregroundStyle(.white)
                .background(.black.opacity(0.72), in: Capsule(style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                .allowsHitTesting(false)
            }

            if let message = session.errorMessage, !session.isProcessing {
                stateOverlay(message: message, isError: true, action: session.errorAction)
            } else if let message = session.emptyMessage, !session.isProcessing {
                stateOverlay(message: message, isError: false, action: session.errorAction)
            } else if let message = session.statusMessage, !session.isProcessing {
                Text(message)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.72), in: Capsule(style: .continuous))
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: selW, height: selH)
        .clipped()
        // 整体翻译框：显眼边框（对齐截图框选描边）
        .overlay {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .strokeBorder(
                    Color(nsColor: SnipStyle.stroke),
                    lineWidth: Self.selectionBorderWidth
                )
        }
    }

    private func stateOverlay(
        message: String,
        isError: Bool,
        action: ScreenTranslateOverlayErrorAction?
    ) -> some View {
        VStack(spacing: 8) {
            Image(systemName: isError ? "exclamationmark.triangle" : "text.viewfinder")
                .foregroundStyle(isError ? .yellow : .white)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(stateActionTitle(action)) {
                performStateAction(action)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func stateActionTitle(_ action: ScreenTranslateOverlayErrorAction?) -> String {
        guard let action else {
            return session.mode == .imageOCR
                ? L10n.string("重新识别")
                : L10n.string("重新翻译")
        }
        switch action {
        case .retryOCR:
            return L10n.string("重试识别")
        case .retranslate:
            return L10n.string("重新翻译")
        case .openOCRSettings:
            return L10n.string("打开 OCR 设置")
        case .openTranslationSettings:
            return L10n.string("打开翻译设置")
        }
    }

    private func performStateAction(_ action: ScreenTranslateOverlayErrorAction?) {
        guard let action else {
            if session.mode == .imageOCR {
                actions.onRetryOCR(session)
            } else {
                actions.onRetranslate(session)
            }
            return
        }
        switch action {
        case .retryOCR:
            actions.onRetryOCR(session)
        case .retranslate:
            actions.onRetranslate(session)
        case .openOCRSettings:
            actions.onOpenOCRSettings()
        case .openTranslationSettings:
            actions.onOpenTranslationSettings()
        }
    }

    /// 文本块：整块统一背景 + 按识别框自适应字号；可选中 / 一键复制
    @ViewBuilder
    private func translationBlockView(_ block: OverlayTextBlock, viewSize: CGSize) -> some View {
        let frame = mapBox(block.boundingBox, in: viewSize)
        let pad: CGFloat = 5
        let contentW = max(frame.width - pad * 2, 12)
        let contentH = max(frame.height - pad * 2, 12)
        // 先按框宽高拟合，再乘会话缩放（工具栏 A±）
        let baseSize = OverlayFontFitter.fittedFontSize(
            text: block.text,
            maxWidth: contentW,
            maxHeight: contentH,
            lineHeightHint: max(8, block.averageLineHeight * (viewSize.height / max(session.imageSize.height, 1)))
        )
        let fontSize = OverlayFontFitter.clampedSize(baseSize * session.fontScale)
        let copyHint = session.hasTranslatedContent ? L10n.string("已复制该段译文") : L10n.string("已复制该段原文")

        TranslationBlockCard(
            text: block.text,
            contentWidth: contentW,
            fontSize: fontSize,
            // 背景默认贴合识别框；字号放大后允许纵向撑开以免裁字
            minWidth: max(frame.width, 16),
            minHeight: max(frame.height, fontSize + pad * 2),
            preferredHeight: frame.height,
            pad: pad,
            onCopy: { copyOverlayText(block.text, hint: copyHint) }
        )
        .offset(x: frame.minX, y: frame.minY)
    }

    private func copyAllOverlayText() {
        let text = session.lines
            .map { session.displayText(for: $0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let hint = session.hasTranslatedContent ? L10n.string("已复制全部译文") : L10n.string("已复制全部原文")
        copyOverlayText(text, hint: hint)
    }

    private func copyOverlayText(_ text: String, hint: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            session.flash(session.hasTranslatedContent ? L10n.string("暂无译文可复制") : L10n.string("暂无原文可复制"))
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        session.flash(hint)
    }

    /// 显示原图 / 显示译文|原文 切换文案
    private var toggleOriginalTitle: String {
        if session.isShowingOriginal {
            return session.hasTranslatedContent ? L10n.string("显示译文") : L10n.string("显示原文")
        }
        return L10n.string("显示原图")
    }

    private var toggleOriginalHelp: String {
        if session.isShowingOriginal {
            return session.hasTranslatedContent ? L10n.string("显示译文") : L10n.string("显示识别原文")
        }
        return L10n.string("查看原图")
    }

    private var retranslateHelp: String {
        session.hasTranslatedContent ? L10n.string("重新翻译") : L10n.string("一键翻译")
    }

    private var toolbar: some View {
        // 紧凑排列：不把多余宽度均分到间距
        HStack(spacing: 2) {
            OverlayOCRServiceMenu(
                selectedID: session.ocrServiceID,
                services: actions.enabledOCRServices(),
                onSelect: { id in
                    session.ocrServiceID = id
                    actions.onSelectOCR(session, id)
                }
            )

            toolbarDivider

            OverlayTranslationServiceMenu(
                selectedID: session.translationServiceID,
                services: actions.enabledTranslationServices(),
                onSelect: { id in
                    session.translationServiceID = id
                    actions.onSelectTranslation(session, id)
                }
            )

            toolbarDivider

            HStack(spacing: 0) {
                OverlayLanguageMenu(
                    title: session.sourceMenuTitle,
                    selection: session.sourceLanguage,
                    options: TranslatePopupLanguageOption.sourceOptions,
                    chipStyle: .embedded,
                    showSymbol: false
                ) { code in
                    session.sourceLanguage = code
                    actions.onSourceLanguageChanged(session, code)
                }

                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(CaptureToolbarStyle.textSecondary)
                    .frame(width: 12)

                OverlayLanguageMenu(
                    title: session.targetMenuTitle,
                    selection: session.targetLanguage,
                    options: TranslatePopupLanguageOption.targetOptions,
                    chipStyle: .embedded,
                    showSymbol: false
                ) { code in
                    session.targetLanguage = code
                    actions.onTargetLanguageChanged(session, code)
                }
            }
            .padding(.horizontal, 3)
            .frame(height: CaptureToolbarStyle.controlHeight)
            .background(
                RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous)
                    .fill(CaptureToolbarStyle.fieldFill)
            )

            toolbarDivider

            ScreenTranslateToolbarButton(
                title: toggleOriginalTitle,
                symbol: "photo",
                help: toggleOriginalHelp,
                style: .chip
            ) {
                // 无叠字时不允许切到「显示叠字」（与原图翻译无译文时一致：复制禁用）
                if session.isShowingOriginal, !session.hasOverlayText {
                    session.flash(session.mode == .imageOCR ? L10n.string("暂无识别结果") : L10n.string("暂无译文"))
                    return
                }
                session.isShowingOriginal.toggle()
            }

            // 纯图标：不用 textformat.size（带字母 A，易被看成文字按钮）
            ScreenTranslateToolbarButton(
                symbol: "minus",
                help: L10n.string("减小叠字（相对识别框自适应）"),
                style: .icon,
                disabled: !session.canDecreaseFontScale
            ) {
                session.adjustFontScale(by: -ScreenTranslateOverlaySession.fontScaleStep)
            }

            ScreenTranslateToolbarButton(
                symbol: "plus",
                help: L10n.string("增大叠字（相对识别框自适应）"),
                style: .icon,
                disabled: !session.canIncreaseFontScale
            ) {
                session.adjustFontScale(by: ScreenTranslateOverlaySession.fontScaleStep)
            }

            ScreenTranslateToolbarButton(
                symbol: "doc.on.doc",
                help: session.hasTranslatedContent ? L10n.string("复制全部译文") : L10n.string("复制全部原文"),
                style: .icon,
                // 对齐原图翻译「显示原图」态：隐藏叠字时禁用复制
                disabled: session.isShowingOriginal || !session.hasOverlayText
            ) {
                copyAllOverlayText()
            }

            ScreenTranslateToolbarButton(
                symbol: session.hasTranslatedContent ? "arrow.clockwise" : "globe",
                help: retranslateHelp,
                style: .icon
            ) {
                actions.onRetranslate(session)
            }

            ScreenTranslateToolbarButton(symbol: "xmark", help: L10n.string("关闭"), style: .icon) {
                actions.onClose()
            }
        }
        .padding(.horizontal, Self.toolbarPadding)
        .padding(.vertical, Self.toolbarPadding)
        .background(
            RoundedRectangle(cornerRadius: Self.toolbarCornerRadius, style: .continuous)
                .fill(CaptureToolbarStyle.barBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Self.toolbarCornerRadius, style: .continuous)
                .strokeBorder(CaptureToolbarStyle.barBorder, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 8, y: 3)
        .fixedSize()
    }

    private var toolbarDivider: some View {
        Rectangle()
            .fill(CaptureToolbarStyle.separator)
            .frame(width: 1, height: 12)
            .padding(.horizontal, 2)
            .frame(height: CaptureToolbarStyle.controlHeight)
    }

    private func mapBox(_ pixelBox: CGRect, in viewSize: CGSize) -> CGRect {
        guard session.imageSize.width > 0, session.imageSize.height > 0 else { return .zero }
        let sx = viewSize.width / session.imageSize.width
        let sy = viewSize.height / session.imageSize.height
        return CGRect(
            x: pixelBox.minX * sx,
            y: pixelBox.minY * sy,
            width: pixelBox.width * sx,
            height: pixelBox.height * sy
        )
    }

    // MARK: - Text blocks

    /// 将邻近 OCR 行聚合成段落块，共用一块背景与宽度
    private func clusterTextBlocks(from lines: [OverlayLine]) -> [OverlayTextBlock] {
        let valid = lines.filter {
            !session.displayText(for: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard !valid.isEmpty else { return [] }

        let sorted = valid.sorted { a, b in
            if abs(a.boundingBox.minY - b.boundingBox.minY) < 3 {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return a.boundingBox.minY < b.boundingBox.minY
        }

        var groups: [[OverlayLine]] = []
        var current: [OverlayLine] = []

        for line in sorted {
            guard let prev = current.last else {
                current = [line]
                continue
            }
            let gap = line.boundingBox.minY - prev.boundingBox.maxY
            let avgH = max(8, (prev.boundingBox.height + line.boundingBox.height) / 2)
            // 行距不大且水平范围有关联 → 同一文本块
            let verticalClose = gap <= max(10, avgH * 0.9)
            let horizontalRelated =
                line.boundingBox.minX <= prev.boundingBox.maxX + avgH * 2.5
                && line.boundingBox.maxX >= prev.boundingBox.minX - avgH * 2.5
            if verticalClose, horizontalRelated {
                current.append(line)
            } else {
                groups.append(current)
                current = [line]
            }
        }
        if !current.isEmpty { groups.append(current) }

        return groups.map { group in
            let union = group.dropFirst().reduce(group[0].boundingBox) { partial, line in
                partial.union(line.boundingBox)
            }
            // 略扩展，避免文字贴边
            let padded = union.insetBy(dx: -3, dy: -2)
            let avgH = group.map(\.boundingBox.height).reduce(0, +) / CGFloat(group.count)
            return OverlayTextBlock(
                id: group[0].id,
                text: joinBlockText(group),
                boundingBox: padded,
                averageLineHeight: avgH
            )
        }
    }

    /// 块内拼接：中文紧密拼接，西文用空格（译文优先，原图 OCR 未译用原文）
    private func joinBlockText(_ lines: [OverlayLine]) -> String {
        guard !lines.isEmpty else { return "" }
        let texts = lines.map { session.displayText(for: $0) }
        if texts.count == 1 { return texts[0] }

        var result = texts[0]
        for i in 1..<texts.count {
            let next = texts[i]
            let needSpace = needsSpaceBetween(result, next)
            result += needSpace ? " " + next : next
        }
        return result
    }

    private func needsSpaceBetween(_ left: String, _ right: String) -> Bool {
        guard let lc = left.last, let rc = right.first else { return false }
        let cjk: (Character) -> Bool = { ch in
            ch.unicodeScalars.contains { scalar in
                (0x4E00...0x9FFF).contains(scalar.value)
                    || (0x3400...0x4DBF).contains(scalar.value)
                    || (0xF900...0xFAFF).contains(scalar.value)
            }
        }
        if cjk(lc) || cjk(rc) { return false }
        if lc.isWhitespace || rc.isWhitespace { return false }
        if "，。！？、；：,.!?;:)]}》」』".contains(rc) { return false }
        if "([{《「『".contains(lc) { return false }
        return true
    }
}

/// 聚合后的译文块（图像像素坐标，原点左上）
private struct OverlayTextBlock: Identifiable {
    let id: UUID
    let text: String
    let boundingBox: CGRect
    let averageLineHeight: CGFloat
}

// MARK: - 按识别框自适应字号

/// 根据目标宽高二分搜索最大可排下的字号（对齐 SwiftUI 中等字重 + lineSpacing）。
private enum OverlayFontFitter {
    static let minSize: CGFloat = 8
    static let maxSize: CGFloat = 48

    static func clampedSize(_ size: CGFloat) -> CGFloat {
        min(maxSize, max(minSize, size))
    }

    /// - Parameters:
    ///   - maxWidth / maxHeight: 内容区（已扣 padding）
    ///   - lineHeightHint: 屏幕坐标下行高提示，用于上限，避免单字撑满过高框
    static func fittedFontSize(
        text: String,
        maxWidth: CGFloat,
        maxHeight: CGFloat,
        lineHeightHint: CGFloat
    ) -> CGFloat {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return minSize }
        let width = max(maxWidth, 8)
        let height = max(maxHeight, 8)
        // 上限：框高、行高提示、全局 max；下限 minSize
        let hiCap = min(maxSize, max(height * 0.95, minSize), max(lineHeightHint * 1.15, minSize))
        var lo = minSize
        var hi = max(lo, hiCap)
        // 若最大字号仍装不下，退到 minSize（卡片可纵向略撑开）
        if !fits(trimmed, fontSize: lo, maxWidth: width, maxHeight: height) {
            return lo
        }
        if fits(trimmed, fontSize: hi, maxWidth: width, maxHeight: height) {
            return hi
        }
        for _ in 0..<12 {
            let mid = (lo + hi) / 2
            if fits(trimmed, fontSize: mid, maxWidth: width, maxHeight: height) {
                lo = mid
            } else {
                hi = mid
            }
        }
        return lo
    }

    private static func fits(
        _ text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat,
        maxHeight: CGFloat
    ) -> Bool {
        let size = measure(text, fontSize: fontSize, maxWidth: maxWidth)
        // 略放宽 1pt，避免舍入导致偏小
        return size.width <= maxWidth + 1 && size.height <= maxHeight + 1
    }

    private static func measure(
        _ text: String,
        fontSize: CGFloat,
        maxWidth: CGFloat
    ) -> CGSize {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .medium)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        // 与 TranslationBlockCard.lineSpacing 对齐
        paragraph.lineSpacing = max(1, fontSize * 0.18)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .paragraphStyle: paragraph,
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }
}

// MARK: - Capture toolbar palette（对齐 SnipToolbar / AnnotateOptionsBar）

private enum CaptureToolbarStyle {
    static let controlHeight: CGFloat = 26
    static let iconButtonSize: CGFloat = 26
    static let chipCorner: CGFloat = 5
    static let barBackground = Color(nsColor: AppTheme.nsCaptureBarBackground).opacity(0.92)
    static let barBorder = Color(nsColor: AppTheme.nsCaptureBorder)
    static let separator = Color(nsColor: AppTheme.nsCaptureSeparator)
    static let fieldFill = Color(nsColor: AppTheme.nsCaptureField)
    static let fieldHover = Color(nsColor: AppTheme.nsCaptureHover)
    static let text = Color(nsColor: AppTheme.nsCaptureText)
    static let textSecondary = Color.white.opacity(0.55)
}

private enum ScreenTranslateChipStyle {
    /// 独立下拉：字段底 + 圆角（OCR / 翻译服务）
    case standalone
    /// 嵌在语言组字段底内，仅 hover 高亮
    case embedded
}

// MARK: - Toolbar menus

/// 工具栏字号 11pt，品牌图与文字同高（约 12）
private enum OverlayServiceIconMetrics {
    static let chipIcon: CGFloat = 12
    static let rowIcon: CGFloat = 18
    static let labelFontSize: CGFloat = 11
}

/// 叠层 OCR 服务：用 popover 而非系统 Menu（Menu 会丢掉自定义品牌图）
private struct OverlayOCRServiceMenu: View {
    let selectedID: String
    let services: [OCRServiceEntry]
    let onSelect: (String) -> Void

    @State private var isOpen = false

    private var selected: OCRServiceEntry? { services.first { $0.id == selectedID } }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            ScreenTranslateMenuLabel(
                title: selected?.displayName ?? OCRServiceKind.vision.displayName,
                ocrKind: selected?.kind ?? .vision,
                chipStyle: .standalone,
                isExpanded: isOpen
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            OverlayServicePickerPanel(
                title: L10n.string("文本识别"),
                rows: services.map {
                    OverlayServicePickerRow(
                        id: $0.id,
                        title: $0.displayName,
                        isSelected: $0.id == selectedID,
                        ocrKind: $0.kind,
                        translationKind: nil
                    )
                },
                onSelect: { id in
                    onSelect(id)
                    isOpen = false
                }
            )
        }
        .accessibilityLabel(L10n.string("选择 OCR 服务"))
    }
}

/// 叠层翻译服务：popover + 品牌图（与偏好设置一致）
private struct OverlayTranslationServiceMenu: View {
    let selectedID: String
    let services: [TranslationServiceEntry]
    let onSelect: (String) -> Void

    @State private var isOpen = false

    private var selected: TranslationServiceEntry? { services.first { $0.id == selectedID } }

    var body: some View {
        Button {
            isOpen.toggle()
        } label: {
            ScreenTranslateMenuLabel(
                title: selected?.displayName ?? TranslationServiceKind.system.displayName,
                translationKind: selected?.kind ?? .system,
                chipStyle: .standalone,
                isExpanded: isOpen
            )
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            OverlayServicePickerPanel(
                title: L10n.string("翻译服务"),
                rows: services.map {
                    OverlayServicePickerRow(
                        id: $0.id,
                        title: $0.displayName,
                        isSelected: $0.id == selectedID,
                        ocrKind: nil,
                        translationKind: $0.kind
                    )
                },
                onSelect: { id in
                    onSelect(id)
                    isOpen = false
                }
            )
        }
        .accessibilityLabel(L10n.string("选择翻译服务"))
    }
}

private struct OverlayServicePickerRow: Identifiable {
    let id: String
    let title: String
    let isSelected: Bool
    let ocrKind: OCRServiceKind?
    let translationKind: TranslationServiceKind?
}

private struct OverlayServicePickerPanel: View {
    let title: String
    let rows: [OverlayServicePickerRow]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
                .padding(.bottom, 4)

            ForEach(rows) { row in
                Button {
                    onSelect(row.id)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(AppTheme.textPrimary)
                            .frame(width: 14)
                            .opacity(row.isSelected ? 1 : 0)

                        if let ocrKind = row.ocrKind {
                            OCRServiceIconView(kind: ocrKind, size: OverlayServiceIconMetrics.rowIcon)
                        } else if let translationKind = row.translationKind {
                            TranslationServiceIconView(kind: translationKind, size: OverlayServiceIconMetrics.rowIcon)
                        }

                        Text(row.title)
                            .font(.system(size: 12, weight: .regular))
                            .foregroundStyle(AppTheme.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 8)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(row.isSelected ? AppTheme.textPrimary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
                .onHover { updateHandCursor($0) }
            }
        }
        .padding(4)
        .frame(minWidth: 200)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppTheme.surfaceMuted)
        )
    }
}

private struct OverlayLanguageMenu: View {
    let title: String
    let selection: String
    let options: [TranslatePopupLanguageOption]
    var chipStyle: ScreenTranslateChipStyle = .standalone
    var showSymbol: Bool = true
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    onSelect(option.rawValue)
                } label: {
                    if TranslationLanguage.normalize(selection) == TranslationLanguage.normalize(option.rawValue) {
                        Label(option.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(option.menuTitle)
                    }
                }
            }
        } label: {
            ScreenTranslateMenuLabel(
                title: title,
                symbol: showSymbol ? "character.book.closed" : nil,
                chipStyle: chipStyle
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .accessibilityLabel(L10n.string("设置翻译语言"))
    }
}

/// 工具栏下拉触发器：服务项优先品牌图（与设置页 `*ServiceIconView` 一致），图标与 11pt 文字同高
private struct ScreenTranslateMenuLabel: View {
    let title: String
    var symbol: String? = nil
    var ocrKind: OCRServiceKind? = nil
    var translationKind: TranslationServiceKind? = nil
    var chipStyle: ScreenTranslateChipStyle = .standalone
    var isExpanded: Bool = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            leadingIcon
            Text(title)
                .font(.system(size: OverlayServiceIconMetrics.labelFontSize, weight: .medium))
                .lineLimit(1)
            // 明确的下拉指示：更大 chevron + 弱化竖线分隔
            if chipStyle == .standalone {
                Rectangle()
                    .fill(CaptureToolbarStyle.separator.opacity(0.7))
                    .frame(width: 1, height: 12)
                    .padding(.leading, 1)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: chipStyle == .standalone ? 9 : 7, weight: .bold))
                .foregroundStyle(
                    CaptureToolbarStyle.text.opacity(hovering || isExpanded ? 0.95 : 0.72)
                )
                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                .frame(width: chipStyle == .standalone ? 12 : 8)
        }
        .foregroundStyle(CaptureToolbarStyle.text)
        .padding(.leading, chipStyle == .embedded ? 5 : 7)
        .padding(.trailing, chipStyle == .embedded ? 5 : 6)
        .frame(height: CaptureToolbarStyle.controlHeight)
        .background(chipBackground)
        .overlay(chipBorder)
        .contentShape(RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous))
        .onHover { inside in
            hovering = inside
            updateHandCursor(inside)
        }
        .animation(.easeOut(duration: 0.12), value: isExpanded)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if let ocrKind {
            OCRServiceIconView(kind: ocrKind, size: OverlayServiceIconMetrics.chipIcon)
                .fixedSize()
        } else if let translationKind {
            TranslationServiceIconView(kind: translationKind, size: OverlayServiceIconMetrics.chipIcon)
                .fixedSize()
        } else if let symbol {
            Image(systemName: symbol)
                .font(.system(size: OverlayServiceIconMetrics.labelFontSize, weight: .medium))
                .frame(
                    width: OverlayServiceIconMetrics.chipIcon,
                    height: OverlayServiceIconMetrics.chipIcon
                )
        }
    }

    @ViewBuilder
    private var chipBackground: some View {
        switch chipStyle {
        case .standalone:
            // 更醒目的字段底，一眼能看出是可点下拉
            RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous)
                .fill(hovering ? CaptureToolbarStyle.fieldHover : Color.white.opacity(0.12))
        case .embedded:
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(hovering ? CaptureToolbarStyle.fieldHover : Color.clear)
        }
    }

    @ViewBuilder
    private var chipBorder: some View {
        switch chipStyle {
        case .standalone:
            RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(hovering ? 0.32 : 0.20),
                    lineWidth: 1
                )
        case .embedded:
            EmptyView()
        }
    }
}

/// 译文卡片：可选中 + 悬停显示复制；默认贴合识别框
private struct TranslationBlockCard: View {
    let text: String
    let contentWidth: CGFloat
    let fontSize: CGFloat
    let minWidth: CGFloat
    let minHeight: CGFloat
    /// 识别框高度；字号放大时允许超过
    var preferredHeight: CGFloat = 0
    let pad: CGFloat
    let onCopy: () -> Void

    @State private var hovering = false
    @State private var copyHovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Text(text)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
                .lineSpacing(max(1, fontSize * 0.18))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(pad)
                .padding(.trailing, hovering ? 22 : 0)

            // 悬停显示复制；始终可点区域避免误伤选中
            Button(action: onCopy) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(copyHovering ? 1 : 0.88))
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(Color.white.opacity(copyHovering ? 0.22 : 0.12))
                    )
            }
            .buttonStyle(.plain)
            .help(L10n.string("复制这段文字"))
            .padding(4)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .onHover { inside in
                copyHovering = inside
                updateHandCursor(inside)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(Color.black.opacity(hovering ? 0.88 : 0.82))
        )
        .frame(
            minWidth: minWidth,
            minHeight: max(minHeight, preferredHeight),
            alignment: .topLeading
        )
        .onHover { hovering = $0 }
    }
}

private enum ScreenTranslateButtonStyle {
    /// 图标+文案，带字段底（如「显示原图」）
    case chip
    /// 纯图标，对齐 SnipToolButton
    case icon
}

private struct ScreenTranslateToolbarButton: View {
    let symbol: String
    var title: String?
    var help: String
    var style: ScreenTranslateButtonStyle = .icon
    var disabled: Bool = false
    let action: () -> Void
    @State private var hovering = false
    @State private var pressed = false

    init(
        title: String? = nil,
        symbol: String,
        help: String,
        style: ScreenTranslateButtonStyle = .icon,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.style = style
        self.disabled = disabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !disabled else { return }
            pressed = true
            action()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                pressed = false
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: symbol)
                    .font(.system(size: style == .icon ? 12 : 11, weight: .medium))
                if let title {
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(CaptureToolbarStyle.text.opacity(disabled ? 0.35 : 1))
            .frame(
                width: style == .icon && title == nil ? CaptureToolbarStyle.iconButtonSize : nil,
                height: CaptureToolbarStyle.controlHeight
            )
            .padding(.horizontal, style == .chip ? 6 : 0)
            .background(buttonBackground)
            .contentShape(RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
        .onHover { inside in
            guard !disabled else { return }
            hovering = inside
            updateHandCursor(inside)
        }
        .accessibilityLabel(help)
    }

    @ViewBuilder
    private var buttonBackground: some View {
        let shape = RoundedRectangle(cornerRadius: CaptureToolbarStyle.chipCorner, style: .continuous)
        if pressed {
            shape.fill(Color(nsColor: AppTheme.nsCapturePressed))
        } else if style == .chip {
            shape.fill(hovering ? CaptureToolbarStyle.fieldHover : CaptureToolbarStyle.fieldFill)
        } else if hovering {
            shape.fill(CaptureToolbarStyle.fieldHover)
        } else {
            shape.fill(Color.clear)
        }
    }
}

/// 按可用宽度换行，避免固定 HStack 把服务名称压成省略号。
private struct ToolbarFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? subviews.reduce(0) {
            $0 + $1.sizeThatFits(.unspecified).width
        }
        let rows = rows(for: subviews, width: max(1, width))
        return CGSize(
            width: width,
            height: rows.reduce(0) { $0 + $1.height }
                + CGFloat(max(0, rows.count - 1)) * verticalSpacing
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: subviews, width: max(1, bounds.width))
        var y = bounds.minY
        for row in rows {
            let sizes = row.indices.map { subviews[$0].sizeThatFits(.unspecified) }
            let contentWidth = sizes.reduce(0) { $0 + $1.width }
            let baseSpacing = CGFloat(max(0, row.indices.count - 1)) * horizontalSpacing
            let extraSpacing = row.indices.count > 1
                ? max(0, bounds.width - contentWidth - baseSpacing) / CGFloat(row.indices.count - 1)
                : 0
            var x = bounds.minX
            for (offset, index) in row.indices.enumerated() {
                let size = sizes[offset]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + horizontalSpacing + extraSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [(indices: [Int], height: CGFloat)] {
        var result: [(indices: [Int], height: CGFloat)] = []
        var current: [Int] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let nextWidth = current.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width
            if !current.isEmpty, nextWidth > width {
                result.append((current, currentHeight))
                current = []
                currentWidth = 0
                currentHeight = 0
            }
            current.append(index)
            currentWidth = current.isEmpty ? size.width : currentWidth + (current.count == 1 ? 0 : horizontalSpacing) + size.width
            currentHeight = max(currentHeight, size.height)
        }
        if !current.isEmpty {
            result.append((current, currentHeight))
        }
        return result
    }
}
