import Foundation
#if canImport(MLXLLM)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// Small open models that run on the device itself (including an iPhone 12) after a one-time
/// download from Hugging Face. Slower and less capable than Apple Intelligence or Claude,
/// but nothing leaves the device.
enum PhoneModelChoice: String, CaseIterable, Identifiable, Sendable {
    case gemma1B
    case llama1B
    case qwen17B

    static let defaultChoice = PhoneModelChoice.gemma1B

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemma1B: "Gemma 3 1B (Google)"
        case .llama1B: "Llama 3.2 1B (Meta)"
        case .qwen17B: "Qwen3 1.7B (Alibaba)"
        }
    }

    var detail: String {
        switch self {
        case .gemma1B: "Recommended. About 0.8 GB, quickest."
        case .llama1B: "About 0.7 GB."
        case .qwen17B: "About 1 GB. A little smarter, slower, tight on an iPhone 12."
        }
    }

    /// The Hugging Face repository the files come from.
    var repoID: String {
        switch self {
        case .gemma1B: "mlx-community/gemma-3-1b-it-qat-4bit"
        case .llama1B: "mlx-community/Llama-3.2-1B-Instruct-4bit"
        case .qwen17B: "mlx-community/Qwen3-1.7B-4bit"
        }
    }

    var stopTokens: Set<String> {
        switch self {
        case .gemma1B: ["<end_of_turn>"]
        case .llama1B: ["<|eot_id|>"]
        case .qwen17B: ["<|im_end|>"]
        }
    }

    static var selected: PhoneModelChoice {
        PhoneModelChoice(rawValue: UserDefaults.standard.string(forKey: AppSettings.phoneModel) ?? "") ?? .defaultChoice
    }
}

/// Downloads model files straight from huggingface.co — only when you tap Download.
/// Loading a model that's already downloaded never touches the network.
struct ModelFiles: Sendable {
    static let patterns = ["*.safetensors", "*.json", "*.jinja", "*.txt", "*.model", "*.tiktoken"]

    static var folder: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let folder = support.appendingPathComponent("Sintr/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Models are large and can always be downloaded again: keep them out of backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var copy = folder
        try? copy.setResourceValues(values)
        return folder
    }

    static func directory(for repoID: String) -> URL {
        folder.appendingPathComponent(repoID.replacingOccurrences(of: "/", with: "--"), isDirectory: true)
    }

    private static func marker(for repoID: String) -> URL {
        directory(for: repoID).appendingPathComponent(".sintr-complete")
    }

    static func isDownloaded(_ repoID: String) -> Bool {
        FileManager.default.fileExists(atPath: marker(for: repoID).path)
    }

    static func sizeOnDisk(_ repoID: String) -> Int64 {
        let dir = directory(for: repoID)
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    static func delete(_ repoID: String) {
        try? FileManager.default.removeItem(at: directory(for: repoID))
    }

    struct RemoteFile: Decodable {
        let type: String
        let path: String
        let size: Int64?
    }

    /// Lists the files that will be downloaded and their total size.
    static func plan(_ repoID: String, patterns: [String] = ModelFiles.patterns) async throws -> [RemoteFile] {
        let url = URL(string: "https://huggingface.co/api/models/\(repoID)/tree/main")!
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw EnhanceError.service("Couldn't reach Hugging Face to list the model's files.")
        }
        let files = try JSONDecoder().decode([RemoteFile].self, from: data)
        return files.filter { file in
            file.type == "file" && patterns.contains { fnmatch($0, file.path, 0) == 0 }
        }
    }

    /// Downloads every matching file that isn't already here.
    @discardableResult
    static func download(
        _ repoID: String,
        patterns: [String] = ModelFiles.patterns,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let dir = directory(for: repoID)
        if isDownloaded(repoID) { return dir }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let files = try await plan(repoID, patterns: patterns)
        let total = max(1, files.reduce(Int64(0)) { $0 + ($1.size ?? 0) })
        var done: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let destination = dir.appendingPathComponent(file.path)
            let existing = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if let size = file.size, existing == size {
                done += size
                continue
            }
            let remote = URL(string: "https://huggingface.co/\(repoID)/resolve/main/\(file.path)")!
            let base = done
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try await FileDownload.run(remote, to: destination) { written in
                progress(Double(base + written) / Double(total))
            }
            done += file.size ?? 0
            progress(Double(done) / Double(total))
        }
        FileManager.default.createFile(atPath: marker(for: repoID).path, contents: Data())
        return dir
    }

}

/// One file download with progress, saved straight to its final place.
private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let onProgress: @Sendable (Int64) -> Void
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    private init(destination: URL, onProgress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    static func run(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let download = FileDownload(destination: destination, onProgress: progress)
        let session = URLSession(configuration: .default, delegate: download, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                download.continuation = continuation
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress(totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            failure = EnhanceError.service("Downloading \(destination.lastPathComponent) failed (HTTP \(status)).")
            return
        }
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        if let error = error ?? failure {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}

#if canImport(MLXLLM)
/// Connects the downloaded files to MLX. Never downloads anything itself: if the files
/// aren't on the device it stops and asks you to download them in AppSettings.
private struct LocalOnlyDownloader: MLXLMCommon.Downloader {
    func download(
        id: String, revision: String?, matching patterns: [String], useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard ModelFiles.isDownloaded(id) else {
            throw EnhanceError.unavailable("The phone model isn't downloaded yet. Download it in Settings → Phone model.")
        }
        return ModelFiles.directory(for: id)
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let upstream = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TokenizerBridge(upstream: upstream)
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }
    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }
    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

/// Keeps one model in memory between requests.
actor PhoneModelRuntime {
    static let shared = PhoneModelRuntime()
    private var container: ModelContainer?
    private var loadedID: String?

    func container(for choice: PhoneModelChoice) async throws -> ModelContainer {
        if let container, loadedID == choice.repoID { return container }
        container = nil
        loadedID = nil
        // Keep MLX's scratch memory small; an iPhone 12 has 4 GB in total.
        Memory.cacheLimit = 20 * 1024 * 1024
        let configuration = ModelConfiguration(id: choice.repoID, extraEOSTokens: choice.stopTokens)
        let loaded = try await loadModelContainer(
            from: LocalOnlyDownloader(), using: TransformersTokenizerLoader(), configuration: configuration)
        container = loaded
        loadedID = choice.repoID
        return loaded
    }

    func unload() {
        container = nil
        loadedID = nil
    }
}

struct PhoneModelGenerator: TextGenerator {
    let choice: PhoneModelChoice

    static let isBuiltIn = true

    var name: String { "\(choice.title) on this \(Platform.deviceName)" }
    var chunkCharacters: Int { 6_000 }

    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        let container = try await PhoneModelRuntime.shared.container(for: choice)
        let session = ChatSession(
            container,
            instructions: instructions,
            generateParameters: GenerateParameters(maxTokens: maxTokens, temperature: 0.3),
            additionalContext: ["enable_thinking": false])
        return try await session.respond(to: prompt)
    }
}
#else
/// Placeholder used until the MLX packages are part of the build.
struct PhoneModelGenerator: TextGenerator {
    let choice: PhoneModelChoice

    static let isBuiltIn = false

    var name: String { choice.title }
    var chunkCharacters: Int { 6_000 }

    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        throw EnhanceError.unavailable("This build of Sintr doesn't include the phone model yet.")
    }
}
#endif
