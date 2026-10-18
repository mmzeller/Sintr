import Foundation
import Security

/// How hard Claude thinks before answering (the API's "effort"). Current Claude models
/// decide for themselves when to think; this sets how much.
enum ClaudeEffort: String, CaseIterable, Identifiable, Sendable {
    case modelDefault = ""
    case low, medium, high, max

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modelDefault: "Model's default"
        case .low: "Quick"
        case .medium: "Balanced"
        case .high: "Thorough"
        case .max: "Deepest (slowest, costs most)"
        }
    }
}

/// The Claude models offered in Settings (any other model ID can be typed in).
enum ClaudeModels {
    static let choices: [(id: String, title: String, detail: String)] = [
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", "Recommended — fast and smart."),
        ("claude-opus-5-5", "Claude Opus 5.5", "Most capable for everyday work; slower, costs more."),
        ("claude-fable-5-1", "Claude Fable 5.1", "Deepest reasoning; slowest and most expensive."),
        ("claude-haiku-5-5", "Claude Haiku 5.5", "Fastest and cheapest."),
    ]

    static func title(for id: String) -> String {
        choices.first { $0.id == id }?.title ?? id
    }
}

/// Sends a note to Anthropic's Claude API — only ever when you choose Claude and send.
/// Needs your own API key from console.anthropic.com (separate from a Claude.ai plan).
/// Replies are streamed, so long answers show up as they're written.
struct ClaudeGenerator: TextGenerator {
    let apiKey: String
    let model: String
    var effort: ClaudeEffort = AppSettings.claudeEffortChoice

    var name: String { "Claude (\(model))" }
    /// Claude reads very long transcripts in one go.
    var chunkCharacters: Int { 500_000 }

    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        try await chat(system: instructions, turns: [ChatTurn(role: "user", text: prompt)], maxTokens: maxTokens) { _ in }
    }

    func chat(system: String, turns: [ChatTurn], maxTokens: Int,
              onText: @escaping @Sendable (String) -> Void) async throws -> String {
        do {
            return try await stream(system: system, turns: turns, maxTokens: maxTokens, effort: effort, onText: onText)
        } catch ClaudeFailure.effortRejected where effort != .modelDefault {
            // An older or custom model that doesn't take "effort": try once without it.
            return try await stream(system: system, turns: turns, maxTokens: maxTokens, effort: .modelDefault, onText: onText)
        }
    }

    private enum ClaudeFailure: Error { case effortRejected }

    private func stream(system: String, turns: [ChatTurn], maxTokens: Int, effort: ClaudeEffort,
                        onText: @escaping @Sendable (String) -> Void) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Thinking counts toward max_tokens, so leave plenty of room for it.
        let budget = effort == .max ? 64_000 : (effort == .high ? 32_000 : 16_000)
        var body: [String: Any] = [
            "model": model,
            "max_tokens": max(maxTokens, budget),
            "system": system,
            "stream": true,
            "messages": turns.map { ["role": $0.role, "content": $0.text] },
        ]
        if effort != .modelDefault { body["output_config"] = ["effort": effort.rawValue] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > 20_000 { break }
            }
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            if status == 400, effort != .modelDefault,
               message.localizedCaseInsensitiveContains("effort") || message.localizedCaseInsensitiveContains("output_config") {
                throw ClaudeFailure.effortRejected
            }
            throw Self.failure(status: status, message: message, model: model)
        }

        var text = ""
        var stopReason: String?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let data = payload.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
            else { continue }
            switch event.type {
            case "content_block_delta":
                if event.delta?.type == "text_delta", let piece = event.delta?.text {
                    text += piece
                    onText(text)
                }
            case "message_delta":
                stopReason = event.delta?.stop_reason ?? stopReason
            case "error":
                let message = event.error?.message ?? "Unknown error"
                throw EnhanceError.service(event.error?.type == "overloaded_error"
                    ? "Claude is busy right now. Try again in a minute. (\(message))"
                    : "Claude stopped with an error: \(message)")
            default:
                break
            }
        }
        if text.isEmpty {
            throw EnhanceError.service(stopReason == "max_tokens"
                ? "Claude used its whole budget thinking and didn't write an answer. Try a lower thinking level in Settings → Claude."
                : "Claude sent back an empty reply.")
        }
        return text
    }

    private static func failure(status: Int, message: String, model: String) -> Error {
        switch status {
        case 401: EnhanceError.service("Claude rejected the API key. Check it in Settings → Claude.")
        case 404: EnhanceError.service("Claude doesn't recognize the model “\(model)”. Change it in Settings → Claude. (\(message))")
        case 429, 529: EnhanceError.service("Claude is busy right now. Try again in a minute. (\(message))")
        default: EnhanceError.service("Claude returned an error (\(status)): \(message)")
        }
    }

    private struct StreamEvent: Decodable {
        struct Delta: Decodable {
            let type: String?
            let text: String?
            let stop_reason: String?
        }
        struct Problem: Decodable {
            let type: String?
            let message: String?
        }
        let type: String
        let delta: Delta?
        let error: Problem?
    }

    private struct APIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

/// Secrets (API keys and tokens) live in the device's Keychain — never in notes, settings
/// files, or the portable folder.
enum SecretStore {
    private static let service = "io.github.mmzeller.Sintr.claude"

    static func get(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    static func set(_ account: String, _ value: String?) {
        SecItemDelete(baseQuery(account) as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = Data(value.utf8)
        #if os(iOS)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        #endif
        SecItemAdd(attributes as CFDictionary, nil)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// The Claude API key.
enum APIKeyStore {
    static var claudeKey: String? {
        get { SecretStore.get("api-key") }
        set { SecretStore.set("api-key", newValue) }
    }
}
