import AppKit
import SwiftUI

// MARK: - 全局：同时只允许一个快捷键处于录制态

@MainActor
@Observable
final class HotkeyRecordingStore {
    static let shared = HotkeyRecordingStore()

    /// 非隔离只读标志，供 `LocalShortcutMatcher` 等非 MainActor 路径快速判断。
    nonisolated(unsafe) private(set) static var recordingActiveFlag = false

    /// 当前正在录制的字段；`nil` 表示无人录制。
    var activeFieldID: UUID?

    /// 是否处于快捷键录制（用于屏蔽全局/局部热键）。
    var isRecordingActive: Bool { activeFieldID != nil }

    /// 录制开始/结束时回调（挂接 `HotKeyManager.suspend/resume`）。
    var onRecordingActiveChange: ((Bool) -> Void)?

    func claim(_ id: UUID) {
        let wasIdle = activeFieldID == nil
        activeFieldID = id
        Self.recordingActiveFlag = true
        if wasIdle {
            onRecordingActiveChange?(true)
        }
    }

    func release(_ id: UUID) {
        guard activeFieldID == id else { return }
        activeFieldID = nil
        Self.recordingActiveFlag = false
        onRecordingActiveChange?(false)
    }

    func isActive(_ id: UUID) -> Bool {
        activeFieldID == id
    }
}

// MARK: - 录制控件

/// 快捷键录制胶囊：
/// - 点击整颗按钮进入修改
/// - 全局同时只允许一个字段录制
/// - 录制中显示「取消」；Esc 或取消不提交
struct HotkeyRecorderField: View {
    @Binding var chord: String
    var placeholder: String = L10n.string("点击修改")
    var onChange: (() -> Void)?

    @State private var fieldID = UUID()
    @State private var monitor: Any?
    @State private var isHovered = false
    /// 录制中实时预览（修饰键 / 完整组合）
    @State private var livePreview: String = ""
    /// 订阅 `@Observable` 变更（其它字段 claim 时本字段退出录制 UI）。
    private let store = HotkeyRecordingStore.shared

    private var isRecording: Bool {
        store.activeFieldID == fieldID
    }

    var body: some View {
        HStack(spacing: 8) {
            // 整颗胶囊可点：进入 / 再次点击可取消
            Button {
                if isRecording {
                    cancelRecording()
                } else {
                    startRecording()
                }
            } label: {
                Text(labelText)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .dynamicTypeSize(SettingsTypography.contentTypeRange)
                    .foregroundStyle(labelColor)
                    .lineLimit(1)
                    .frame(minWidth: 100, alignment: .center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(
                        Capsule(style: .continuous)
                            .fill(backgroundFill)
                    )
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(borderColor, lineWidth: isRecording ? 1.5 : 1)
                    )
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(isRecording ? L10n.string("点击取消录制") : L10n.string("点击修改快捷键"))
            .onHover { hovering in
                isHovered = hovering
                updateHandCursor(hovering)
            }

            if isRecording {
                Button {
                    cancelRecording()
                } label: {
                    Text(L10n.string("取消"))
                        .settingsCompactText(weight: .semibold)
                        .foregroundStyle(AppTheme.accent)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            Capsule(style: .continuous)
                                .fill(AppTheme.accent.opacity(0.14))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(AppTheme.accent.opacity(0.28), lineWidth: 1)
                        )
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(L10n.string("取消修改，保留原快捷键"))
                .onHover { hovering in
                    updateHandCursor(hovering)
                }
            } else if !chord.isEmpty {
                Button {
                    chord = ""
                    onChange?()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .settingsRowTitleText()
                        .foregroundStyle(AppTheme.textTertiary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.string("清除快捷键"))
                .onHover { hovering in
                    updateHandCursor(hovering)
                }
            }
        }
        .onChange(of: store.activeFieldID) { _, newID in
            // 其它字段抢占录制权时，卸掉本字段 monitor
            if newID != fieldID {
                teardownMonitorOnly()
                livePreview = ""
            }
        }
        .onDisappear {
            cancelRecording()
        }
        .animation(.easeOut(duration: 0.12), value: isRecording)
        .animation(.easeOut(duration: 0.1), value: isHovered)
        .animation(.easeOut(duration: 0.08), value: livePreview)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isRecording
                ? (livePreview.isEmpty ? L10n.string("正在录制快捷键") : String(format: L10n.string("当前按键 %@"), livePreview))
                : String(format: L10n.string("快捷键 %@"), displayChord)
        )
        .accessibilityHint(isRecording ? L10n.string("按下新快捷键确认，或点取消") : L10n.string("点击后按下新的快捷键"))
    }

    // MARK: Appearance

    private var labelText: String {
        if isRecording {
            return livePreview.isEmpty ? L10n.string("按下快捷键…") : livePreview
        }
        if chord.isEmpty { return placeholder }
        return HotKeyChord.displayString(from: chord)
    }

    private var displayChord: String {
        chord.isEmpty ? placeholder : HotKeyChord.displayString(from: chord)
    }

    private var labelColor: Color {
        if isRecording { return AppTheme.accent }
        if chord.isEmpty { return AppTheme.textSecondary }
        return AppTheme.textPrimary
    }

    private var backgroundFill: Color {
        if isRecording { return AppTheme.accentSoft }
        if isHovered { return AppTheme.surfaceHover }
        return AppTheme.surfaceMuted
    }

    private var borderColor: Color {
        if isRecording { return AppTheme.accent.opacity(0.55) }
        return isHovered ? AppTheme.textTertiary : AppTheme.border
    }

    // MARK: Recording

    private func startRecording() {
        teardownMonitorOnly()
        livePreview = ""
        store.claim(fieldID)
        // 同步当前已按住的修饰键（若有）
        livePreview = HotKeyChord.displayModifiers(from: NSEvent.modifierFlags)

        // 录制期间吞掉 keyDown / keyUp，避免菜单栏快捷键、局部快捷键继续响应
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .keyUp, .flagsChanged]
        ) { [fieldID] event in
            // 非本字段录制时不拦截
            // （其它 monitor 不应存在；仍做守卫）
            let active = HotkeyRecordingStore.shared.isActive(fieldID)

            if event.type == .flagsChanged {
                if active {
                    Task { @MainActor in
                        guard HotkeyRecordingStore.shared.isActive(fieldID) else { return }
                        // 仅修饰键：实时显示 ⌃⌥⇧⌘；全部松开则回到提示
                        self.livePreview = HotKeyChord.displayModifiers(from: event.modifierFlags)
                    }
                }
                // 修饰键事件仍放行，避免系统状态错乱
                return event
            }

            // keyUp：一律吞掉，防止配对快捷键残留
            if event.type == .keyUp {
                return active ? nil : event
            }

            // keyDown
            guard active else { return event }

            // Esc：取消
            if event.keyCode == 53 {
                Task { @MainActor in
                    guard HotkeyRecordingStore.shared.isActive(fieldID) else { return }
                    self.cancelRecording()
                }
                return nil
            }
            // 忽略单独修饰键 keyDown（修饰变化走 flagsChanged）
            if Self.isModifierOnly(event) { return nil }

            if let next = HotKeyChord.chordString(from: event) {
                let preview = HotKeyChord.displayString(from: next)
                Task { @MainActor in
                    guard HotkeyRecordingStore.shared.isActive(fieldID) else { return }
                    // 先刷新预览，再提交
                    self.livePreview = preview
                    self.chord = next
                    self.onChange?()
                    self.finishRecordingCommitted()
                }
            }
            // 吞掉所有 keyDown，屏蔽本应用菜单/其它局部快捷键
            return nil
        }
    }

    private func cancelRecording() {
        teardownMonitorOnly()
        livePreview = ""
        store.release(fieldID)
    }

    private func finishRecordingCommitted() {
        teardownMonitorOnly()
        livePreview = ""
        store.release(fieldID)
    }

    /// 只卸 monitor，不改 store（用于被其它字段抢占时）。
    private func teardownMonitorOnly() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private static func isModifierOnly(_ event: NSEvent) -> Bool {
        // 左右 Command/Shift/Option/Control 键码
        let codes: Set<UInt16> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
        return codes.contains(event.keyCode)
    }
}

