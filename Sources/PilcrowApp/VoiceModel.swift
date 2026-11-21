import Foundation
import Speech

struct VoiceModel {
    enum Transcriber {
        case speech(SpeechTranscriber)
        case dictation(DictationTranscriber)

        var module: any SpeechModule {
            switch self {
            case .speech(let transcriber): transcriber
            case .dictation(let transcriber): transcriber
            }
        }
    }

    let locale: Locale
    private let usesDictation: Bool

    func makeTranscriber() -> Transcriber {
        if usesDictation {
            return .dictation(DictationTranscriber(locale: locale, contentHints: [],
                transcriptionOptions: [.punctuation], reportingOptions: [.volatileResults],
                attributeOptions: [.audioTimeRange]))
        }
        return .speech(SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults], attributeOptions: [.audioTimeRange]))
    }

    /// Prefer the user's language with either on-device engine before trying English.
    /// A missing download does not change the chosen language or engine.
    static func select(for preferred: Locale = .current) async -> (VoiceModel, AssetInventory.Status)? {
        for requested in [preferred, Locale(identifier: "en-US")] {
            if SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                let model = VoiceModel(locale: locale, usesDictation: false)
                let status = await AssetInventory.status(forModules: [model.makeTranscriber().module])
                if status != .unsupported { return (model, status) }
            }
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                let model = VoiceModel(locale: locale, usesDictation: true)
                let status = await AssetInventory.status(forModules: [model.makeTranscriber().module])
                if status != .unsupported { return (model, status) }
            }
        }
        return nil
    }
}
