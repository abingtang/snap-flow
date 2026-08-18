import AppKit
import SwiftUI

/// 安全手型光标：用 `set()` 代替 `push()`/`pop()`，避免嵌套 hover 或视图销毁导致光标栈失衡。
///
/// 不加 `@MainActor` 注解：部分 View 辅助函数为 nonisolated，但 hover 回调实际始终在主线程执行。
enum PointerCursor {
    nonisolated static func setHand(_ hovering: Bool) {
        if hovering {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
    }
}

/// 全项目共用：hover 进入/离开时切换手型 / 箭头。
nonisolated func updateHandCursor(_ hovering: Bool) {
    PointerCursor.setHand(hovering)
}

extension View {
    /// 悬停时显示手型光标（离开恢复箭头）。
    func pointingHandOnHover(enabled: Bool = true) -> some View {
        onHover { hovering in
            guard enabled else {
                if !hovering { NSCursor.arrow.set() }
                return
            }
            updateHandCursor(hovering)
        }
    }

    /// 连续 hover 相位版（与 `onContinuousHover` 搭配的旧写法迁移用）。
    func pointingHandOnContinuousHover(enabled: Bool = true) -> some View {
        onContinuousHover { phase in
            guard enabled else { return }
            switch phase {
            case .active:
                updateHandCursor(true)
            case .ended:
                updateHandCursor(false)
            }
        }
    }
}
