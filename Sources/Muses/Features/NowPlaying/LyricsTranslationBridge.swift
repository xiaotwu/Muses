import NaturalLanguage
import SwiftUI
import Translation

/// Mounted only for a specific lyric document and target language. SwiftUI owns
/// translation model downloads and cancellation when that identity disappears.
@available(macOS 15.0, *)
struct LyricsTranslationBridge: View {
    let lines: [String]
    let target: String
    let onResult: @MainActor ([String]?, String?) -> Void
    @Environment(LyricsService.self) private var lyrics
    @State private var configuration: TranslationSession.Configuration?

    private var key: String { LyricsDocumentIdentity.digest(["translation", target] + lines) }

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .task {
                guard target != "off", !lines.isEmpty else { return }
                #if DEBUG
                // Exercise the production fallback without changing system models.
                if ProcessInfo.processInfo.arguments.contains("--test-lyrics-translation-failure") {
                    onResult(nil, Self.failureMessage)
                    return
                }
                #endif
                if let cached = lyrics.enrichment(key: key) {
                    onResult(cached, nil)
                    return
                }
                let recognizer = NLLanguageRecognizer()
                recognizer.processString(String(lines.joined(separator: "\n").prefix(8_000)))
                guard let detected = recognizer.dominantLanguage else {
                    onResult(nil, tr("Could not identify the lyric language", "无法识别歌词语言"))
                    return
                }
                let source = Locale.Language(identifier: detected.rawValue)
                let destination = Locale.Language(identifier: target)
                if source.languageCode == destination.languageCode {
                    if target.hasPrefix("zh") {
                        let transform = StringTransform(target == "zh-Hant" ? "Hans-Hant" : "Hant-Hans")
                        onResult(lines.map { $0.applyingTransform(transform, reverse: false) ?? $0 }, nil)
                    } else { onResult(nil, nil) }
                    return
                }
                let status = await LanguageAvailability().status(from: source, to: destination)
                guard !Task.isCancelled else { return }
                guard status != .unsupported else {
                    onResult(nil, tr("This language pair is not supported by Apple Translation", "Apple 翻译不支持此语言组合"))
                    return
                }
                configuration = .init(source: source, target: destination)
            }
            .translationTask(configuration, action: translate)
    }

    /// Keep the framework-owned, non-Sendable session on its asynchronous
    /// executor. Only plain strings cross back to the UI actor.
    nonisolated private func translate(_ session: TranslationSession) async {
        do {
            try await session.prepareTranslation()
            var translated: [(Int, String)] = []
            for start in stride(from: 0, to: lines.count, by: 30) {
                try Task.checkCancellation()
                let requests = (start..<min(start + 30, lines.count)).map {
                    TranslationSession.Request(sourceText: lines[$0], clientIdentifier: String($0))
                }
                let responses = try await session.translations(from: requests)
                translated.append(contentsOf: responses.compactMap {
                    guard let identifier = $0.clientIdentifier, let index = Int(identifier) else { return nil }
                    return (index, $0.targetText)
                })
            }
            try Task.checkCancellation()
            guard let aligned = LyricsLineAlignment.align(translated, count: lines.count) else {
                throw LyricsIntelligence.ProcessingError.invalidAlignment
            }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                lyrics.rememberEnrichment(aligned, key: key)
                onResult(aligned, nil)
            }
        } catch {
            guard !Task.isCancelled else { return }
            await onResult(nil, Self.failureMessage)
        }
    }

    private static var failureMessage: String {
        tr("Translation unavailable. Original lyrics are still shown.", "翻译暂不可用，仍显示原文歌词。")
    }
}
