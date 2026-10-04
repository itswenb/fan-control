import AppKit

/// 关闭普通窗口后保留菜单栏；不替换 SwiftUI 管理的窗口 delegate。
@MainActor
final class AppWindowVisibility: NSObject {
    var onVisibilityChange: ((Bool) -> Void)?

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(self, selector: #selector(windowOcclusionChanged), name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didMiniaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowChanged), name: NSWindow.didDeminiaturizeNotification, object: nil)
        center.addObserver(self, selector: #selector(windowClosed), name: NSWindow.willCloseNotification, object: nil)
        refresh(hideDockWhenEmpty: true)
    }

    func stop() { NotificationCenter.default.removeObserver(self) }

    static func prepareToOpen() { NSApp.setActivationPolicy(.regular) }

    private func refresh(hideDockWhenEmpty: Bool = false) {
        let windows = NSApp.windows.filter { $0.styleMask.contains(.titled) && $0.parent == nil }
        let hasWindow = windows.contains { $0.isVisible || $0.isMiniaturized }
        if hasWindow, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        } else if !hasWindow, hideDockWhenEmpty, NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.accessory)
        }
        // 最小化窗口仍在 Dock，但不需要持续刷新完整监控列表。
        onVisibilityChange?(windows.contains { $0.isVisible && !$0.isMiniaturized })
    }

    @objc private func windowChanged() { refresh() }
    @objc private func windowOcclusionChanged() {
        // 最小化动画中存在短暂的“不可见但尚未最小化”状态，不能因此隐藏 Dock。
        refresh()
    }
    @objc private func windowClosed(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              window.styleMask.contains(.titled), window.parent == nil else { return }
        // willClose 发生时窗口仍可见，等 AppKit 完成关闭再统计。
        DispatchQueue.main.async { [weak self] in self?.refresh(hideDockWhenEmpty: true) }
    }
}
