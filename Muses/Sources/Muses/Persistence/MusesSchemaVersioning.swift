import Foundation
import SwiftData

//  Formal SwiftData versioning for the Muses store.
//
//  Why the current schema is V1 (Version 1, 0, 0) and not V2:
//  Every prior build constructed the schema with an *unversioned* `Schema([...])`,
//  whose `version` defaults to `Schema.Version(1, 0, 0)`. Phases 16–27 added new
//  models/columns through SwiftData's automatic lightweight migration, which never
//  changes the stamped version. As a result *every existing on-disk store carries
//  version `1.0.0`* regardless of when it was created.
//
//  Declaring the current 18-model schema as `MusesSchemaV1` (`1.0.0`) therefore makes
//  existing stores match the declared version exactly: opening them is a no-op
//  migration (no stage runs), so there is zero risk to user data. The historical
//  10-model baseline is recorded as `MusesSchemaV0` (`0.1.0`) — a version that never
//  shipped as a *versioned* schema, but represents the pre-upgrade table set. The
//  V0→V1 lightweight stage is exercised by `Phase16bMigrationTests` against a
//  from-scratch V0 fixture, proving the migration machinery works without ever
//  touching a real store. Future schema changes add V2 with a real V1→V2 stage.

/// Historical 10-model baseline (pre-Phase-16 store). Used only by the migration
/// plan and the migration-test fixture; no real store carries this version.
enum MusesSchemaV0: VersionedSchema {
    static var models: [any PersistentModel.Type] {
        [Track.self, Album.self, Artist.self, ScanRoot.self, QueueState.self,
         EQPreset.self, YouTubeImport.self, YouTubeImportItem.self,
         Playlist.self, PlaylistItem.self]
    }
    static var versionIdentifier: Schema.Version { Schema.Version(0, 1, 0) }
}

/// Current 18-model schema. Version `1.0.0` matches the stamp on every existing
/// on-disk store (the unversioned `Schema([...])` default), so opening an existing
/// store under this versioned schema runs no migration stage.
enum MusesSchemaV1: VersionedSchema {
    static var models: [any PersistentModel.Type] {
        MusesSchemaV0.models + [
            ListeningEvent.self, ListeningSession.self, InboxItem.self,
            TrackNote.self, TrackBookmark.self, AlbumNote.self,
            AutomationRule.self, FocusSession.self,
        ]
    }
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
}

/// Single lightweight stage V0 → V1: adds the eight Phase 17–27 model tables
/// (and any additive optional columns) without touching existing rows. Existing
/// stores at `1.0.0` already match V1, so this stage only ever runs against a V0
/// fixture (see `Phase16bMigrationTests`).
enum MusesMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [MusesSchemaV0.self, MusesSchemaV1.self]
    }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: MusesSchemaV0.self, toVersion: MusesSchemaV1.self)]
    }
}