import AppKit
import UniformTypeIdentifiers

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
    private let titleLabel = NSTextField(labelWithString: "TigerSummarizer")
    private let subtitleLabel = NSTextField(labelWithString: "Drop or copy a TigerDroppings thread URL to begin.")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let copyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let exportButton = NSButton(title: "Export", target: nil, action: nil)
    private let openSavedButton = NSButton(title: "Open Saved", target: nil, action: nil)
    private var summaryText = ""
    private var savedPath: String?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "TigerSummarizer"
        window.center()
        window.backgroundColor = NSColor(red: 0.045, green: 0.045, blue: 0.05, alpha: 1)

        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = NSColor(red: 0.045, green: 0.045, blue: 0.05, alpha: 1).cgColor
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.078, alpha: 1).cgColor
        headerView.layer?.cornerRadius = 10
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSTextField(labelWithString: "TS")
        iconView.alignment = .center
        iconView.font = NSFont.systemFont(ofSize: 18, weight: .heavy)
        iconView.textColor = .white
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = NSColor(red: 0.82, green: 0.08, blue: 0.06, alpha: 1).cgColor
        iconView.layer?.cornerRadius = 8
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = NSColor(white: 0.66, alpha: 1)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = NSColor(white: 0.82, alpha: 1)
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        let contentCard = NSView()
        contentCard.wantsLayer = true
        contentCard.layer?.backgroundColor = NSColor(red: 0.027, green: 0.027, blue: 0.031, alpha: 1).cgColor
        contentCard.layer?.cornerRadius = 12
        contentCard.layer?.borderWidth = 1
        contentCard.layer?.borderColor = NSColor(white: 0.16, alpha: 1).cgColor
        contentCard.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = NSColor(red: 0.027, green: 0.027, blue: 0.031, alpha: 1)
        textView.textColor = NSColor(white: 0.88, alpha: 1)
        textView.insertionPointColor = .white
        textView.font = NSFont.systemFont(ofSize: 16, weight: .regular)
        textView.textContainerInset = NSSize(width: 22, height: 22)
        textView.textContainer?.lineFragmentPadding = 0
        scrollView.documentView = textView

        let actionBar = NSStackView()
        actionBar.orientation = .horizontal
        actionBar.spacing = 10
        actionBar.distribution = .fillEqually
        actionBar.translatesAutoresizingMaskIntoConstraints = false

        actionBar.addArrangedSubview(copyButton)
        actionBar.addArrangedSubview(exportButton)
        actionBar.addArrangedSubview(openSavedButton)

        rootView.addSubview(headerView)
        rootView.addSubview(contentCard)
        rootView.addSubview(actionBar)
        headerView.addSubview(iconView)
        headerView.addSubview(titleLabel)
        headerView.addSubview(subtitleLabel)
        headerView.addSubview(statusLabel)
        headerView.addSubview(progressIndicator)
        contentCard.addSubview(scrollView)

        window.contentView = rootView
        super.init(window: window)

        configureActionButton(copyButton, action: #selector(copySummary))
        configureActionButton(exportButton, action: #selector(exportSummary))
        configureActionButton(openSavedButton, action: #selector(openSavedSummary))

        NSLayoutConstraint.activate([
            headerView.topAnchor.constraint(equalTo: rootView.topAnchor, constant: 18),
            headerView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            headerView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            headerView.heightAnchor.constraint(equalToConstant: 82),

            iconView.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 18),
            iconView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 42),
            iconView.heightAnchor.constraint(equalToConstant: 42),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 18),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            progressIndicator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -18),
            progressIndicator.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            progressIndicator.heightAnchor.constraint(equalToConstant: 18),

            statusLabel.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 220),

            contentCard.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            contentCard.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            contentCard.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            contentCard.bottomAnchor.constraint(equalTo: actionBar.topAnchor, constant: -14),

            scrollView.topAnchor.constraint(equalTo: contentCard.topAnchor, constant: 1),
            scrollView.leadingAnchor.constraint(equalTo: contentCard.leadingAnchor, constant: 1),
            scrollView.trailingAnchor.constraint(equalTo: contentCard.trailingAnchor, constant: -1),
            scrollView.bottomAnchor.constraint(equalTo: contentCard.bottomAnchor, constant: -1),

            actionBar.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            actionBar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),
            actionBar.bottomAnchor.constraint(equalTo: rootView.bottomAnchor, constant: -18),
            actionBar.heightAnchor.constraint(equalToConstant: 44)
        ])

        showReady()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func configureActionButton(_ button: NSButton, action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        button.contentTintColor = .white
    }

    func showReady() {
        titleLabel.stringValue = "TigerSummarizer"
        subtitleLabel.stringValue = "Copy a thread URL, use the menu, or drag a link onto TS."
        statusLabel.stringValue = "Ready"
        progressIndicator.stopAnimation(nil)
        savedPath = nil
        summaryText = ""
        render(text: "Ready.\n\nCopy a TigerDroppings thread URL, click the TS menu bar item, then choose Summarize Clipboard URL.")
    }

    func showMessage(_ text: String) {
        titleLabel.stringValue = "TigerSummarizer"
        subtitleLabel.stringValue = ""
        statusLabel.stringValue = "Notice"
        progressIndicator.stopAnimation(nil)
        savedPath = nil
        summaryText = text
        render(text: text)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func start(url: String) {
        titleLabel.stringValue = "Summarizing Thread"
        subtitleLabel.stringValue = url
        statusLabel.stringValue = "Working..."
        progressIndicator.startAnimation(nil)
        savedPath = nil
        summaryText = ""
        render(text: "Summarizing...\n\n\(url)\n\nFetching thread pages, extracting posts, and generating the summary.")
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
        statusLabel.stringValue = latestLine
    }

    func appendSummary(_ text: String) {
        summaryText += text
        render(text: summaryText)
    }

    func finish(success: Bool) {
        progressIndicator.stopAnimation(nil)
        statusLabel.stringValue = success ? "Done" : "Failed"
        if !success && summaryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            render(text: "The summary failed. Check the terminal logs or try the CLI command directly.")
        }
    }

    private func render(text: String) {
        let attributed = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let bodyFont = NSFont.systemFont(ofSize: 16, weight: .regular)
        let bodyColor = NSColor(white: 0.86, alpha: 1)

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = isSectionHeading(trimmed)
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil
            let font = isHeading ? NSFont.systemFont(ofSize: 21, weight: .bold) : (isBullet ? NSFont.systemFont(ofSize: 16, weight: .medium) : bodyFont)
            let color = isHeading ? NSColor.white : bodyColor

            attributed.append(NSAttributedString(
                string: line + "\n",
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph
                ]
            ))
        }

        textView.textStorage?.setAttributedString(attributed)
    }

    private func isSectionHeading(_ line: String) -> Bool {
        if line.isEmpty { return false }
        if line.hasSuffix(":") && line.count < 80 { return true }
        return line.range(of: #"^[A-I]\.\s"#, options: .regularExpression) != nil
    }

    @objc private func copySummary() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summaryText, forType: .string)
        statusLabel.stringValue = "Copied"
    }

    @objc private func exportSummary() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "TigerSummary.txt"
        panel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = panel.url, let text = self?.summaryText else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                self?.statusLabel.stringValue = "Exported"
            } catch {
                self?.showMessage("Export failed.\n\n\(error)")
            }
        }
    }

    @objc private func openSavedSummary() {
        guard let savedPath else {
            statusLabel.stringValue = "No saved file yet"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: savedPath))
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

        let projectDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
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
                if finished.terminationStatus == 0 {
                    self?.summaryWindow.finish(success: true)
                } else {
                    self?.summaryWindow.finish(success: false)
                }
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