// MARK: - Chord ↔ 展示 / 事件

extension HotKeyChord {
    /// 录制中：根据当前修饰键 flags 实时显示 `⌃⌥⇧⌘`（无主键时也可单独显示）。
    static func displayModifiers(from flags: NSEvent.ModifierFlags) -> String {
        let f = flags.intersection([.control, .option, .shift, .command])
        var ordered = ""
        if f.contains(.control) { ordered += "⌃" }
        if f.contains(.option) { ordered += "⌥" }
        if f.contains(.shift) { ordered += "⇧" }
        if f.contains(.command) { ordered += "⌘" }
        return ordered
    }

    /// `ctrl+option+command+a` → `⌃⌥⌘A`
    static func displayString(from chord: String) -> String {
        let parts = chord.lowercased()
            .split(separator: "+")
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "" }

        var symbols = ""
        var key = ""
        for p in parts {
            switch p {
            case "ctrl", "control": symbols += "⌃"
            case "opt", "option", "alt": symbols += "⌥"
            case "shift": symbols += "⇧"
            case "cmd", "command": symbols += "⌘"
            default: key = prettyKey(p)
            }
        }
        // 修饰键固定顺序：⌃⌥⇧⌘
        var ordered = ""
        if symbols.contains("⌃") { ordered += "⌃" }
        if symbols.contains("⌥") { ordered += "⌥" }
        if symbols.contains("⇧") { ordered += "⇧" }
        if symbols.contains("⌘") { ordered += "⌘" }
        return ordered + key
    }

    /// 从按键事件生成 chord 字符串（与 parse 兼容）
    static func chordString(from event: NSEvent) -> String? {
        var parts: [String] = []
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("option") }
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }

        guard let key = keyName(for: event) else { return nil }
        // 单独修饰不够；至少要有一个主键
        parts.append(key)
        // F 键等可无修饰；字母建议有修饰，但允许单键（如 f1）
        return parts.joined(separator: "+")
    }

    private static func prettyKey(_ key: String) -> String {
        HotKeyChord.prettyKeyName(key)
    }

    /// 主键名：优先 keyCode 表（含 ` [ ] \ 等），再回退可打印字符。
    private static func keyName(for event: NSEvent) -> String? {
        if let named = HotKeyChord.keyName(forKeyCode: event.keyCode) {
            // 小键盘 Enter 与主键盘 Return 共用 return 名
            if event.keyCode == 76 { return "keypadenter" }
            // 历史兼容：= 键仍可记为 plus（LocalShortcut cmd+plus）
            if named == "equal" { return "plus" }
            return named
        }
        // 未在表中的可打印字符（部分布局 / 输入法）
        if let chars = event.charactersIgnoringModifiers?.lowercased(),
           let ch = chars.first,
           !ch.isWhitespace,
           ch.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0) })
        {
            // 至少能显示；全局注册仍依赖 name→keyCode，未知字符可能仅局部匹配
            return String(ch)
        }
        return nil
    }
}
