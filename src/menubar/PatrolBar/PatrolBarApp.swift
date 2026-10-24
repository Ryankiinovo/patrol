import AppKit
import SwiftUI

@main
struct PatrolBarApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = MonitorModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.attributedTitle = title("—°", color: NSColor.secondaryLabelColor)
            button.target = self
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp])
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = NSSize(width: 304, height: 380)
        popover.contentViewController = NSHostingController(rootView: PopoverView(model: model))

        model.onUpdate = { [weak self] snap in
            guard let self else { return }
            guard let snap, snap.temp_c > 0 else {
                self.statusItem.button?.attributedTitle = self.title("—°", color: NSColor.secondaryLabelColor)
                return
            }
            let color: NSColor = snap.temp_c >= 85 ? .systemRed
                : (snap.temp_c >= 78 ? .systemOrange : .labelColor)
            self.statusItem.button?.attributedTitle = self.title(
                String(format: "%.0f°", snap.temp_c),
                color: color
            )
        }

        model.start()

        // 自测开关：PATROL_POPOVER=1 启动后自动展开面板（用于截图验收）
        if ProcessInfo.processInfo.environment["PATROL_POPOVER"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.showPopover()
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if let window = self.statusItem.button?.window {
                NSLog("[patrol] status item window=%@", NSStringFromRect(window.frame))
            }
        }
    }

    private func title(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
        ])
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        guard !popover.isShown else { return }
        model.refresh()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    @objc private func handleClick() {
        NSLog("[patrol] click, shown=%@", popover.isShown ? "yes" : "no")
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }
}
