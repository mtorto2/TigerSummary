import AppKit
import UniformTypeIdentifiers

enum TigerTheme {
    static let pageBackground = NSColor(red: 0.035, green: 0.031, blue: 0.043, alpha: 1)
    static let panelBackground = NSColor(red: 0.055, green: 0.043, blue: 0.068, alpha: 1)
    static let readerBackground = NSColor(red: 0.024, green: 0.022, blue: 0.03, alpha: 1)
    static let tigerDroppingsPurple = NSColor(red: 0.314, green: 0.035, blue: 0.455, alpha: 1)
    static let tigerDroppingsDarkPurple = NSColor(red: 0.239, green: 0.031, blue: 0.345, alpha: 1)
    static let tigerDroppingsLightPurple = NSColor(red: 0.384, green: 0.133, blue: 0.51, alpha: 1)
    static let lsuGold = NSColor(red: 0.992, green: 0.815, blue: 0.14, alpha: 1)
    static let goldMuted = NSColor(red: 0.78, green: 0.61, blue: 0.16, alpha: 1)
    static let textPrimary = NSColor(white: 0.92, alpha: 1)
    static let textSecondary = NSColor(white: 0.68, alpha: 1)
    static let border = NSColor(red: 0.29, green: 0.21, blue: 0.37, alpha: 1)
}

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

final class SentimentGaugeView: NSView {
    private var positive = 0
    private var negative = 0
    private var neutral = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.backgroundColor = TigerTheme.panelBackground.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    func update(positive: Int, negative: Int, neutral: Int) {
        self.positive = max(0, min(100, positive))
        self.negative = max(0, min(100, negative))
        self.neutral = max(0, min(100, neutral))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rows = [
            ("Positive", positive, TigerTheme.lsuGold),
            ("Negative", negative, NSColor(red: 0.86, green: 0.23, blue: 0.25, alpha: 1)),
            ("Neutral", neutral, TigerTheme.tigerDroppingsLightPurple)
        ]

        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: TigerTheme.textSecondary
        ]
        let valueAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold),
            .foregroundColor: TigerTheme.textPrimary
        ]

        let left: CGFloat = 10
        let right: CGFloat = 10
        let top: CGFloat = 8
        let rowHeight: CGFloat = 17
        let labelWidth: CGFloat = 52
        let valueWidth: CGFloat = 34
        let barHeight: CGFloat = 6
        let barWidth = max(20, bounds.width - left - right - labelWidth - valueWidth - 12)

        for (index, row) in rows.enumerated() {
            let y = bounds.height - top - CGFloat(index + 1) * rowHeight
            row.0.draw(in: NSRect(x: left, y: y - 1, width: labelWidth, height: 14), withAttributes: labelAttrs)
            "\(row.1)%".draw(in: NSRect(x: bounds.width - right - valueWidth, y: y - 1, width: valueWidth, height: 14), withAttributes: valueAttrs)

            let trackRect = NSRect(x: left + labelWidth + 4, y: y + 3, width: barWidth, height: barHeight)
            TigerTheme.border.withAlphaComponent(0.55).setFill()
            NSBezierPath(roundedRect: trackRect, xRadius: 3, yRadius: 3).fill()

            let fillRect = NSRect(x: trackRect.minX, y: trackRect.minY, width: trackRect.width * CGFloat(row.1) / 100.0, height: trackRect.height)
            row.2.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3).fill()
        }
    }
}

