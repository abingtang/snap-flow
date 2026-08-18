import AppKit
import Carbon
import CoreGraphics
import Darwin
import Foundation

/// 截图全屏会话的安全网：主线程卡死或遮罩霸屏时，仍能释放屏幕。
///
/// ## 为何旧实现“完全不起作用”
/// 1. 用 `DispatchQueue.main.async` 做心跳：拖拽时 RunLoop 在 **Tracking** 模式，
///    default 队列任务不跑，行为不可靠。
/// 2. 主线程其实空闲、只是遮罩吞事件时，心跳一直成功 → **永远不触发**。
/// 3. 紧急路径还依赖主线程 `forceCancel`，主线程死了就白搭。
///
/// ## 新策略（三层，均不依赖“主线程还活着才能杀进程”）
/// A. **Timer（.common）** 周期写心跳，含 tracking 和空闲等待  
/// B. **独立 pthread + usleep** 检测心跳超时 → 直接 `_exit(0)`（不经过主线程）  
/// C. **独立线程 CGEventTap**：会话中按 **Esc** 或 **⌘⌥⇧Esc**  
///    → 先尝试主线程取消，0.25s 仍在会话则 `_exit(0)`
final class MainThreadWatchdog: @unchecked Sendable {
    static let shared = MainThreadWatchdog()

    /// 主线程（含 tracking）无心跳多久 → 硬退出
    private let hangThresholdNs: UInt64 = 2_500_000_000 // 2.5s
    private let pollIntervalUs: useconds_t = 200_000 // 0.2s

    private let lock = NSLock()
    private var captureActive = false
    /// 单调时钟纳秒（mach_absolute_time 换算后），避免墙钟回拨
    private var lastBeatNs: UInt64 = 0
    /// 文字框几何拖拽开始时间；主线程假死（RunLoop 仍转）时用时长兜底
    private var geometryDragStartNs: UInt64 = 0
    private var geometryDragging = false
    private let geometryDragMaxNs: UInt64 = 6_000_000_000 // 6s
    private var installed = false
    private var heartbeatTimer: Timer?
    private var watchdogThread: Thread?
    private var tapThread: Thread?
    private var eventTap: CFMachPort?

    private init() {}

    // MARK: - Public

