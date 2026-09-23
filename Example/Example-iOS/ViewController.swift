//
// ViewController.swift
//
// A minimal, complete tour of the SDK: install the models bundled with the app —
// or fetch the sample ones when there are none — pick a pair, translate.
// Everything below is plain UIKit; the model bookkeeping lives in
// Shared/Models.swift, which is yours to copy.
//

import UIKit
import OfflineTranslator

final class ViewController: UIViewController {

    // MARK: - Model

    /// English plus every installed language.
    private var languages: [Language] = [.english]
    private var source: Language = .english
    private var target: Language = .english

    private let translator = PairTranslator()
    private var downloader: ModelsDownloader?
    private var isTranslating = false

    /// Why the current pair could not be loaded; `nil` when it is ready. Translating with
    /// no models loaded would hand the text back unchanged, which reads as a bug.
    private var pairError: Error?

    /// Loading a model and translating both take seconds and must not run on the main
    /// thread; one serial queue keeps them in order — a translation waits for its load.
    private let engineQueue = DispatchQueue(label: "com.lingvanex.example.engine")

    // MARK: - Views

    private let scrollView = UIScrollView()
    private let sourceButton = UIButton(type: .system)
    private let targetButton = UIButton(type: .system)
    private let swapButton = UIButton(type: .system)
    private let inputTextView = UITextView()
    private let inputPlaceholder = UILabel()
    private let translateButton = UIButton(type: .system)
    private let outputTextView = UITextView()
    private let outputPlaceholder = UILabel()
    private let copyButton = UIButton(type: .system)
    private let statsLabel = UILabel()
    private let overlay = UIView()
    private let overlaySpinner = UIActivityIndicatorView(style: .large)
    private let overlayLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        buildInterface()
        installModels()
        observeKeyboard()
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
        overlayLabel.text = "Downloading the Portuguese sample models…"
        setOverlay(visible: true)
        downloader = ModelsDownloader(
            progress: { [weak self] received, expected in
                let formatter = ByteCountFormatter()
                var text = "Downloading the Portuguese sample models…\n\(formatter.string(fromByteCount: received))"
                if expected > 0 {
                    text += " of \(formatter.string(fromByteCount: expected))"
                }
                self?.overlayLabel.text = text
            },
            completion: { [weak self] result in
                guard let self = self else { return }
                self.downloader = nil
                switch result {
                case .success(let languages):
                    self.show(languages: languages)
                case .failure(let error):
                    self.overlaySpinner.stopAnimating()
                    self.overlayLabel.text = "Could not download the sample models.\n\(error.localizedDescription)"
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

        applyLanguagePair()
        setOverlay(visible: false)
    }

    private func displayName(of language: Language) -> String {
        let code = language.code
        let name = Locale.current.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    // MARK: - Actions

    @objc private func pickSource() {
        presentLanguageMenu(from: sourceButton, title: "Translate from") { [weak self] language in
            guard let self = self else { return }
            self.source = language
            if language.code == self.target.code {
                self.target = self.languages.first { $0.code != language.code } ?? .english
            }
            self.applyLanguagePair()
        }
    }

    @objc private func pickTarget() {
        presentLanguageMenu(from: targetButton, title: "Translate to") { [weak self] language in
            guard let self = self else { return }
            self.target = language
            if language.code == self.source.code {
                self.source = self.languages.first { $0.code != language.code } ?? .english
            }
            self.applyLanguagePair()
        }
    }

    @objc private func swapLanguages() {
        let old = source
        source = target
        target = old
        let text = outputTextView.text ?? ""
        if !text.isEmpty {
            inputTextView.text = text
            outputTextView.text = ""
            refreshPlaceholders()
        }
        applyLanguagePair()
    }

    @objc private func translate() {
        view.endEditing(true)
        let text = inputTextView.text ?? ""
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isTranslating else { return }
        isTranslating = true
        refreshTranslateButton()
        statsLabel.isHidden = false
        statsLabel.text = "Translating…"

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
                    self.outputTextView.text = translation
                    let megabytes = self.residentMemory() / 1_048_576
                    self.statsLabel.text = String(format: "%.2f s · %llu MB memory", elapsed, megabytes)
                case .failure(let error):
                    self.outputTextView.text = ""
                    self.statsLabel.text = "Translation failed: \(error.localizedDescription)"
                }
                self.refreshPlaceholders()
            }
        }
    }

