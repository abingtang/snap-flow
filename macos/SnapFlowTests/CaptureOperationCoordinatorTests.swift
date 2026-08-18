import XCTest
@testable import SnapFlow

final class CaptureOperationCoordinatorTests: XCTestCase {
    @MainActor
    func testReplacingSameKindCancelsPreviousAndInvalidatesItsToken() async {
        let coordinator = CaptureOperationCoordinator()
        let first = coordinator.start(kind: .service) { _ in
            try? await Task.sleep(for: .seconds(60))
        }

        await Task.yield()
        let second = coordinator.start(kind: .service) { _ in
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertTrue(first.task.isCancelled)
        XCTAssertFalse(coordinator.isCurrent(first.token))
        XCTAssertTrue(coordinator.isCurrent(second.token))

        coordinator.finish(first.token)
        XCTAssertTrue(coordinator.isCurrent(second.token))

        coordinator.cancel(second.token)
    }

    @MainActor
    func testReplacingDifferentKindLeavesPreviousOperationRunning() async {
        let coordinator = CaptureOperationCoordinator()
        let service = coordinator.start(kind: .service) { _ in
            try? await Task.sleep(for: .seconds(60))
        }

        await Task.yield()
        let screenshot = coordinator.start(kind: .screenshot) { _ in
            try? await Task.sleep(for: .seconds(60))
        }

        XCTAssertFalse(service.task.isCancelled)
        XCTAssertTrue(coordinator.isCurrent(service.token))
        XCTAssertTrue(coordinator.isCurrent(screenshot.token))

        coordinator.cancel(service.token)
        coordinator.cancel(screenshot.token)
    }
}
