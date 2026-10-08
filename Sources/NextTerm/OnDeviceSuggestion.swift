import Foundation
#if canImport(FoundationModels)
// Weakly linked: the framework is only on macOS 26 and later, and the app runs from macOS 13.
@_weakLinked import FoundationModels
#endif

/// Apple's on-device model for Suggest a Command (macOS 26 and later, with Apple Intelligence on): the same prompt
/// and the same checks as an agent's (CommandSuggestion). Nothing leaves the Mac. Compiled out where the SDK has no
/// FoundationModels, as with the Swift 6.1 that builds releases.
enum OnDeviceSuggestion {
    static let instructions = "You turn a request into one shell command. Answer with the command only: no explanation, no code fence."

    /// This build has the model's code and this Mac's macOS can have the model: Settings offers it.
    static var isOffered: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return true }
        #endif
        return false
    }

    /// Why the model can't be used on this Mac, in words for Settings; nil when it can.
    static var unavailable: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return reason(SystemLanguageModel.default.availability) }
        return "Apple’s on-device model needs macOS 26 or later."
        #else
        return "This build of Next Term was made without Apple’s on-device model."
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26, *)
    static func reason(_ availability: SystemLanguageModel.Availability) -> String? {
        switch availability {
        case .available:
            return nil
        case .unavailable(let why):
            switch why {
            case .deviceNotEligible: return "This Mac can’t run Apple’s on-device model."
            case .appleIntelligenceNotEnabled: return "Apple Intelligence is off: turn it on in System Settings › Apple Intelligence & Siri."
            case .modelNotReady: return "Apple’s on-device model isn’t ready yet: it may still be downloading."
            @unknown default: return "Apple’s on-device model isn’t available."
            }
        }
    }

    /// For the self-test: Settings' words when the model is available (none), then for each reason it isn't.
    @available(macOS 26, *)
    static var everyReason: [String?] {
        let reasons: [SystemLanguageModel.Availability.UnavailableReason] = [.deviceNotEligible, .appleIntelligenceNotEnabled, .modelNotReady]
        return [reason(.available)] + reasons.map { reason(.unavailable($0)) }
    }
    #endif

    enum Failure: LocalizedError {
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let why): return why
            }
        }
    }

    /// One answer for `prompt`, as text.
    static func suggest(_ prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            if let why = reason(SystemLanguageModel.default.availability) { throw Failure.unavailable(why) }
            let session = LanguageModelSession(instructions: instructions)
            let response = try await session.respond(to: prompt)
            return response.content
        }
        #endif
        throw Failure.unavailable(unavailable ?? "Apple’s on-device model isn’t available.")
    }
}
