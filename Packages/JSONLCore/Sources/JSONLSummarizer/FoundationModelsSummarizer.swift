import FoundationModels
import JSONLCore

/// Kept out of JSONLCore so the Quick Look extension, which cannot run the model, does not link FoundationModels.

public struct FoundationModelsSummarizer: Summarizing {
    public init() {}

    public func summarize(_ digest: String, format: FileFormat) async throws -> String {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available: break
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: throw SummaryUnavailable(reason: "Apple Intelligence is off")
            case .modelNotReady: throw SummaryUnavailable(reason: "model not downloaded")
            case .deviceNotEligible: throw SummaryUnavailable(reason: "not supported here")
            @unknown default: throw SummaryUnavailable(reason: "not supported here")
            }
        }
        let session = LanguageModelSession(model: model, instructions: SummaryInstructions.text(for: format))
        return try await session.respond(to: digest).content
    }
}