    @objc private func copyTranslation() {
        UIPasteboard.general.string = outputTextView.text
        let title = copyButton.image(for: .normal)
        copyButton.setImage(UIImage(systemName: "checkmark"), for: .normal)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.setImage(title, for: .normal)
        }
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - State

    private func applyLanguagePair() {
        sourceButton.setTitle(displayName(of: source), for: .normal)
        targetButton.setTitle(displayName(of: target), for: .normal)
        refreshTranslateButton()

        let pair = (source: source, target: target)
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            let error: Error? = Result { try self.translator.setup(from: pair.source, to: pair.target) }.failureError
            DispatchQueue.main.async {
                guard pair.source == self.source, pair.target == self.target else {
                    return   // the user has already switched to another pair
                }
                // Without this branch a direction that failed to load would look like a
                // translation that changed nothing, which reads as a bug. The error itself
                // is worth showing: a missing model and a license that does not match the
                // models read very differently.
                self.pairError = error
                self.statsLabel.isHidden = error == nil
                if let error = error {
                    self.statsLabel.text = error.localizedDescription
                }
                self.refreshTranslateButton()
            }
        }
    }

    private func refreshTranslateButton() {
        let hasText = !(inputTextView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let enabled = hasText && !isTranslating && pairError == nil
        translateButton.isEnabled = enabled
        translateButton.backgroundColor = enabled ? .systemBlue : .systemGray4
        translateButton.setTitle(isTranslating ? "Translating…" : "Translate", for: .normal)
    }

    private func refreshPlaceholders() {
        inputPlaceholder.isHidden = !(inputTextView.text ?? "").isEmpty
        let hasOutput = !(outputTextView.text ?? "").isEmpty
        outputPlaceholder.isHidden = hasOutput
        copyButton.isHidden = !hasOutput
    }

    private func setOverlay(visible: Bool) {
        overlay.isHidden = !visible
        visible ? overlaySpinner.startAnimating() : overlaySpinner.stopAnimating()
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

    // MARK: - Language menu

    private func presentLanguageMenu(from anchor: UIView, title: String, pick: @escaping (Language) -> Void) {
        let sheet = UIAlertController(title: title, message: nil, preferredStyle: .actionSheet)
        for language in languages {
            sheet.addAction(UIAlertAction(title: displayName(of: language), style: .default) { _ in
                pick(language)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = anchor
        sheet.popoverPresentationController?.sourceRect = anchor.bounds
        present(sheet, animated: true)
    }

    // MARK: - Interface

    private func buildInterface() {
        view.backgroundColor = .systemGroupedBackground

        let title = UILabel()
        title.text = "Offline Translation"
        title.font = .systemFont(ofSize: 30, weight: .bold)
        title.textColor = .label

        let subtitle = UILabel()
        subtitle.text = "Runs on device. Nothing is sent anywhere."
        subtitle.font = .systemFont(ofSize: 15)
        subtitle.textColor = .secondaryLabel
        subtitle.numberOfLines = 0

        // Language bar -------------------------------------------------------
        let sourceSide = languageSide(caption: "From", button: sourceButton,
                                      action: #selector(pickSource), aligned: .leading)
        let targetSide = languageSide(caption: "To", button: targetButton,
                                      action: #selector(pickTarget), aligned: .trailing)

        swapButton.setImage(UIImage(systemName: "arrow.left.arrow.right"), for: .normal)
        swapButton.tintColor = .systemBlue
        swapButton.addTarget(self, action: #selector(swapLanguages), for: .touchUpInside)
        swapButton.setContentHuggingPriority(.required, for: .horizontal)
        swapButton.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let languageRow = UIStackView(arrangedSubviews: [sourceSide, swapButton, targetSide])
        languageRow.axis = .horizontal
        languageRow.alignment = .center
        languageRow.spacing = 8
        sourceSide.widthAnchor.constraint(equalTo: targetSide.widthAnchor).isActive = true
        let languageCard = card(wrapping: languageRow, insets: UIEdgeInsets(top: 10, left: 16, bottom: 10, right: 16))

        // Input --------------------------------------------------------------
        inputTextView.font = .systemFont(ofSize: 17)
        inputTextView.backgroundColor = .clear
        inputTextView.textColor = .label
        inputTextView.delegate = self
        inputTextView.textContainerInset = .zero
        inputTextView.textContainer.lineFragmentPadding = 0
        inputTextView.heightAnchor.constraint(equalToConstant: 116).isActive = true

        inputPlaceholder.text = "Type or paste text"
        inputPlaceholder.font = .systemFont(ofSize: 17)
        inputPlaceholder.textColor = .tertiaryLabel

        let inputContainer = UIView()
        inputContainer.addSubview(inputTextView)
        inputContainer.addSubview(inputPlaceholder)
        inputTextView.translatesAutoresizingMaskIntoConstraints = false
        inputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inputTextView.topAnchor.constraint(equalTo: inputContainer.topAnchor),
            inputTextView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor),
            inputTextView.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor),
            inputTextView.bottomAnchor.constraint(equalTo: inputContainer.bottomAnchor),
            inputPlaceholder.topAnchor.constraint(equalTo: inputTextView.topAnchor),
            inputPlaceholder.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor)
        ])
        let inputCard = card(wrapping: inputContainer)

        // Translate ----------------------------------------------------------
        translateButton.setTitle("Translate", for: .normal)
        translateButton.setTitleColor(.white, for: .normal)
        translateButton.setTitleColor(UIColor.white.withAlphaComponent(0.7), for: .disabled)
        translateButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        translateButton.backgroundColor = .systemGray4
        translateButton.layer.cornerRadius = 14
        translateButton.addTarget(self, action: #selector(translate), for: .touchUpInside)
        translateButton.heightAnchor.constraint(equalToConstant: 52).isActive = true

        // Output -------------------------------------------------------------
        outputTextView.font = .systemFont(ofSize: 17)
        outputTextView.backgroundColor = .clear
        outputTextView.textColor = .label
        outputTextView.isEditable = false
        outputTextView.textContainerInset = .zero
        outputTextView.textContainer.lineFragmentPadding = 0
        outputTextView.heightAnchor.constraint(equalToConstant: 116).isActive = true

        outputPlaceholder.text = "Translation appears here"
        outputPlaceholder.font = .systemFont(ofSize: 17)
        outputPlaceholder.textColor = .tertiaryLabel

        copyButton.setImage(UIImage(systemName: "doc.on.doc"), for: .normal)
        copyButton.tintColor = .systemBlue
        copyButton.addTarget(self, action: #selector(copyTranslation), for: .touchUpInside)
        copyButton.isHidden = true

        let outputContainer = UIView()
        outputContainer.addSubview(outputTextView)
        outputContainer.addSubview(outputPlaceholder)
        outputContainer.addSubview(copyButton)
        outputTextView.translatesAutoresizingMaskIntoConstraints = false
        outputPlaceholder.translatesAutoresizingMaskIntoConstraints = false
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            outputTextView.topAnchor.constraint(equalTo: outputContainer.topAnchor),
            outputTextView.leadingAnchor.constraint(equalTo: outputContainer.leadingAnchor),
            outputTextView.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            outputTextView.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor),
            outputPlaceholder.topAnchor.constraint(equalTo: outputTextView.topAnchor),
            outputPlaceholder.leadingAnchor.constraint(equalTo: outputTextView.leadingAnchor),
            copyButton.trailingAnchor.constraint(equalTo: outputContainer.trailingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: outputContainer.bottomAnchor)
        ])
        let outputCard = card(wrapping: outputContainer)

        // Stats --------------------------------------------------------------
        statsLabel.font = .systemFont(ofSize: 13)
        statsLabel.textColor = .secondaryLabel
        statsLabel.textAlignment = .center
        statsLabel.numberOfLines = 0
        statsLabel.isHidden = true

        // Assembly -----------------------------------------------------------
        let stack = UIStackView(arrangedSubviews: [
            title, subtitle, languageCard, inputCard, translateButton, outputCard, statsLabel
        ])
        stack.axis = .vertical
        stack.spacing = 16
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(24, after: subtitle)

        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        view.addSubview(scrollView)
        scrollView.addSubview(stack)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20)
        ])

        // Install overlay ----------------------------------------------------
        overlay.backgroundColor = .systemGroupedBackground
        overlayLabel.text = "Installing models…"
        overlayLabel.font = .systemFont(ofSize: 15)
        overlayLabel.textColor = .secondaryLabel
        overlayLabel.textAlignment = .center
        overlayLabel.numberOfLines = 0
        retryButton.setTitle("Retry", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        retryButton.addTarget(self, action: #selector(downloadSampleModels), for: .touchUpInside)
        retryButton.isHidden = true
        let overlayStack = UIStackView(arrangedSubviews: [overlaySpinner, overlayLabel, retryButton])
        overlayStack.axis = .vertical
        overlayStack.spacing = 12
        overlayStack.alignment = .center
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
            overlayStack.leadingAnchor.constraint(greaterThanOrEqualTo: overlay.leadingAnchor, constant: 32),
            overlayStack.trailingAnchor.constraint(lessThanOrEqualTo: overlay.trailingAnchor, constant: -32)
        ])
        setOverlay(visible: true)

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        scrollView.addGestureRecognizer(tap)

        refreshPlaceholders()
    }

    private func languageSide(caption: String,
                              button: UIButton,
                              action: Selector,
                              aligned: UIStackView.Alignment) -> UIStackView {
        let label = UILabel()
        label.text = caption.uppercased()
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabel

        button.setTitle("English", for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 17, weight: .semibold)
        button.titleLabel?.adjustsFontSizeToFitWidth = true
        button.titleLabel?.minimumScaleFactor = 0.7
        button.contentHorizontalAlignment = aligned == .leading ? .leading : .trailing
        button.addTarget(self, action: action, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [label, button])
        stack.axis = .vertical
        stack.alignment = aligned
        stack.spacing = 2
        return stack
    }

    private func card(wrapping content: UIView,
                      insets: UIEdgeInsets = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)) -> UIView {
        let container = UIView()
        container.backgroundColor = .secondarySystemGroupedBackground
        container.layer.cornerRadius = 16
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: insets.top),
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: insets.left),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -insets.right),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -insets.bottom)
        ])
        return container
    }

    // MARK: - Keyboard

    private func observeKeyboard() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardChanged(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(keyboardHidden),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc private func keyboardChanged(_ note: Notification) {
        guard let frame = note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let overlapping = view.bounds.maxY - view.convert(frame, from: nil).minY
        scrollView.contentInset.bottom = max(0, overlapping)
        scrollView.verticalScrollIndicatorInsets.bottom = max(0, overlapping)
    }

    @objc private func keyboardHidden() {
        scrollView.contentInset.bottom = 0
        scrollView.verticalScrollIndicatorInsets.bottom = 0
    }
}

// MARK: - UITextViewDelegate

extension ViewController: UITextViewDelegate {

    func textViewDidChange(_ textView: UITextView) {
        refreshPlaceholders()
        refreshTranslateButton()
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