final class SummaryWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "TigerSummarizer")
    private let subtitleLabel = NSTextField(labelWithString: "Drop or copy a TigerDroppings thread URL to begin.")
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressIndicator = NSProgressIndicator()
    private let gaugeView = SentimentGaugeView()
    private let progressPanel = NSView()
    private let progressTitleLabel = NSTextField(labelWithString: "Summarizing")
    private let progressDetailLabel = NSTextField(labelWithString: "Preparing thread...")
    private let progressBar = NSProgressIndicator()
    private var progressPanelHeightConstraint: NSLayoutConstraint?
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
        window.backgroundColor = TigerTheme.pageBackground

        let rootView = NSView()
        rootView.wantsLayer = true
        rootView.layer?.backgroundColor = TigerTheme.pageBackground.cgColor
        rootView.translatesAutoresizingMaskIntoConstraints = false

        let headerView = NSView()
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = TigerTheme.tigerDroppingsDarkPurple.cgColor
        headerView.layer?.cornerRadius = 10
        headerView.layer?.borderWidth = 1
        headerView.layer?.borderColor = TigerTheme.lsuGold.withAlphaComponent(0.32).cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSTextField(labelWithString: "TS")
        iconView.alignment = .center
        iconView.font = NSFont.systemFont(ofSize: 18, weight: .heavy)
        iconView.textColor = TigerTheme.tigerDroppingsDarkPurple
        iconView.wantsLayer = true
        iconView.layer?.backgroundColor = TigerTheme.lsuGold.cgColor
        iconView.layer?.cornerRadius = 8
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        titleLabel.textColor = TigerTheme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = TigerTheme.textSecondary
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusLabel.textColor = TigerTheme.lsuGold
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        gaugeView.translatesAutoresizingMaskIntoConstraints = false

        progressPanel.wantsLayer = true
        progressPanel.layer?.backgroundColor = TigerTheme.tigerDroppingsPurple.cgColor
        progressPanel.layer?.cornerRadius = 12
        progressPanel.layer?.borderWidth = 1
        progressPanel.layer?.borderColor = TigerTheme.lsuGold.withAlphaComponent(0.65).cgColor
        progressPanel.translatesAutoresizingMaskIntoConstraints = false

        progressTitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        progressTitleLabel.textColor = TigerTheme.textPrimary
        progressTitleLabel.translatesAutoresizingMaskIntoConstraints = false

        progressDetailLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        progressDetailLabel.textColor = TigerTheme.lsuGold.withAlphaComponent(0.82)
        progressDetailLabel.lineBreakMode = .byTruncatingTail
        progressDetailLabel.translatesAutoresizingMaskIntoConstraints = false

        progressBar.style = .bar
        progressBar.isIndeterminate = true
        progressBar.controlSize = .regular
        progressBar.translatesAutoresizingMaskIntoConstraints = false

        let contentCard = NSView()
        contentCard.wantsLayer = true
        contentCard.layer?.backgroundColor = TigerTheme.readerBackground.cgColor
        contentCard.layer?.cornerRadius = 12
        contentCard.layer?.borderWidth = 1
        contentCard.layer?.borderColor = TigerTheme.border.cgColor
        contentCard.translatesAutoresizingMaskIntoConstraints = false

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = TigerTheme.readerBackground
        textView.textColor = TigerTheme.textPrimary
        textView.insertionPointColor = TigerTheme.lsuGold
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
        rootView.addSubview(progressPanel)
        rootView.addSubview(contentCard)
        rootView.addSubview(actionBar)
        headerView.addSubview(iconView)
        headerView.addSubview(titleLabel)
        headerView.addSubview(subtitleLabel)
        headerView.addSubview(statusLabel)
        headerView.addSubview(progressIndicator)
        headerView.addSubview(gaugeView)
        progressPanel.addSubview(progressTitleLabel)
        progressPanel.addSubview(progressDetailLabel)
        progressPanel.addSubview(progressBar)
        contentCard.addSubview(scrollView)

        window.contentView = rootView
        super.init(window: window)

        configureActionButton(copyButton, action: #selector(copySummary))
        configureActionButton(exportButton, action: #selector(exportSummary))
        configureActionButton(openSavedButton, action: #selector(openSavedSummary))

        progressPanelHeightConstraint = progressPanel.heightAnchor.constraint(equalToConstant: 0)
        progressPanelHeightConstraint?.isActive = true

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
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: gaugeView.leadingAnchor, constant: -16),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            progressIndicator.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -18),
            progressIndicator.centerYAnchor.constraint(equalTo: headerView.topAnchor, constant: 24),
            progressIndicator.widthAnchor.constraint(equalToConstant: 18),
            progressIndicator.heightAnchor.constraint(equalToConstant: 18),

            statusLabel.trailingAnchor.constraint(equalTo: progressIndicator.leadingAnchor, constant: -10),
            statusLabel.centerYAnchor.constraint(equalTo: progressIndicator.centerYAnchor),
            statusLabel.widthAnchor.constraint(equalToConstant: 190),

            gaugeView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -18),
            gaugeView.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 32),
            gaugeView.widthAnchor.constraint(equalToConstant: 260),
            gaugeView.heightAnchor.constraint(equalToConstant: 58),

            progressPanel.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 14),
            progressPanel.leadingAnchor.constraint(equalTo: rootView.leadingAnchor, constant: 18),
            progressPanel.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -18),

            progressTitleLabel.leadingAnchor.constraint(equalTo: progressPanel.leadingAnchor, constant: 18),
            progressTitleLabel.topAnchor.constraint(equalTo: progressPanel.topAnchor, constant: 14),
            progressTitleLabel.widthAnchor.constraint(equalToConstant: 160),

            progressDetailLabel.leadingAnchor.constraint(equalTo: progressTitleLabel.trailingAnchor, constant: 12),
            progressDetailLabel.trailingAnchor.constraint(equalTo: progressPanel.trailingAnchor, constant: -18),
            progressDetailLabel.centerYAnchor.constraint(equalTo: progressTitleLabel.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: progressPanel.leadingAnchor, constant: 18),
            progressBar.trailingAnchor.constraint(equalTo: progressPanel.trailingAnchor, constant: -18),
            progressBar.topAnchor.constraint(equalTo: progressTitleLabel.bottomAnchor, constant: 12),

            contentCard.topAnchor.constraint(equalTo: progressPanel.bottomAnchor, constant: 14),
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
        button.contentTintColor = TigerTheme.tigerDroppingsPurple
    }

    func showReady() {
        titleLabel.stringValue = "TigerSummarizer"
        subtitleLabel.stringValue = "Copy a thread URL, use the menu, or drag a link onto TS."
        statusLabel.stringValue = "Ready"
        progressIndicator.stopAnimation(nil)
        progressBar.stopAnimation(nil)
        progressPanel.isHidden = true
        progressPanelHeightConstraint?.constant = 0
        gaugeView.update(positive: 0, negative: 0, neutral: 0)
        savedPath = nil
        summaryText = ""
        render(text: "Ready.\n\nCopy a TigerDroppings thread URL, click the TS menu bar item, then choose Summarize Clipboard URL.")
    }

    func showMessage(_ text: String) {
        titleLabel.stringValue = "TigerSummarizer"
        subtitleLabel.stringValue = ""
        statusLabel.stringValue = "Notice"
        progressIndicator.stopAnimation(nil)
        progressBar.stopAnimation(nil)
        progressPanel.isHidden = true
        progressPanelHeightConstraint?.constant = 0
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
        progressPanel.isHidden = false
        progressPanelHeightConstraint?.constant = 74
        progressTitleLabel.stringValue = "Summarizing"
        progressDetailLabel.stringValue = "Fetching thread and preparing the model run..."
        progressBar.startAnimation(nil)
        gaugeView.update(positive: 0, negative: 0, neutral: 0)
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
        progressDetailLabel.stringValue = latestLine
    }

    func appendSummary(_ text: String) {
        summaryText += text
        updateSentimentGauges(from: summaryText)
        render(text: summaryText)
    }

    func finish(success: Bool) {
        progressIndicator.stopAnimation(nil)
        progressBar.stopAnimation(nil)
        progressPanel.isHidden = true
        progressPanelHeightConstraint?.constant = 0
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
        let bodyColor = TigerTheme.textPrimary

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isHeading = isSectionHeading(trimmed)
            let isBullet = trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil
            let font = isHeading ? NSFont.systemFont(ofSize: 21, weight: .bold) : (isBullet ? NSFont.systemFont(ofSize: 16, weight: .medium) : bodyFont)
            let color = isHeading ? TigerTheme.lsuGold : bodyColor

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
        return line.range(of: #"^[A-J]\.\s"#, options: .regularExpression) != nil
    }

    private func updateSentimentGauges(from text: String) {
        guard
            let positive = firstPercent(after: "Positive", in: text),
            let negative = firstPercent(after: "Negative", in: text),
            let neutral = firstPercent(after: "Neutral", in: text)
        else {
            return
        }
        gaugeView.update(positive: positive, negative: negative, neutral: neutral)
    }

    private func firstPercent(after label: String, in text: String) -> Int? {
        let pattern = "\(label)[^0-9]{0,20}([0-9]{1,3})%"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard
            let match = regex.firstMatch(in: text, options: [], range: range),
            match.numberOfRanges > 1,
            let valueRange = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Int(text[valueRange])
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
