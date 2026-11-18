import AppKit

@main
@MainActor
struct PaletteCoordinatorTests {
    static var failures = 0

    static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            failures += 1
            print("FAIL: \(message)")
        }
    }

    static func main() {
        for mode in PaletteMode.allCases {
            let state = PaletteState()
            let window = PaletteWindowController(state: state)
            let coordinator = PaletteCoordinator(
                palette: state, settings: AppSettings(), appIndex: AppIndex(),
                fileSearch: FileSearchSession(), menuSearch: MenuSearchSession(),
                windowSwitch: WindowSwitchSession(), windowController: window)
            state.prepare(mode: .launcher)
            if mode != .launcher { state.push(mode: mode) }
            state.query = "saved query"
            state.selection = 3
            window.isVisible = true
            let stack = state.backStack

            coordinator.togglePalette()
            expect(!window.isVisible, "main shortcut hides \(mode)")
            coordinator.togglePalette()
            expect(
                window.isVisible && state.mode == mode && state.query == "saved query"
                    && state.selection == 3 && state.backStack == stack,
                "reopening before timeout restores \(mode) and its navigation")

            coordinator.togglePalette()
            window.popToRootNow()
            coordinator.togglePalette()
            expect(
                window.isVisible && state.mode == .launcher && state.query.isEmpty && !state.canGoBack,
                "reopening after timeout opens fresh root search from \(mode)")

            state.push(mode: mode)
            state.query = "discarded query"
            coordinator.closePalette()
            expect(
                !window.isVisible && !window.preserved && state.mode == .launcher
                    && state.query.isEmpty && !state.canGoBack,
                "closing \(mode) immediately resets navigation despite the pending timeout")
            coordinator.togglePalette()
            expect(
                window.isVisible && state.mode == .launcher && state.query.isEmpty && !state.canGoBack,
                "the main shortcut after closing \(mode) opens fresh root search")
        }
        print("\(failures) failure(s)")
        if failures > 0 { exit(1) }
    }
}

@MainActor
final class PaletteWindowController {
    let state: PaletteState
    var isVisible = false
    var isPoppedToRoot = false
    var preserved = false
    var previousApp: NSRunningApplication? { nil }
    var previousOwnWindow: NSWindow? { nil }
    var previousTarget: InjectionTarget? { nil }
    var visibleFrame: CGRect? { nil }
    var anchorView: NSView? { nil }

    init(state: PaletteState) { self.state = state }
    func show() { isVisible = true; isPoppedToRoot = false }
    func hide(restoreFocus: Bool) { isVisible = false; preserved = true }
    func consumePreservedState() -> Bool {
        defer { preserved = false }
        return preserved
    }
    func popToRootNow() {
        preserved = false
        state.prepare(mode: .launcher)
        isPoppedToRoot = true
    }
    func applyCollapsed(_ collapsed: Bool) {}
    func beginDrag() {}
    func endDrag() {}
}

enum InjectionTarget {}

@MainActor
final class AppSettings { var compactMode = false }

@MainActor
final class AppIndex { func refresh() async {} }

@MainActor
final class FileSearchSession { func search(_ query: String) {} }

@MainActor
final class MenuSearchSession {
    func filter(_ query: String) {}
    func reset() {}
}

@MainActor
final class WindowSwitchSession {
    func filter(_ query: String) {}
    func reset() {}
}

enum FrontmostApp { static var current: NSRunningApplication? { nil } }

struct AppEntry {
    let id: String
    let name: String
}
