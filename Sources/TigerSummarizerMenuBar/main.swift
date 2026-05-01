import AppKit
import UniformTypeIdentifiers
import WebKit

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

final class SummaryWindowController: NSWindowController, WKScriptMessageHandler, WKNavigationDelegate {
    private let webView: WKWebView
    private var summaryText = ""
    private var savedPath: String?
    private var webViewReady = false
    private var pendingScripts: [String] = []

    init() {
        let userContentController = WKUserContentController()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = userContentController

        webView = WKWebView(frame: .zero, configuration: configuration)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TigerSummarizer"
        window.center()
        window.backgroundColor = NSColor(red: 0.035, green: 0.031, blue: 0.043, alpha: 1)
        window.contentView = webView

        super.init(window: window)

        userContentController.add(self, name: "tigerAction")
        webView.navigationDelegate = self
        webView.setValue(false, forKey: "drawsBackground")
        loadWebApp()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "tigerAction")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webViewReady = true
        flushPendingScripts()
        waitForReactBridge(attempt: 0)
    }

    private func waitForReactBridge(attempt: Int) {
        webView.evaluateJavaScript("Boolean(window.TigerSummary)") { [weak self] result, _ in
            guard let self else { return }
            if let isReady = result as? Bool, isReady {
                self.showReady()
            } else if attempt < 20 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.waitForReactBridge(attempt: attempt + 1)
                }
            } else {
                self.showWebFallback("React viewer loaded, but the TigerSummary bridge did not initialize.")
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard
            message.name == "tigerAction",
            let body = message.body as? [String: Any],
            let action = body["action"] as? String
        else {
            return
        }

        switch action {
        case "copy":
            copySummary()
        case "export":
            exportSummary()
        case "openSaved":
            openSavedSummary()
        default:
            break
        }
    }

    func showReady() {
        savedPath = nil
        summaryText = ""
        setWebState([
            "mode": "ready",
            "title": "TigerSummarizer",
            "subtitle": "Copy a TigerDroppings thread URL, click TS, then summarize.",
            "status": "Ready",
            "summary": "Ready.\n\nCopy a TigerDroppings thread URL, click the TS menu bar item, then choose Summarize Clipboard URL.",
        ])
    }

    func showMessage(_ text: String) {
        savedPath = nil
        summaryText = text
        setWebState([
            "mode": "notice",
            "title": "TigerSummarizer",
            "subtitle": "",
            "status": "Notice",
            "summary": text,
        ])
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start(url: String) {
        savedPath = nil
        summaryText = ""
        setWebState([
            "mode": "running",
            "title": "Summarizing Thread",
            "subtitle": url,
            "status": "Fetching thread and preparing the model run...",
            "summary": "Summarizing...\n\n\(url)\n\nFetching thread pages, extracting posts, and generating the summary.",
        ])
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateStatus(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if let range = trimmed.range(of: "Saved summary: ") {
            savedPath = String(trimmed[range.upperBound...])
        }

        let latestLine = trimmed.split(separator: "\n").last.map(String.init) ?? trimmed
        setWebState([
            "status": latestLine,
            "savedPath": savedPath ?? "",
        ])
    }

    func appendSummary(_ text: String) {
        summaryText += text
        callWeb(function: "window.TigerSummary?.appendSummary", argument: text)
    }

    func finish(success: Bool) {
        if !success && summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            summaryText = "The summary failed. Check the terminal logs or try the CLI command directly."
        }
        setWebState([
            "mode": success ? "done" : "error",
            "status": success ? "Done" : "Failed",
            "summary": summaryText,
            "savedPath": savedPath ?? "",
        ])
    }

    private func loadWebApp() {
        let bundledIndexURL = Bundle.main.resourceURL?
            .appendingPathComponent("web")
            .appendingPathComponent("index.html")
        let projectIndexURL = Self.projectDirectory()
            .appendingPathComponent("build")
            .appendingPathComponent("web")
            .appendingPathComponent("index.html")
        let indexURL = [bundledIndexURL, projectIndexURL]
            .compactMap { $0 }
            .first { FileManager.default.fileExists(atPath: $0.path) }

        if let indexURL {
            webView.loadFileURL(indexURL, allowingReadAccessTo: indexURL.deletingLastPathComponent())
        } else {
            let fallback = """
            <html><body style="background:#09070d;color:#f0edf5;font-family:-apple-system;padding:24px">
            <h1>TigerSummarizer</h1>
            <p>React viewer is not built yet. Run <code>npm run build:web</code>.</p>
            </body></html>
            """
            webView.loadHTMLString(fallback, baseURL: nil)
        }
    }

    private func showWebFallback(_ message: String) {
        let escaped = message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let fallback = """
        document.body.innerHTML = '<main style="min-height:100vh;margin:0;padding:24px;background:#09070d;color:#f0edf5;font-family:-apple-system"><h1 style="color:#fddb3a">TigerSummarizer</h1><p>\(escaped)</p><p>Try rebuilding with <code>./scripts/package_menubar_app.sh</code>.</p></main>';
        """
        webView.evaluateJavaScript(fallback)
    }

    private func setWebState(_ state: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: state),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        evaluate("window.TigerSummary?.setState(\(json));")
    }

    private func callWeb(function: String, argument: String) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [argument]),
            let json = String(data: data, encoding: .utf8)
        else {
            return
        }
        evaluate("\(function)(\(json.dropFirst().dropLast()));")
    }

    private func evaluate(_ script: String) {
        guard webViewReady else {
            pendingScripts.append(script)
            return
        }
        webView.evaluateJavaScript(script)
    }

    private func flushPendingScripts() {
        let scripts = pendingScripts
        pendingScripts = []
        scripts.forEach(evaluate)
    }

    private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText, forType: .string)
        setWebState(["status": "Copied"])
    }

    private func exportSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "TigerSummary.txt"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let text = self?.summaryText else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.setWebState(["status": "Exported"])
            } catch {
                self?.showMessage("Export failed.\n\n\(error)")
            }
        }
    }

    private func openSavedSummary() {
        guard let savedPath, !savedPath.isEmpty else {
            setWebState(["status": "No saved file yet"])
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: savedPath))
    }

    static func projectDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
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
            summaryWindow.showMessage("Copy a TigerDroppings thread URL first, then choose Summarize Clipboard URL.")
            return
        }
        summarize(url: raw)
    }

    @objc private func showWindow() {
        summaryWindow.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quit() {
        runningProcess?.terminate()
        NSApp.terminate(nil)
    }

    private func summarize(url: String) {
        guard runningProcess == nil else {
            summaryWindow.showMessage("A summary is already running. Wait for it to finish, then try again.")
            return
        }

        let projectDir = SummaryWindowController.projectDirectory().path
        let runner = "\(projectDir)/run_tigersummarizer.sh"

        summaryWindow.start(url: url)
        statusItem.button?.title = "TS..."

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
                self?.summaryWindow.appendSummary(text)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                self?.summaryWindow.updateStatus(text)
            }
        }

        process.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self?.runningProcess = nil
                self?.statusItem.button?.title = "TS"
                self?.summaryWindow.finish(success: finished.terminationStatus == 0)
            }
        }

        do {
            runningProcess = process
            try process.run()
        } catch {
            runningProcess = nil
            statusItem.button?.title = "TS"
            summaryWindow.showMessage("Could not start TigerSummarizer.\n\n\(error)")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
