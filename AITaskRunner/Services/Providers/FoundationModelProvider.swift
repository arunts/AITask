import Foundation
import FoundationModels
import Observation

/// Availability and metadata for Apple's Foundation Model, all read live from the FoundationModels framework.
@Observable
final class FoundationModelProvider {
    private(set) var isAvailable = false
    private(set) var statusLabel = "Checking…"
    private(set) var statusDetail: String?
    private(set) var supportedLanguages: [String] = []
    private(set) var supportsCurrentLocale = false

    func refresh() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            isAvailable = true
            statusLabel = "Available"
            statusDetail = "Apple Intelligence is enabled and the model assets are ready."
        case .unavailable(let reason):
            isAvailable = false
            statusLabel = "Unavailable"
            switch reason {
            case .deviceNotEligible:
                statusDetail = "This Mac is not eligible for Apple Intelligence (Apple silicon required)."
            case .appleIntelligenceNotEnabled:
                statusDetail = "Apple Intelligence is turned off. Enable it in System Settings › Apple Intelligence & Siri."
            case .modelNotReady:
                statusDetail = "The model is still downloading or preparing. Try again in a few minutes."
            @unknown default:
                statusDetail = "The model is unavailable for an unknown reason."
            }
        }
        supportedLanguages = model.supportedLanguages
            .map { language in
                let identifier = language.maximalIdentifier
                let display = Locale.current.localizedString(forIdentifier: identifier) ?? identifier
                return display
            }
            .sorted()
        supportsCurrentLocale = model.supportsLocale(Locale.current)
    }
}
