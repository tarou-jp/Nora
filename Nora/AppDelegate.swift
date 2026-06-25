import AppKit
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let panelController = PromptPanelController()
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey)) { [weak self] in
            DispatchQueue.main.async {
                self?.panelController.toggle()
            }
        }
    }
}
