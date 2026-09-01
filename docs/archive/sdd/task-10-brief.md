### Task 10: 联网元数据补全(MusicBrainz + iTunes Search)

**Files:**
- Create: `Muses/Sources/Muses/Services/Enrichment/EnrichmentEndpoint.swift`
- Create: `Muses/Sources/Muses/Services/Enrichment/MetadataEnricherService.swift`
- Create: `Muses/Tests/MusesTests/MetadataEnricherServiceTests.swift`
- Modify: `Muses/Sources/Muses/App/MusesApp.swift`(inject enricher)
- Modify: `Muses/Sources/Muses/Services/Library/LibraryService.swift`(post-scan enrichment queue)

**Verified API facts:**
- `Track` (@Model): id:UUID, title:String, artist:String, albumTitle:String?, year:Int?, artworkUrl:String?, localArtworkHash:String?, metadataStatusRaw:String (MetadataStatus.rawValue), source:TrackSource. Has `var metadataStatus: MetadataStatus` computed getter.
- `MetadataStatus`: enum { embedded, enriching, complete, missing } — String, Codable, Sendable.
- `ArtworkCache.default.store(_ data: Data) throws -> String` (returns hash). `ArtworkCache.default.data(forHash:) -> Data?`.
- `LibraryService`: `@Observable @MainActor final class` with `modelContainer: ModelContainer`, `metadata: MetadataService`. `scan(root:)` is private. Has `applyScanItem`, `upsert`. File: `Muses/Sources/Muses/Services/Library/LibraryService.swift`.
- `MusesApp.init()` creates `LibraryService(modelContainer:container, metadata:meta)`. File: `Muses/Sources/Muses/App/MusesApp.swift`.
- iTunes Search API: `https://itunes.apple.com/search?term=<encoded>&entity=song&limit=5` — free, no token. Response JSON: `{ results: [{ trackName, artistName, collectionName, releaseDate, artworkUrl100 }] }`. Artwork upgrade: replace `100x100bb` with `600x600bb` in the URL.
- MusicBrainz API: `https://musicbrainz.org/ws/2/release-group/?query=<encoded>&fmt=json` — requires User-Agent header, 1 req/sec rate limit. Response: `{ "release-groups": [{ id, title, "first-release-date" }] }`. Cover Art Archive: `https://coverartarchive.org/release/<mbid>/front` — redirects to image.
- URLSession: standard `URLSession.shared` or injectable for testing.
- URLProtocol: for test stubs, subclass URLProtocol, register in URLSessionConfiguration.

**Implementation:**

1. **EnrichmentEndpoint.swift** — enum with static methods building URLs:
```swift
enum EnrichmentEndpoint {
    static func itunesSearch(term: String) -> URL { ... }
    static func musicBrainzReleaseGroup(query: String) -> URL { ... }
    static func coverArt(releaseId: String) -> URL { ... }
}
```

2. **MetadataEnricherService.swift** — `@MainActor final class`:
- Properties: `session: URLSession`, `artworkCache: ArtworkCache`, `modelContainer: ModelContainer`
- `func enrich(_ track: Track) async` — sets track.metadataStatusRaw = .enriching, tries iTunes Search first (parse JSON, upgrade artwork URL to 600x600, download artwork → ArtworkCache.store → set localArtworkHash, set artworkUrl/albumTitle/year). If iTunes misses, try MusicBrainz (1 req/sec rate limit via sleep). Set .complete on success, .missing on failure. Save to ModelContext.
- iTunes response parsing: use `JSONSerialization` or Codable structs.
- Rate limiting: `private var lastMBRequest: Date = .distantPast`, sleep if needed before MB requests.

3. **MetadataEnricherServiceTests.swift** — Use URLProtocol stub:
- Test "iTunes search upgrades artwork to 600x600": stub returns iTunes JSON with artworkUrl100 containing "100x100bb", assert enricher extracts and upgrades to "600x600bb".
- Test "no results sets metadataStatus to missing": stub returns empty results, assert .missing.
- Use a custom URLSessionConfiguration with URLProtocol subclass that returns canned JSON.
- Need a ModelContainer (inMemory: true) for Track persistence.
- Mark test struct @MainActor.

4. **MusesApp** — create `MetadataEnricherService` after LibraryService, inject into LibraryService.

5. **LibraryService** — add `var enricher: MetadataEnricherService?`. After scan completes, query tracks with metadataStatus == .embedded && (localArtworkHash == nil || albumTitle == nil), enrich them with concurrency limit 4 via TaskGroup.

**Build gate:** `swift build` — must pass.
**Test gate:** `swift test --no-parallel` — 38 existing + new tests must pass.
**Do NOT commit.** Report back with build result and test count.

---