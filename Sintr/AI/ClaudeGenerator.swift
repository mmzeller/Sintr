import Foundation
import Security

/// Sends a note to Anthropic's Claude API — only ever when you tap "Send to Claude"
/// and confirm. Needs your own API key from console.anthropic.com (separate from a Claude.ai plan).
struct ClaudeGenerator: TextGenerator {
    let apiKey: String
    let model: String

    var name: String { "Claude (\(model))" }
    /// Claude reads very long transcripts in one go.
    var chunkCharacters: Int { 500_000 }

    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        let body: [String: Any] = [
            "model": model,
            "max_tokens": max(maxTokens, 4000),
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(APIError.self, from: data))?.error.message
                ?? String(data: data, encoding: .utf8) ?? "Unknown error"
            switch status {
            case 401: throw EnhanceError.service("Claude rejected the API key. Check it in Settings → Claude.")
            case 404: throw EnhanceError.service("Claude doesn't recognize the model “\(model)”. Change it in Settings → Claude. (\(message))")
            case 429, 529: throw EnhanceError.service("Claude is busy right now. Try again in a minute. (\(message))")
            default: throw EnhanceError.service("Claude returned an error (\(status)): \(message)")
            }
        }
        let decoded = try JSONDecoder().decode(MessageResponse.self, from: data)
        let text = decoded.content.compactMap { $0.type == "text" ? $0.text : nil }.joined()
        guard !text.isEmpty else { throw EnhanceError.service("Claude sent back an empty reply.") }
        return text
    }

    private struct MessageResponse: Decodable {
        struct Block: Decodable {
            let type: String
            let text: String?
        }
        let content: [Block]
    }

    private struct APIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

/// Stores the Claude API key in the device's Keychain (never in the notes or settings files).
enum APIKeyStore {
    private static let service = "io.github.mmzeller.Sintr.claude"

    static var claudeKey: String? {
        get {
            var query = baseQuery
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let key = String(data: data, encoding: .utf8),
                  !key.isEmpty
            else { return nil }
            return key
        }
        set {
            SecItemDelete(baseQuery as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var attributes = baseQuery
            attributes[kSecValueData as String] = Data(newValue.utf8)
            #if os(iOS)
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            #endif
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "api-key",
        ]
    }
}
