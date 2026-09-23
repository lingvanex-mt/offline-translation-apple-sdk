//
// Models.swift
//
// Everything the demo apps need on top of the SDK: install the models that ship with the
// app, fetch the sample models when there are none, remember what is installed, and
// translate a pair — going through English when there is no direct model.
//
// The SDK itself stays at one level of abstraction: a translator is one loaded direction.
// This file is the other half — deliberately small, and yours to copy into your app.
//

import Foundation
import OfflineTranslator
import ZIPFoundation

// MARK: - Language

/// A language the installed models translate to or from.
struct Language: Equatable {

    /// ISO code, e.g. `pt`.
    let code: String

    /// English, the pivot language. Translating to or from it needs no model of its own.
    static let english = Language(code: "en")

    var isEnglish: Bool {
        return code == Language.english.code
    }
}

// MARK: - Installed models

/// The models on disk: one flat folder holding one subfolder per direction —
/// `en_pt`, `pt_en`, `en_ru`, `ru_en` — exactly as they come in the archive.
enum ModelStore {

    enum InstallError: LocalizedError {
        case noModels(String)
        case badResponse(Int)

        var errorDescription: String? {
            switch self {
            case .noModels(let archive):
                return "\(archive) carries no model directions"
            case .badResponse(let status):
                return "The server answered HTTP \(status)"
            }
        }
    }

