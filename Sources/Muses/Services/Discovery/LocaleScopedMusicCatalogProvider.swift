import Foundation

/// Routes every public-catalog operation through the currently selected app
/// language and system region. A language change cannot continue an older
/// cursor or reuse another locale's physical cache partition.
actor LocaleScopedMusicCatalogProvider: MusicCatalogProviding {
    struct Scope: Hashable, Sendable {
        let region: String
        let language: String
    }

    typealias ScopeProvider = @Sendable () -> Scope
    typealias Factory = @Sendable (Scope) -> any MusicCatalogProviding

    private let scopeProvider: ScopeProvider
    private let factory: Factory
    private var providers: [Scope: any MusicCatalogProviding] = [:]

    init(
        scopeProvider: @escaping ScopeProvider = {
            Scope(
                region: Locale.current.region?.identifier ?? "US",
                language: L10n.languageCode)
        },
        factory: @escaping Factory = { scope in
            CachedMusicCatalogProvider(
                region: scope.region, language: scope.language)
        }
    ) {
        self.scopeProvider = scopeProvider
        self.factory = factory
    }

    func search(
        _ query: String, kind: MusicCatalogKind?
    ) async throws -> MusicCatalogPage {
        let (scope, provider) = providerForCurrentScope()
        let page = try await provider.search(query, kind: kind)
        guard page.region == scope.region, page.language == scope.language else {
            throw MusicCatalogError.invalidResponse
        }
        return page
    }

    func browse(_ id: String) async throws -> MusicCatalogPage {
        let (scope, provider) = providerForCurrentScope()
        let page = try await provider.browse(id)
        guard page.region == scope.region, page.language == scope.language else {
            throw MusicCatalogError.invalidResponse
        }
        return page
    }

    func next(_ cursor: MusicCatalogCursor) async throws -> MusicCatalogPage {
        let scope = normalized(scopeProvider())
        guard cursor.region == scope.region,
              cursor.language == scope.language else {
            throw MusicCatalogError.expiredCursor
        }
        let provider = provider(for: scope)
        return try await provider.next(cursor)
    }

    func reset() async {
        let values = Array(providers.values)
        providers.removeAll(keepingCapacity: false)
        for provider in values { await provider.reset() }
    }

    private func providerForCurrentScope()
        -> (Scope, any MusicCatalogProviding) {
        let scope = normalized(scopeProvider())
        return (scope, provider(for: scope))
    }

    private func provider(for scope: Scope) -> any MusicCatalogProviding {
        if let existing = providers[scope] { return existing }
        let value = factory(scope)
        providers[scope] = value
        return value
    }

    private func normalized(_ scope: Scope) -> Scope {
        let region = scope.region.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let language = scope.language
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
        return Scope(
            region: region.count == 2 ? region : "US",
            language: language.isEmpty ? "en" : language)
    }
}