    var isCaptureActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return captureActive
    }

    func install() {
        lock.lock()
        if installed {
            lock.unlock()
            return
        }
        installed = true
        lock.unlock()

        installHeartbeatTimerOnMain()
        startWatchdogThread()
        startEmergencyEventTapThread()
        noteMainAlive()
        NSLog("[SnapFlow] Watchdog v2 installed (hang=2.5s, Esc emergency, hard _exit)")
    }

    func beginCaptureSession() {
        lock.lock()
        captureActive = true
        lock.unlock()
        noteMainAlive()
        NSLog("[SnapFlow] watchdog: capture BEGIN pid=\(getpid())")
    }

    func endCaptureSession() {
        lock.lock()
        captureActive = false
        geometryDragging = false
        geometryDragStartNs = 0
        lock.unlock()
        NSLog("[SnapFlow] watchdog: capture END")
    }

    /// 主线程任意 commonModes 回调里可调用
    func noteMainAlive() {
        let now = monotonicNs()
        lock.lock()
        lastBeatNs = now
        lock.unlock()
    }

    /// 文字框拉伸/移动/旋转：主线程仍可能“假死”（RunLoop 忙但界面不动）
    func noteGeometryDrag(_ active: Bool) {
        let now = monotonicNs()
        lock.lock()
        geometryDragging = active
        geometryDragStartNs = active ? now : 0
        if active { lastBeatNs = now }
        lock.unlock()
        if active {
            NSLog("[SnapFlow] watchdog: geometry drag BEGIN")
        } else {
            NSLog("[SnapFlow] watchdog: geometry drag END")
        }
    }

    /// 立刻硬退出（可从任意线程调用）
    func hardExitNow(reason: String) {
        NSLog("[SnapFlow] WATCHDOG HARD EXIT: \(reason) pid=\(getpid())")
        // 尽量恢复光标形态（best-effort，可能失败）
        fputs("[SnapFlow] emergency hard exit\n", stderr)
        fflush(stderr)
        _exit(0)
    }

    // MARK: - Monotonic time

    private func monotonicNs() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let t = mach_absolute_time()
        return t * UInt64(info.numer) / UInt64(info.denom)
    }

    // MARK: - A. Main RunLoop heartbeat（含 tracking 和空闲）

    private func installHeartbeatTimerOnMain() {
        let work = { [weak self] in
            guard let self else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                self?.noteMainAlive()
            }
            timer.tolerance = 0.05
            RunLoop.main.add(timer, forMode: .common)
            self.lock.lock()
            self.heartbeatTimer = timer
            self.lock.unlock()
        }
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    // MARK: - B. 独立线程轮询（纯 usleep，不走 GCD 主队列）

    private func startWatchdogThread() {
        // 捕获常量，避免后台线程反复读 self 的存储属性触发 Swift exclusivity / beginAccess
        let interval = pollIntervalUs
        let thread = Thread { [weak self] in
            Thread.current.qualityOfService = .userInteractive
            Thread.current.name = "snapflow.watchdog"
            while !Thread.current.isCancelled {
                usleep(interval)
                self?.watchdogPoll()
            }
        }
        thread.qualityOfService = .userInteractive
        thread.name = "snapflow.watchdog"
        thread.start()
        watchdogThread = thread
    }

    private func watchdogPoll() {
        lock.lock()
        let active = captureActive
        let last = lastBeatNs
        let geo = geometryDragging
        let geoStart = geometryDragStartNs
        lock.unlock()

        guard active else { return }

        let now = monotonicNs()

        // 几何拖拽超过 6s：先尝试取消会话，再硬退（假死时 RunLoop 仍可能有心跳）
        if geo, geoStart > 0, now > geoStart, now - geoStart >= geometryDragMaxNs {
            NSLog("[SnapFlow] watchdog: geometry drag >6s — force cancel then hard exit")
            DispatchQueue.main.async {
                RegionSelectorController.forceCancel()
            }
            // 0.3s 后无论是否取消成功都硬退，保证放屏
            usleep(300_000)
            hardExitNow(reason: "geometry drag stuck >6s")
            return
        }

        guard last > 0 else { return }
        let lag = now > last ? now - last : 0
        if lag >= hangThresholdNs {
            hardExitNow(reason: "main RunLoop silent for \(Double(lag) / 1e9)s during capture")
        }
    }

    // MARK: - C. 独立线程 Event Tap（Esc 紧急出口）

    private func startEmergencyEventTapThread() {
        let thread = Thread { [weak self] in
            self?.runEventTapLoop()
        }
        thread.qualityOfService = .userInteractive
        thread.name = "snapflow.emergency-tap"
        thread.start()
        tapThread = thread
    }

    private func runEventTapLoop() {
        // 需要辅助功能权限；失败则只依赖 hang 检测
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else {
                return Unmanaged.passUnretained(event)
            }
            let dog = Unmanaged<MainThreadWatchdog>.fromOpaque(refcon).takeUnretainedValue()

            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = dog.eventTap {
                    CGEvent.tapEnable(tap: tap, enable: true)
                }
                return Unmanaged.passUnretained(event)
            }

            guard type == .keyDown else {
                return Unmanaged.passUnretained(event)
            }

            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            // Esc = 53
            // 会话中：Esc → 请求取消；⌘⌥⇧Esc → 立即硬退
            if keycode == 53, dog.isCaptureActive {
                let forceCombo =
                    flags.contains(.maskCommand)
                    && flags.contains(.maskAlternate)
                    && flags.contains(.maskShift)

                if forceCombo {
                    dog.hardExitNow(reason: "user ⌘⌥⇧Esc during capture")
                    return nil // swallow
                }

                // 普通 Esc：主线程取消 + 短延时硬退兜底
                DispatchQueue.main.async {
                    RegionSelectorController.forceCancel()
                    MainThreadWatchdog.shared.endCaptureSession()
                }
                DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.35) {
                    if MainThreadWatchdog.shared.isCaptureActive {
                        MainThreadWatchdog.shared.hardExitNow(
                            reason: "Esc cancel did not clear session in 0.35s"
                        )
                    }
                }
            }

            return Unmanaged.passUnretained(event)
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: refcon
        ) else {
            NSLog("[SnapFlow] Watchdog: CGEventTap create FAILED (need Accessibility). Hang-kill still active.")
            // 无 tap 时仍靠 hang 检测；另起一个“仅会话 Esc 用 Carbon 无效”时的兜底：延长无操作不会杀
            return
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        NSLog("[SnapFlow] Watchdog: emergency Esc event-tap running on background thread")
        CFRunLoopRun()
    }
}