    /// Where the models live. Caches, because they can always be installed again —
    /// and iOS is allowed to evict them when the device runs out of space.
    static var directory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return caches.appendingPathComponent("models")
    }

    /// Installs every `.zip` shipped in the app bundle and returns every language on disk —
    /// the bundled ones plus whatever an earlier launch downloaded.
    ///
    /// An archive already installed is skipped, so this is cheap to call on every launch.
    static func installBundled() throws -> [Language] {
        for archive in Bundle.main.urls(forResourcesWithExtension: "zip", subdirectory: nil) ?? [] {
            if try !isInstalled(archive) {
                try install(archive: archive)
            }
        }
        return installedLanguages()
    }

    /// Every language the installed models reach, English aside — sorted by code.
    static func installedLanguages() -> [Language] {
        var codes = Set<String>()
        for direction in directions(in: directory) {
            guard let pair = languageCodes(inDirectionNamed: direction.lastPathComponent) else {
                continue
            }
            codes.formUnion([pair.from, pair.to])
        }
        codes.remove(Language.english.code)
        return codes.sorted().map { Language(code: $0) }
    }

    /// Whether the model for one direction is installed. An archive is free to carry one
    /// direction of a language and not the other.
    static func hasModel(from source: Language, to target: Language) -> Bool {
        return modelPath(from: source, to: target) != nil
    }

    /// Path of the model for one direction, `nil` when it is not installed.
    ///
    /// A direction folder holds the model under `1` — the layout the models ship in, and
    /// the one the Android SDK expects as well.
    static func modelPath(from source: Language, to target: Language) -> String? {
        let model = directory.appendingPathComponent("\(source.code)_\(target.code)/1")
        guard FileManager.default.fileExists(atPath: model.appendingPathComponent("model.bin").path) else {
            return nil
        }
        return model.path
    }

    /// Unpacks an archive and merges its directions into the models folder, replacing the
    /// directions already there and leaving the others alone — two archives can be installed
    /// side by side.
    ///
    /// Every direction is unpacked next to its final place and moved there in one step, so a
    /// launch interrupted half-way never leaves a direction that looks installed but is not.
    /// The SDK does not unpack archives — any zip library works; the demo uses ZIPFoundation.
    static func install(archive: URL) throws {
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try FileManager.default.unzipItem(at: archive, to: staging)

        let unpacked = directions(in: modelsRoot(in: staging))
        guard !unpacked.isEmpty else {
            throw InstallError.noModels(archive.lastPathComponent)
        }
        for direction in unpacked {
            let destination = directory.appendingPathComponent(direction.lastPathComponent)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: direction, to: destination)
        }
        try writeReceipt(for: archive)
    }

    // MARK: Reading the folder

    /// The direction folders of a models folder: a folder named `en_pt` with `1/model.bin`
    /// inside. Anything else — loose files, a `models.config`, a folder we do not recognise —
    /// is ignored, so an archive is free to carry extras.
    private static func directions(in folder: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.filter { entry in
            guard languageCodes(inDirectionNamed: entry.lastPathComponent) != nil else {
                return false
            }
            return FileManager.default.fileExists(atPath: entry.appendingPathComponent("1/model.bin").path)
        }
    }

    /// The two language codes of a direction folder: `en_pt` → `en`, `pt`. A code may carry
    /// a region (`en_zh-Hans`), so anything but the separating underscore is left alone.
    private static func languageCodes(inDirectionNamed name: String) -> (from: String, to: String)? {
        let parts = name.components(separatedBy: "_")
        guard parts.count == 2 else {
            return nil
        }
        let isCode = { (code: String) in
            !code.isEmpty && code.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
        guard isCode(parts[0]), isCode(parts[1]) else {
            return nil
        }
        return (parts[0], parts[1])
    }

    /// The folder holding the directions. Normally the root of the archive — but an archive
    /// made by compressing a folder puts them one level down (`models/en_pt/…`), so a single
    /// subfolder that has directions of its own is followed.
    private static func modelsRoot(in staging: URL) -> URL {
        if !directions(in: staging).isEmpty {
            return staging
        }
        let entries = (try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
        let candidates = entries.filter { !directions(in: $0).isEmpty }
        return candidates.count == 1 ? candidates[0] : staging
    }

    // MARK: Receipts

    /// A note that an archive has been unpacked, so the next launch skips it. It records the
    /// size: replace the archive in the project with another one and it is installed anew.
    private static func receipt(for archive: URL) -> URL {
        return directory
            .appendingPathComponent(".installed")
            .appendingPathComponent(archive.lastPathComponent)
    }

    private static func isInstalled(_ archive: URL) throws -> Bool {
        guard let written = try? String(contentsOf: receipt(for: archive), encoding: .utf8) else {
            return false
        }
        return try written == size(of: archive)
    }

    private static func writeReceipt(for archive: URL) throws {
        let receipt = receipt(for: archive)
        try FileManager.default.createDirectory(at: receipt.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try size(of: archive).write(to: receipt, atomically: true, encoding: .utf8)
    }

    private static func size(of archive: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.path)
        return String(attributes[.size] as? Int ?? 0)
    }
}

// MARK: - Downloading models

/// Fetches an archive over HTTPS and installs it. The demo apps use it for the sample
/// Portuguese models when they find none at all, so they run with nothing to set up.
///
/// Nothing here is specific to the sample: point `url` at your own server to fetch
/// commercial models the same way. Progress and completion arrive on the main queue.
final class ModelsDownloader: NSObject, URLSessionDownloadDelegate {

    /// The sample models: English ↔ Portuguese, 87 MB, unencrypted.
    static let sampleModelsURL = URL(
        string: "https://github.com/lingvanex-mt/offline-translation-apple-sdk/releases/download/sample-models/pt.zip"
    )!

    private let url: URL
    private let progress: (_ received: Int64, _ expected: Int64) -> Void
    private let completion: (Result<[Language], Error>) -> Void
    private var session: URLSession?
    private var isFinished = false

    /// - Parameters:
    ///   - progress: bytes received so far and bytes expected in total, `-1` when the
    ///     server does not say.
    init(url: URL = ModelsDownloader.sampleModelsURL,
         progress: @escaping (_ received: Int64, _ expected: Int64) -> Void,
         completion: @escaping (Result<[Language], Error>) -> Void) {
        self.url = url
        self.progress = progress
        self.completion = completion
    }

    func start() {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        session.downloadTask(with: url).resume()
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        DispatchQueue.main.async {
            self.progress(totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is gone once this method returns, so unpack it right here.
        let result = Result<[Language], Error> {
            if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
                throw ModelStore.InstallError.badResponse(response.statusCode)
            }
            try ModelStore.install(archive: location)
            return ModelStore.installedLanguages()
        }
        finish(with: result)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            finish(with: .failure(error))
        }
    }

    /// Runs once: a finished download reports here and then completes with a `nil` error,
    /// a failed one reports only the error.
    private func finish(with result: Result<[Language], Error>) {
        session?.finishTasksAndInvalidate()   // the session holds its delegate until then
        DispatchQueue.main.async {
            guard !self.isFinished else { return }
            self.isFinished = true
            self.completion(result)
        }
    }
}

// MARK: - Translating a pair

/// Translates between two languages, pivoting through English when there is no direct model.
///
/// Holds one translator per loaded direction: a pivoted pair costs two models in memory,
/// so unload it (`setup(from: .english, to: .english)`) when the screen is gone.
final class PairTranslator {

    /// License for encrypted models. Demo models are plain, so this stays `nil`;
    /// commercial models need the license issued with them.
    var license: License?

    private var first: Translator?
    private var second: Translator?

    enum PairError: LocalizedError {
        case noModel(from: String, to: String)

        var errorDescription: String? {
            switch self {
            case .noModel(let source, let target):
                return "No \(source)_\(target) model is installed"
            }
        }
    }

    /// Loads the pair: the direct model when it is installed, two models chained through
    /// English otherwise. Loading nothing — the same language on both sides — is how the
    /// models are released.
    func setup(from source: Language, to target: Language) throws {
        first = nil
        second = nil

        guard source != target else {
            return
        }
        do {
            if let direct = ModelStore.modelPath(from: source, to: target) {
                first = try translator(direct, from: source, to: target)
                return
            }
            first = try translator(from: source, to: .english)
            second = try translator(from: .english, to: target)
        } catch {
            // An archive can carry one direction only, and then the second leg of a pivot
            // is missing. Half a pair would translate into English and call it the target
            // language, so it is dropped: either the whole pair loads or nothing does.
            first = nil
            second = nil
            throw error
        }
    }

    /// Translates with the loaded pair. A pair of the same language returns the input unchanged.
    func translate(_ text: String) throws -> String {
        let firstPass = try first?.translate(text) ?? text
        return try second?.translate(firstPass) ?? firstPass
    }

    /// Stops the translation in flight; it ends at the next batch boundary.
    func cancel() {
        first?.requestCancel()
        second?.requestCancel()
    }

    private func translator(from source: Language, to target: Language) throws -> Translator {
        guard let path = ModelStore.modelPath(from: source, to: target) else {
            throw PairError.noModel(from: source.code, to: target.code)
        }
        return try translator(path, from: source, to: target)
    }

    private func translator(_ path: String, from source: Language, to target: Language) throws -> Translator {
        return try Translator(
            modelPath: path,
            from: source.code,
            to: target.code,
            license: license
        )
    }
}
