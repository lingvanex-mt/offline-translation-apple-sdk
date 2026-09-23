//
// ViewController.swift
//
// A minimal, complete tour of the SDK: install the models bundled with the app —
// or fetch the sample ones when there are none — pick a pair, translate.
// Everything below is plain AppKit — the only model bookkeeping lives in
// Shared/Models.swift, which is yours to copy.
//

import Cocoa
import OfflineTranslator

final class ViewController: NSViewController {

    // MARK: - Model

    /// English plus every installed language.
    private var languages: [Language] = [.english]
    private var source: Language = .english
    private var target: Language = .english

    private let translator = PairTranslator()
    private var downloader: ModelsDownloader?

    /// Loading a model and translating both take seconds and must not run on the main
    /// thread; one serial queue keeps them in order — a translation waits for its load.
    private let engineQueue = DispatchQueue(label: "com.lingvanex.example.engine")
    private var isTranslating = false

    /// Why the current pair could not be loaded; `nil` when it is ready. Translating with
    /// no models loaded would hand the text back unchanged, which reads as a bug.
    private var pairError: Error?

    // MARK: - Views

    private let sourcePopUp = NSPopUpButton()
    private let targetPopUp = NSPopUpButton()
    private let swapButton = NSButton()
    private let translateButton = FilledButton()
    private let copyButton = NSButton()
    private let statsLabel = NSTextField(labelWithString: "")
    private let inputPlaceholder = NSTextField(labelWithString: "Type or paste text")
    private let outputPlaceholder = NSTextField(labelWithString: "Translation appears here")
    private let overlay = NSView()
    private let overlaySpinner = NSProgressIndicator()
    private let overlayLabel = NSTextField(wrappingLabelWithString: "Installing models…")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

    private var inputTextView = NSTextView()
    private var outputTextView = NSTextView()

