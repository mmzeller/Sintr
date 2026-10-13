import Foundation
import FoundationModels

/// Apple's built-in on-device model (Apple Intelligence). Runs entirely on the device.
/// Available on Macs with Apple silicon and on iPhone 15 Pro or newer — not on iPhone 12.
struct AppleGenerator: TextGenerator {
    var name: String { "Apple Intelligence on this \(Platform.deviceName)" }

    /// The model's whole context is about 4,000 tokens (≈ 3 characters each for prompt + reply),
    /// so transcripts go in a few thousand characters at a time.
    var chunkCharacters: Int { 6_500 }

    /// Nil when it's ready, otherwise a plain explanation of why it isn't.
    static var unavailableReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return Platform.isMac
                    ? "This Mac can't run Apple Intelligence."
                    : "Apple Intelligence needs an iPhone 15 Pro or newer, so it isn't available on this iPhone."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in \(Platform.isMac ? "System Settings" : "Settings") → Apple Intelligence & Siri, then try again."
            case .modelNotReady:
                return "Apple Intelligence is still getting ready (downloading). Try again in a little while."
            @unknown default:
                return "Apple Intelligence isn't available right now."
            }
        }
    }

    func generate(instructions: String, prompt: String, maxTokens: Int) async throws -> String {
        if let reason = Self.unavailableReason { throw EnhanceError.unavailable(reason) }
        var text = prompt
        // If a piece is still too long, cut it down and try again rather than failing.
        for _ in 0..<3 {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let options = GenerationOptions(temperature: 0.3, maximumResponseTokens: min(maxTokens, 1200))
                let response = try await session.respond(to: text, options: options)
                return response.content
            } catch let error as LanguageModelSession.GenerationError {
                switch error {
                case .exceededContextWindowSize:
                    text = String(text.prefix(text.count * 2 / 3))
                    continue
                case .guardrailViolation:
                    throw EnhanceError.service(
                        "Apple's model declined this content (its safety filter). Try Send to Claude or the phone model instead.")
                default:
                    throw EnhanceError.service("Apple Intelligence couldn't finish: \(error.localizedDescription)")
                }
            }
        }
        throw EnhanceError.service("This was too long for Apple's on-device model, even in pieces.")
    }
}
