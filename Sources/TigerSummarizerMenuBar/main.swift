import AppKit

final class DropOverlayView: NSView {
    var onURL: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.URL, .string])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.URL, .string])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        return readURL(from: sender.draggingPasteboard) == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let url = readURL(from: sender.draggingPasteboard) else {
            return false
        }
        onURL?(url)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        nextResponder?.mouseDown(with: event)
    }

    private func readURL(from pasteboard: NSPasteboard) -> String? {
        if let url = NSURL(from: pasteboard) as URL? {
            return url.absoluteString
        }
        guard let raw = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("http") else {
            return nil
        }
        return raw
    }
}

final class SummaryWindowController: NSWindowController {
    private let textView = NSTextView()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TigerSummarizer"
        window.center()

        let scrollView = NSScrollView(frame: window.contentView?.bounds ?? .zero)
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false

        textView.isEditable = false
        textView.isRichText = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)
        scrollView.documentView = textView

        window.contentView = scrollView
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show(_ text: String) {
        textView.string = text
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func append(_ text: String) {
        textView.string += text
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let summaryWindow = SummaryWindowController()
    private var runningProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.title = "TS"
            button.toolTip = "Drop a TigerDroppings thread URL here, or use the menu."

            let overlay = DropOverlayView(frame: button.bounds)
            overlay.autoresizingMask = [.width, .height]
            overlay.onURL = { [weak self] url in
                self?.summarize(url: url)
            }
            button.addSubview(overlay)
        }

        let menu = NSMenu()
        menu.addItem(menuItem(title: "Summarize Clipboard URL", action: #selector(summarizeClipboard), keyEquivalent: "s"))
        menu.addItem(menuItem(title: "Show Window", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(menuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func summarizeClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              raw.hasPrefix("http") else {
            summaryWindow.show("Copy a TigerDroppings thread URL first, then choose Summarize Clipboard URL.")
            return
        }
        summarize(url: raw)
    }

    @objc private func showWindow() {
        summaryWindow.show(summaryWindow.window?.title ?? "TigerSummarizer is ready.")
    }

    @objc private func quit() {
        runningProcess?.terminate()
        NSApp.terminate(nil)
    }

    private func summarize(url: String) {
        guard runningProcess == nil else {
            summaryWindow.show("A summary is already running. Wait for it to finish, then try again.")
            return
        }

        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let runner = "\(projectDir)/run_tigersummarizer.sh"

        summaryWindow.show("Summarizing...\n\n\(url)\n\n")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: runner)
        process.arguments = [url, "--notify-projecthub"]
        process.currentDirectoryURL = URL(fileURLWithPath: projectDir)

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.summaryWindow.append(text)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.summaryWindow.append(text)
            }
        }

        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.runningProcess = nil
                if finished.terminationStatus == 0 {
                    self?.summaryWindow.append("\n\nDone.")
                } else {
                    self?.summaryWindow.append("\n\nFailed with exit code \(finished.terminationStatus).")
                }
            }
        }

        do {
            runningProcess = process
            try process.run()
        } catch {
            runningProcess = nil
            summaryWindow.show("Could not start TigerSummarizer.\n\n\(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