    // MARK: - Lifecycle

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 600))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        installModels()
    }

    // MARK: - Models

    /// Installs every `.zip` shipped in the app bundle. Drop `models.zip` into the project
    /// and every language it carries shows up in the pickers — no code change needed.
    /// With no models at all, the sample ones are downloaded instead.
    private func installModels() {
        engineQueue.async { [weak self] in
            let languages = (try? ModelStore.installBundled()) ?? []
            DispatchQueue.main.async {
                guard let self = self else { return }
                if languages.isEmpty {
                    self.downloadSampleModels()
                } else {
                    self.show(languages: languages)
                }
            }
        }
    }

    /// Fetches the sample Portuguese models (87 MB, once). They land in Caches next to the
    /// bundled ones, so the next launch finds them installed and skips this.
    @objc private func downloadSampleModels() {
        retryButton.isHidden = true
        overlayLabel.stringValue = "Downloading the Portuguese sample models…"
        setOverlay(visible: true)
        downloader = ModelsDownloader(
            progress: { [weak self] received, expected in
                let formatter = ByteCountFormatter()
                var text = "Downloading the Portuguese sample models…\n\(formatter.string(fromByteCount: received))"
                if expected > 0 {
                    text += " of \(formatter.string(fromByteCount: expected))"
                }
                self?.overlayLabel.stringValue = text
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.downloader = nil
                switch result {
                case .success(let languages):
                    self.show(languages: languages)
                case .failure(let error):
                    self.overlaySpinner.stopAnimation(nil)
                    self.overlayLabel.stringValue = "Could not download the sample models.\n\(error.localizedDescription)"
                    self.retryButton.isHidden = false
                }
            }
        )
        downloader?.start()
    }

    private func show(languages installed: [Language]) {
        languages = [.english] + installed.sorted { displayName(of: $0) < displayName(of: $1) }

        // Start on a pair that is actually installed: an archive may carry `<lang>_en`
        // and not `en_<lang>`, and opening on the missing direction looks broken.
        let language = languages.first { !$0.isEnglish } ?? .english
        let intoLanguage = ModelStore.hasModel(from: .english, to: language)
        source = intoLanguage ? .english : language
        target = intoLanguage ? language : .english

        reloadLanguageMenus()
        applyLanguagePair()
        setOverlay(visible: false)
    }

    private func displayName(of language: Language) -> String {
        let code = language.code
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    private func reloadLanguageMenus() {
        let titles = languages.map { displayName(of: $0) }
        for popUp in [sourcePopUp, targetPopUp] {
            popUp.removeAllItems()
            popUp.addItems(withTitles: titles)
        }
    }

    // MARK: - Actions

    @objc private func sourceChanged() {
        guard sourcePopUp.indexOfSelectedItem >= 0, sourcePopUp.indexOfSelectedItem < languages.count else { return }
        source = languages[sourcePopUp.indexOfSelectedItem]
        if source.code == target.code {
            target = languages.first { $0.code != source.code } ?? .english
        }
        applyLanguagePair()
    }

    @objc private func targetChanged() {
        guard targetPopUp.indexOfSelectedItem >= 0, targetPopUp.indexOfSelectedItem < languages.count else { return }
        target = languages[targetPopUp.indexOfSelectedItem]
        if target.code == source.code {
            source = languages.first { $0.code != target.code } ?? .english
        }
        applyLanguagePair()
    }

    @objc private func swapLanguages() {
        let old = source
        source = target
        target = old
        let translated = outputTextView.string
        if !translated.isEmpty {
            inputTextView.string = translated
            outputTextView.string = ""
            refreshPlaceholders()
        }
        applyLanguagePair()
    }

    @objc private func translate() {
        let text = inputTextView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isTranslating else { return }
        isTranslating = true
        refreshTranslateButton()
        statsLabel.isHidden = false
        statsLabel.stringValue = "Translating…"

        let started = CFAbsoluteTimeGetCurrent()
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            let result = Result { try self.translator.translate(text) }
            DispatchQueue.main.async {
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                self.isTranslating = false
                self.refreshTranslateButton()
                switch result {
                case .success(let translation):
                    self.outputTextView.string = translation
                    let megabytes = self.residentMemory() / 1_048_576
                    self.statsLabel.stringValue = String(format: "%.2f s · %llu MB memory", elapsed, megabytes)
                case .failure(let error):
                    self.outputTextView.string = ""
                    self.statsLabel.stringValue = "Translation failed: \(error.localizedDescription)"
                }
                self.refreshPlaceholders()
            }
        }
    }

    @objc private func copyTranslation() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(outputTextView.string, forType: .string)
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        }
    }

    // MARK: - State

    private func applyLanguagePair() {
        if let index = languages.firstIndex(where: { $0.code == source.code }) {
            sourcePopUp.selectItem(at: index)
        }
        if let index = languages.firstIndex(where: { $0.code == target.code }) {
            targetPopUp.selectItem(at: index)
        }
        refreshTranslateButton()

        // The sample models are unencrypted, so no license is set. For encrypted models
        // assign translator.license once, before loading a pair.
        let pair = (source: source, target: target)
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            let error: Error? = Result { try self.translator.setup(from: pair.source, to: pair.target) }.failureError
            DispatchQueue.main.async {
                guard pair.source == self.source, pair.target == self.target else {
                    return   // the user has picked another pair in the meantime
                }
                // Without this branch a missing model would look like a translation
                // that changed nothing, which reads as a bug.
                self.pairError = error
                self.statsLabel.isHidden = error == nil
                if let error = error {
                    self.statsLabel.stringValue = error.localizedDescription
                }
                self.refreshTranslateButton()
            }
        }
    }

    private func refreshTranslateButton() {
        let hasText = !inputTextView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        translateButton.isEnabled = hasText && !isTranslating && pairError == nil
        translateButton.setFilledTitle(isTranslating ? "Translating…" : "Translate")
        translateButton.needsDisplay = true
    }

    private func refreshPlaceholders() {
        inputPlaceholder.isHidden = !inputTextView.string.isEmpty
        let hasOutput = !outputTextView.string.isEmpty
        outputPlaceholder.isHidden = hasOutput
        copyButton.isHidden = !hasOutput
    }

    private func setOverlay(visible: Bool) {
        overlay.isHidden = !visible
        visible ? overlaySpinner.startAnimation(nil) : overlaySpinner.stopAnimation(nil)
    }

    private func residentMemory() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    // MARK: - Interface

    private func buildInterface() {
        let title = NSTextField(labelWithString: "Offline Translation")
        title.font = .systemFont(ofSize: 26, weight: .bold)

        let subtitle = NSTextField(labelWithString: "Runs on device. Nothing is sent anywhere.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor

        // Language bar -------------------------------------------------------
        for popUp in [sourcePopUp, targetPopUp] {
            popUp.bezelStyle = .rounded
            popUp.controlSize = .large
            popUp.addItems(withTitles: ["English"])
        }
        sourcePopUp.target = self
        sourcePopUp.action = #selector(sourceChanged)
        targetPopUp.target = self
        targetPopUp.action = #selector(targetChanged)

        swapButton.image = NSImage(systemSymbolName: "arrow.left.arrow.right",
                                   accessibilityDescription: "Swap languages")
        swapButton.isBordered = false
        swapButton.contentTintColor = .controlAccentColor
        swapButton.target = self
        swapButton.action = #selector(swapLanguages)
        swapButton.setContentHuggingPriority(.required, for: .horizontal)

        let languageRow = NSStackView(views: [
            caption("From"), sourcePopUp, swapButton, caption("To"), targetPopUp
        ])
        languageRow.orientation = .horizontal
        languageRow.alignment = .centerY
        languageRow.spacing = 8
        sourcePopUp.widthAnchor.constraint(equalTo: targetPopUp.widthAnchor).isActive = true
        let languageCard = card(wrapping: languageRow, padding: 12)

        // Input --------------------------------------------------------------
        let (inputScroll, input) = makeTextView(editable: true)
        inputTextView = input
        inputTextView.delegate = self
        inputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let inputCard = card(wrapping: inputScroll, padding: 12)
        place(inputPlaceholder, inTopLeftOf: inputCard, inset: 12)

        // Translate ----------------------------------------------------------
        translateButton.setFilledTitle("Translate")
        translateButton.isBordered = false
        translateButton.wantsLayer = true
        translateButton.target = self
        translateButton.action = #selector(translate)
        translateButton.heightAnchor.constraint(equalToConstant: 40).isActive = true
        translateButton.keyEquivalent = "\r"

        // Output -------------------------------------------------------------
        let (outputScroll, output) = makeTextView(editable: false)
        outputTextView = output
        outputScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        let outputCard = card(wrapping: outputScroll, padding: 12)
        place(outputPlaceholder, inTopLeftOf: outputCard, inset: 12)

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy")
        copyButton.isBordered = false
        copyButton.contentTintColor = .controlAccentColor
        copyButton.target = self
        copyButton.action = #selector(copyTranslation)
        copyButton.isHidden = true
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        outputCard.addSubview(copyButton)
        NSLayoutConstraint.activate([
            copyButton.trailingAnchor.constraint(equalTo: outputCard.trailingAnchor, constant: -10),
            copyButton.bottomAnchor.constraint(equalTo: outputCard.bottomAnchor, constant: -8)
        ])

        // Stats --------------------------------------------------------------
        statsLabel.font = .systemFont(ofSize: 12)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .center
        statsLabel.isHidden = true

        // Assembly -----------------------------------------------------------
        let stack = NSStackView(views: [
            title, subtitle, languageCard, inputCard, translateButton, outputCard, statsLabel
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(2, after: title)
        stack.setCustomSpacing(20, after: subtitle)
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24)
        ])
        for filling in [languageCard, inputCard, outputCard, translateButton, statsLabel] {
            filling.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        // Install overlay ----------------------------------------------------
        overlay.wantsLayer = true
        overlaySpinner.style = .spinning
        overlaySpinner.isIndeterminate = true
        overlayLabel.textColor = .secondaryLabelColor
        overlayLabel.alignment = .center
        overlayLabel.preferredMaxLayoutWidth = 400
        retryButton.target = self
        retryButton.action = #selector(downloadSampleModels)
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        let overlayStack = NSStackView(views: [overlaySpinner, overlayLabel, retryButton])
        overlayStack.orientation = .vertical
        overlayStack.spacing = 10
        overlayStack.alignment = .centerX
        overlay.addSubview(overlayStack)
        view.addSubview(overlay)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlayStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            overlayStack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            overlayStack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            overlayStack.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
        setOverlay(visible: true)

        refreshPlaceholders()
        refreshTranslateButton()
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text.uppercased())
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    private func makeTextView(editable: Bool) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView()
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.drawsBackground = false
        textView.isEditable = editable
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        scroll.documentView = textView
        return (scroll, textView)
    }

    private func place(_ label: NSTextField, inTopLeftOf container: NSView, inset: CGFloat) {
        label.font = .systemFont(ofSize: 14)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: inset),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: inset)
        ])
    }

    private func card(wrapping content: NSView, padding: CGFloat) -> NSView {
        let container = CardView()
        container.wantsLayer = true
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding)
        ])
        return container
    }
}

// MARK: - NSTextViewDelegate

extension ViewController: NSTextViewDelegate {

    func textDidChange(_ notification: Notification) {
        refreshPlaceholders()
        refreshTranslateButton()
    }
}

// MARK: - Layer-backed pieces
//
// `cgColor` does not follow light/dark appearance changes on its own, so both
// views repaint themselves in `updateLayer`.

private final class CardView: NSView {

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.cornerRadius = 12
    }
}

private final class FilledButton: NSButton {

    override var wantsUpdateLayer: Bool {
        return true
    }

    override func updateLayer() {
        layer?.backgroundColor = (isEnabled ? NSColor.controlAccentColor : NSColor.quaternaryLabelColor).cgColor
        layer?.cornerRadius = 10
    }

    func setFilledTitle(_ text: String) {
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: {
                let style = NSMutableParagraphStyle()
                style.alignment = .center
                return style
            }()
        ])
    }
}

// MARK: - Result

private extension Result {

    /// The error of a failed result, `nil` when it succeeded.
    var failureError: Failure? {
        guard case .failure(let error) = self else {
            return nil
        }
        return error
    }
}
