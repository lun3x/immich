# iOS RAW Companion Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Back up both originals of a combined iOS JPEG + RAW item, retry an omitted RAW independently, and automatically stack only that verified pair.

**Architecture:** Extend the existing foreground upload and background Live Photo sequencing: RAW first, processed image second, existing stack API last. Keep one local Photos item with optional RAW state. Add an opt-in, atomic non-merging mode to the stack endpoint; native PhotoKit resource identity is the only evidence that a pair exists.

**Tech Stack:** Flutter/Dart, Riverpod, Drift/SQLite, Pigeon, Swift/PhotoKit/CryptoKit/UniformTypeIdentifiers, Kotlin bridge stubs, NestJS/Zod/Kysely/PostgreSQL, Vitest, OpenAPI generators.

**Spec:** [Approved design](../specs/2026-10-25-ios-raw-companion-backup-design.md).

## Global Constraints

- All version-control operations use Jujutsu. Any Python tooling must use the project's `.venv`.
- Limit this change to verified JPEG + RAW original pairs. Leave HEIF + RAW and other compound formats on their existing paths.
- The source of truth is one currently accessible `PHAsset.localIdentifier` with both a RAW original and a JPEG original in its original photo resources.
- Do not infer a pair from filenames, capture times, camera metadata, burst IDs, visual similarity, or unrelated local or remote assets.
- Generated Pigeon and Drift files come from their generators.
- No older-server compatibility layer is planned.
- Preserve existing ordinary-photo, standalone-RAW, Android, burst, and Live Photo behavior. Reuse the existing queue and transports; add no pair-orchestration service.
- A pair remains pending until both live components exist and initial stack finalization succeeds. Never automatically restore Trash or overwrite a subsequent manual stack choice.

## Review Focus

- Two unrelated Photos items with matching filenames/times must not become a pair; negative native and upload cases belong to Tasks 2 and 6.
- A rendered JPEG derivative of standalone RAW must not establish an original pair; descriptor-based native cases belong to Task 2.
- A delayed callback from an old account, server, or resource revision must not mutate the current item or its stacks; receipt and callback cases belong to Tasks 3 and 7.
- An upload returning a duplicate ID in Trash must remain pending, including when remote sync has not caught up; authoritative-presence cases belong to Tasks 4 and 5.
- Deduplicated files already in other stacks and concurrent membership changes must not merge or detach unrelated assets; real-database cases belong to Task 1, and mobile call assertions to Task 4.

## Execution and setup

This is one connected feature, not independently shippable subsystem projects: its native resource identity feeds persistent state, both transports, and guarded finalization. Execute Tasks 1–8 in order and keep each intermediate change buildable.

Before implementation, use `superpowers:using-git-worktrees`, adapted to the repository's Jujutsu requirement: reuse this clean workspace or create a `jj workspace`, not a Git worktree. Use a `codex/` bookmark if a named bookmark is needed. Do not publish, push, or open an upstream PR as part of this plan.

The planning checkout has pnpm and Apple tool shims, but `flutter`, `dart`, and `mise` are not currently on PATH; dependency directories/code generation are absent. During execution, locate or install the pinned runtimes from root/mobile `mise.toml` (Node 24.22.1, pnpm 12.14.0, Flutter 3.47.2, Java 21.0.2), then use the existing setup tasks. Check actual Xcode and Docker availability. A missing runtime is an environment failure, not the intended failing regression test.

Commands below run from the repository root unless a `mobile` or `server` working directory is stated. Bootstrap with the repository's `mise run //:plugins`, `mise run //server:install`, `mise run //:open-api-dart`, `mise run //mobile:install`, and necessary mobile codegen tasks. Do not run the destructive `clean` task. Generated mobile SDK/Pigeon/Drift files are ignored; regenerate them locally without force-tracking them.

## File ownership and shared contracts

| Area | Source files and responsibility |
| --- | --- |
| Guarded stacking | `server/src/dtos/stack.dto.ts`, `server/src/services/stack.service.ts`, `server/src/repositories/stack.repository.ts`: opt-in non-merging creation; existing merge calls retain behavior |
| Native resource identity | New `mobile/ios/Runner/Sync/RawPhotoResourceSelector.swift`; existing `PHAssetExtensions.swift`, `MessagesImpl.swift`: select originals, hash/export exact resources, revalidate evidence |
| Bridge | `mobile/pigeon/native_sync_api.dart`; Android `sync/MessagesImplBase.kt`: typed pair discovery, resource operations, unsupported-platform results |
| Domain/state | New `mobile/lib/domain/models/asset/raw_jpeg_pair.model.dart`; existing local asset model/table/database and repositories: pair descriptors, hashes, scoped receipts, migration |
| Shared asset operations | Existing `asset.service.dart`, `asset_api.repository.dart`, `remote_asset.repository.dart`, storage repository/providers: pair preparation, remote presence, receipts, guarded stack finalization |
| Existing transports | Existing foreground/background upload services, upload repository, backup provider: staged uploads and one item-level completion |
| Completion/cleanup | Backup/local-asset repositories, sync-stream repository, cleanup service: consistent pending state and deletion eligibility |
| Generated API | `open-api/immich-openapi-specs.json`, `packages/sdk/src/fetch-client.ts`, ignored mobile OpenAPI output: regenerate from DTO sources |

Use these names consistently across tasks; private implementations remain flexible:

- Domain `PhotoResource`: immutable `key`, `type` (PhotoKit resource integer), `filename`, and `uniformTypeIdentifier`; `key` unambiguously identifies that resource descriptor within one asset.
- Domain `RawJpegPair`: `assetId`, `pairKey`, `jpegOriginal`, `rawOriginal`, `processed` (`PhotoResource` values). `pairKey` includes the original descriptors, selected processed descriptor, and source revision. Plain `toMap`/`fromMap` serialization lives in the model file, not generated bridge types.
- `RawPairDiscovery { unknown, absent, present }`. Errors/ambiguity remain `unknown` with an explicit result error, never `absent`.
- `RawPairReceipt`: `serverEndpoint`, `ownerId`, `pairKey`, nullable `rawId`/`jpegId`, nullable `rawTaskId`/`jpegTaskId`, and `completed`. A receipt is tied to all three scope identifiers; it is not authoritative remote presence. Task claims allow restart recovery without introducing another queue.
- Add `rawPairDiscovery`, `rawJpegPair`, `rawChecksum`, and `rawPairReceipt` to `LocalAsset` with defaults preserving existing call sites.
- Store these on the same local row: `rawPairState` (enum, default unknown), `rawPair` (nullable serialized descriptor), `rawChecksum`, `rawReceiptServer`, `rawReceiptUserId`, `rawReceiptPairKey`, `rawReceiptRawId`, `rawReceiptJpegId`, `rawReceiptRawTaskId`, `rawReceiptJpegTaskId`, `rawPairCompleted` (default false). No companion table or second local asset.
- `RawPairRemoteIds`: nullable `jpegId`/`rawId` plus `jpegTrashed`/`rawTrashed`. IDs come from authoritative checksum checks for the active user.

## Task 1: Add atomic non-merging mode to the existing stack API

**Files:** Modify `server/src/dtos/stack.dto.ts`, `server/src/services/stack.service.ts`, `server/src/repositories/stack.repository.ts`; test existing `server/src/services/stack.service.spec.ts`, `server/test/medium/specs/services/stack.service.spec.ts`, `server/src/controllers/stack.controller.spec.ts`; regenerate OpenAPI and TypeScript SDK sources.

**Interfaces:** Add optional `allowMerge: boolean` to `StackCreateDto`; omission keeps existing merge behavior. Add `StackRepository.createWithoutMerging(entity: Omit<Insertable<StackTable>, 'primaryAssetId'>, assetIds: [string, string]): Promise<{ status: 'created' | 'existing'; stack: Stack } | { status: 'conflict' }>`. Keep existing repository `create` unchanged. The service requires exactly two distinct IDs when `allowMerge === false`, maps conflict to HTTP 409, and emits `StackCreate` only for a newly created stack in this mode.

- [x] **Step 1: Add failing service/DTO and real-database tests.** Use existing `factory.auth`, medium context, and asset/stack factories. Seed the following states; assertions must inspect every affected asset's `stackId`, stack membership, primary, and emitted events:

```typescript
it('rejects one component already stacked elsewhere without any mutation', async () => {
  const { sut, ctx } = setup();
  const { user } = await ctx.newUser();
  const auth = factory.auth({ user });
  const { asset: jpeg } = await ctx.newAsset({ ownerId: user.id });
  const { asset: raw } = await ctx.newAsset({ ownerId: user.id });
  const { asset: other } = await ctx.newAsset({ ownerId: user.id });
  await sut.create(auth, { assetIds: [jpeg.id, other.id] });
  const readRows = () => ctx.database.selectFrom('asset').select(['id', 'stackId'])
    .where('ownerId', '=', user.id).orderBy('id').execute();
  const before = await readRows();
  await expect(sut.create(auth, { assetIds: [jpeg.id, raw.id], allowMerge: false }))
    .rejects.toBeInstanceOf(ConflictException);
  expect(await readRows()).toEqual(before);
});
// creates_exact_pair: returned IDs == [jpeg.id, raw.id], primary == jpeg.id.
// returns_common_stack: stack ID/membership/primary unchanged; no new event.
// rejects_different_stacks: all affected rows/stack records unchanged.
// rejects_repeated_ids: BadRequestException; rejects missing/trashed/foreign IDs without writes.
// waits_for_membership_write: sees the committed conflicting membership, returns conflict.
// competing_strict_requests: exactly one succeeds, losing request adds no members.
// ordinary_merging: omitted allowMerge retains the complete preexisting merged membership.
// immediate_post_upload: response includes both assets even before EXIF rows exist.
```

- [x] **Step 2: Run the new tests and confirm assertion/contract failures.** `pnpm --dir server test --run src/services/stack.service.spec.ts src/controllers/stack.controller.spec.ts`; `pnpm --dir server test:medium --run test/medium/specs/services/stack.service.spec.ts`. Docker is required for the medium suite.
- [x] **Step 3: Implement the interface.** In one transaction, lock both asset rows in stable ID order before reading membership; verify current owner/live status. Create exactly two members only when both are unstacked, return an existing common stack unchanged, or return conflict with no writes. Coordinate any needed stack-row access with concurrent deletion/primary changes; prove this with the medium tests. Do not invoke the existing merge branch for strict requests. Make immediate post-upload responses usable before metadata extraction has created EXIF rows; narrowly adapt the stack response projection if required rather than inventing another endpoint.
- [x] **Step 4: Rerun those tests, `pnpm --dir server check`, and regenerate with `mise run //:open-api`.** Expect passing tests/types and only the intended schema/client changes; do not hand-edit generated contracts.
- [x] **Step 5: Commit:** `jj commit -m 'feat(server): add guarded non-merging stack creation'`.

## Task 2: Detect original pairs and hash/export exact native resources

**Files:** Create the domain model file above, `mobile/ios/Runner/Sync/RawPhotoResourceSelector.swift`, and `mobile/test/native/raw_photo_resource_selector_test.swift`; modify `mobile/pigeon/native_sync_api.dart`, iOS `PHAssetExtensions.swift`/`MessagesImpl.swift`, `mobile/lib/infrastructure/repositories/storage.repository.dart`, `mobile/lib/providers/infrastructure/storage.provider.dart`, and `mobile/android/app/src/main/kotlin/app/alextran/immich/sync/MessagesImplBase.kt`; test new `mobile/test/infrastructure/repositories/storage_repository_test.dart`.

**Interfaces:** Add Pigeon `PlatformPhotoResource` with the domain descriptor fields, `PlatformRawJpegPair` with the domain pair fields, `RawJpegPairResult(assetId, pair?, error?)`, `PhotoResourceRequest(assetId, pairKey, resource)`, and `PhotoResourceHashResult(assetId, resourceKey, hash?, error?)`. Add async native methods `getRawJpegPairs(List<String> assetIds)`, `hashPhotoResources(List<PhotoResourceRequest> requests, {bool allowNetworkAccess = false})`, `exportPhotoResource(PhotoResourceRequest request, String destinationPath, {bool allowNetworkAccess = false}) -> String`, and `cancelPhotoResourceExport(String destinationPath) -> void`. Extend existing `cancelHashing` to cancel the new hash operations too. Export returns the completed destination path or a platform error.

The pure native selector is `selectRawJpegPair(assetId: String, revision: String, resources: [RawPhotoResourceDescriptor]) throws -> RawPhotoResourceSelection?`. Each native descriptor adds `assetId` and `isCurrent` to the domain descriptor fields; selection exposes original JPEG/RAW and processed descriptors plus `pairKey`. It imports Foundation/UniformTypeIdentifiers, not generated Pigeon or Flutter code; the PhotoKit extension builds its inputs and maps its result to Pigeon. Construct a stable pair key from the descriptors and revision, and reject duplicate descriptor keys.

- [x] **Step 1: Write failing native selector and storage tests.** The selector consumes plain Swift resource descriptors, so its same production selection code can run in a small macOS command-line test executable without a Flutter test target. Use a standalone `@main` entry point with named checks that exit nonzero on a failed precondition. Assert:

```swift
// Named fixtures/checks in raw_photo_resource_selector_test.swift:
// jpegAndRafOriginals: selected original roles match actual UTTypes.
// rawFirstAndJpegAlternate: same result independent of array ordering.
// standaloneRawWithFullSizeJpeg: selected pair == nil.
// separateParentsWithMatchingNames: selected pair == nil.
// rawWithEmbeddedPreview, livePhotoOnly, heifAndRaw: selected pair == nil.
// ambiguousOriginals: explicit error, never an arbitrary pair.
// confirmedPairWithEditedOutput: original proof retained; processed selection follows current rendition.
```

In Dart, mock bridge responses: discovery does not export/download; requested descriptor/pair key survives export; cancellation targets the actual destination; errors do not become absence; extensions/filenames match the selected resource.

- [x] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/infrastructure/repositories/storage_repository_test.dart`. Compile native checks using `xcrun swiftc -parse-as-library ios/Runner/Sync/RawPhotoResourceSelector.swift test/native/raw_photo_resource_selector_test.swift -o .dart_tool/raw-photo-selector-tests`, then run `.dart_tool/raw-photo-selector-tests`. Expected initial failure is missing selector/bridge contract, followed by failing fixture checks as implementation begins.
- [x] **Step 3: Implement the model and native APIs; add storage wrappers.** `StorageRepository` receives `NativeSyncApi` via its existing provider. Add `getRawJpegPair(String assetId) -> Future<RawJpegPair?>`, `hashPhotoResources(List<PhotoResourceRequest>, {required bool allowNetworkAccess})`, and `exportPhotoResource(PhotoResourceRequest, {required bool allowNetworkAccess, Completer<void>? cancelToken}) -> Future<File>`. The wrapper owns unique temporary destinations and forwards cancellation. Native selection requires one original `.photo` and one `.alternatePhoto`, RAW/JPEG type conformance, and the same parent; `.fullSizePhoto` may only select the processed rendition after proof exists. Resource keys must be unique; native operations revalidate the pair/revision. Hash and export the same descriptor, stream bytes, bound concurrent reads, respect network policy, and delete partial files on failure. Android returns no pair and does not enter these resource operations. Do not change standalone-RAW selection.
- [x] **Step 4: Generate and rerun.** From `mobile`: `dart run pigeon --input pigeon/native_sync_api.dart`, then the tests above. Expect positive and negative selector checks and wrapper tests to pass. Generated native/Dart outputs stay ignored.
- [x] **Step 5: Commit:** `jj commit -m 'feat(mobile): access verified iOS JPEG and RAW resources'`.

## Task 3: Persist companion state and discover old JPEG-only backups

**Files:** Modify `mobile/lib/domain/models/asset/base_asset.model.dart`/`local_asset.model.dart`, `mobile/lib/data/db/main/table/local/asset.dart`, `mobile/lib/data/db/main/database.dart`, `mobile/lib/infrastructure/repositories/local_asset.repository.dart`/`local_album.repository.dart`, `mobile/lib/domain/services/asset.service.dart`/`hash.service.dart`/`local_sync.service.dart`, and `mobile/lib/providers/infrastructure/asset.provider.dart`/`sync.provider.dart`; test the exact files in Step 2. Extend `mobile/test/medium/repository_context.dart` and existing local-asset factories/mocks. Generate `mobile/drift_schemas/main/drift_schema_v36.json` and ignored migration/test bindings.

**Interfaces:** Implement `LocalAssetRepository.saveRawPairDiscovery(String localId, RawJpegPair? pair) -> Future<void>`, `markRawPairDiscoveryUnknown(String localId) -> Future<void>`, `saveRawPairHashes(String localId, String pairKey, {String? jpegChecksum, String? rawChecksum}) -> Future<bool>`, `saveRawPairReceipt(String localId, RawPairReceipt receipt) -> Future<bool>`, and `clearRawPairReceipt(String localId) -> Future<void>`. Boolean writes use compare-and-set against the current pair key. Add `LocalAlbumRepository.getAssetsToDiscoverRawPairs(String albumId) -> Future<List<LocalAsset>>`. Add `AssetService.inspectRawJpegPair(LocalAsset asset) -> Future<LocalAsset>` (metadata only) and `prepareRawJpegPair(LocalAsset asset, {required bool allowNetworkAccess, Completer<void>? cancelToken}) -> Future<LocalAsset>` (inspect, hash missing roles, persist). Inject storage into the existing asset service and that service into the hash service, not another service.

- [x] **Step 1: Write failing persistence/discovery tests.** Extend fixtures with the exact columns in shared contracts. Test names and key assertions:

```dart
// migration_preserves_primary_checksum_and_marks_old_ios_images_unknown:
expect(upgraded.checksum, oldChecksum);
expect(upgraded.rawPairDiscovery, RawPairDiscovery.unknown);
// jpeg_remote_does_not_skip_raw_discovery:
expect(await albums.getAssetsToDiscoverRawPairs(albumId), contains(oldJpeg));
// changed_processed_rendition_preserves_unchanged_raw_hash:
expect(updated.rawChecksum, previousRawChecksum);
expect(updated.rawPairReceipt?.completed ?? false, isFalse);
// stale_hash_and_receipt_writes_are_rejected:
expect(await assets.saveRawPairReceipt(localId, oldRevisionReceipt), isFalse);
```

Also assert: Android bypass; no-pair discovery persists once; inspection errors remain unknown; removed/replaced originals invalidate relevant hashes; iCloud checksum reconciliation cannot establish RAW presence; manual preparation hashes a previously unhashed pair; duplicate album membership does not hash the same resource twice.

- [x] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/drift/main/migration_test.dart test/medium/repositories/local_album_repository_test.dart test/medium/repositories/local_asset_repository_test.dart test/unit/services/hash_service_test.dart test/domain/services/local_sync_service_test.dart test/unit/services/asset_service_test.dart`.
- [x] **Step 3: Implement schema v36 and state transitions.** Add only the optional same-row fields, mapped through `LocalAsset` and its copy/equality helpers. Preserve primary checksums at migration; discovery subsequently rehashes the processed role of a first-time verified pair rather than trusting a legacy hash of unknown resource identity. Keep raw hashes when the raw descriptor is unchanged. Local iOS updates mark pair evidence unknown before reuse, including updates whose adjustment timestamp is unchanged; compare the revision in full sync too. Inspect unknown items in bounded batches independently of null primary checksums, including already-remote images. Hash pair roles through Task 2; ordinary files retain the current hash API. Selected albums may download within existing policy; excluded albums never schedule pair work. Deduplicate discovery across albums. Newly encountered Android/non-image rows bypass discovery; cleanup queries must also gate unknown-state handling to iOS images.
- [x] **Step 4: Generate and rerun the tests.** From `mobile`: `dart run drift_dev make-migrations`, `dart run drift_dev schema generate --data-classes --companions drift_schemas/main/ test/drift/main/generated/`, and `dart run build_runner build`. Confirm v36's snapshot is tracked, generated Dart is ignored, and old migration paths/data preservation pass.
- [x] **Step 5: Commit:** `jj commit -m 'feat(mobile): persist and discover RAW companion backup state'`.

## Task 4: Resolve live remote components and finalize through guarded stacking

**Files:** Modify `mobile/lib/repositories/asset_api.repository.dart`, `mobile/lib/domain/services/asset.service.dart`, `mobile/lib/infrastructure/repositories/remote_asset.repository.dart`, `mobile/lib/providers/infrastructure/asset.provider.dart`, and the domain model from Task 2; test new `mobile/test/repositories/asset_api_repository_test.dart` and existing `mobile/test/unit/services/asset_service_test.dart`/`mobile/test/medium/repositories/remote_asset_repository_test.dart`.

**Interfaces:** Add `AssetApiRepository.checkUploadChecksums(Map<String, String> checksums) -> Future<Map<String, ({String? assetId, bool isTrashed})>>` using existing bulk-upload-check API; add `stackWithoutMerging(String jpegId, String rawId) -> Future<StackResponse>` sending `allowMerge: false`. Add `AssetService.resolveRawPairRemoteIds(LocalAsset asset) -> Future<RawPairRemoteIds>`, `recordRawPairUpload(LocalAsset asset, {required PhotoResourceRole role, required String remoteId}) -> Future<void>`, and `finalizeRawJpegPair(LocalAsset asset, {required String jpegId, required String rawId}) -> Future<void>`. Define `PhotoResourceRole { processed, raw }` in the domain model. Add `RemoteAssetRepository.upsertUploadedResource({required String remoteId, required String ownerId, required LocalAsset source, required PhotoResource resource, required String checksum}) -> Future<void>` for a minimal insert-only upload stub.

- [x] **Step 1: Write failing API/service tests.** Assert exact request and finalization semantics:

```dart
// Pair finalization sends [jpegId, rawId] and Optional.present(false) for allowMerge.
// Regular AssetApiRepository.stack still sends the existing request.
// Duplicate results map live IDs independently; a trashed result never maps to live presence.
// jpeg_exists_raw_missing: ids.jpegId == jpegId, ids.rawId == null.
// stale_pair_or_account: verifyNever(() => api.stackWithoutMerging(any(), any())).
// failed_stack: receipt.completed == false; both successful upload IDs retained.
// common_existing_stack: membership and primary remain as returned by server.
// completed_then_manually_unstacked: no repeated automatic stack request.
```

Also test a live upload whose remote-sync row is absent: its scoped receipt persists and an insert-only stub bridges sync delay; the stub cannot overwrite a newer trashed/deleted authoritative row.

- [x] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/repositories/asset_api_repository_test.dart test/unit/services/asset_service_test.dart test/medium/repositories/remote_asset_repository_test.dart`.
- [x] **Step 3: Implement the interfaces.** Bulk-check both exact hashes for the current user before reusing cached IDs and after duplicate upload responses; trashed components produce the existing backup error channel with restore/permanent-delete guidance. Before stacking, re-inspect native original-pair proof and compare account/server/pair key, rejecting stale results. Serialize finalization for that item within an isolate; server strict mode supplies cross-isolate concurrency safety. Treat two identical resolved IDs as an error. Persist receipts before advancing, call Task 1's strict API, update existing local remote/stack tables, then compare-and-set completed. Do not run ordinary edited-upload stacking on a pair; leave old uploaded renditions untouched rather than adding them or their other stack members. Existing edited-upload handling for non-pairs remains unchanged. A completed receipt prevents later manual stack edits from triggering automatic regrouping; genuine resource revision changes invalidate it through Task 3.
- [x] **Step 4: Rerun those tests and `dart analyze --fatal-infos`.** Expect no hidden RAW visibility, no RAW cloud-ID metadata, no filename-based lookup, and no call to ordinary merging stack creation in pair finalization.
- [x] **Step 5: Commit:** `jj commit -m 'feat(mobile): finalize verified RAW pairs without merging stacks'`.

## Task 5: Keep partial pairs in backup and out of automatic cleanup

**Files:** Modify `mobile/lib/infrastructure/repositories/backup.repository.dart`, `mobile/lib/infrastructure/repositories/local_asset.repository.dart`, `mobile/lib/infrastructure/repositories/sync_stream.repository.dart`, and `mobile/lib/services/cleanup.service.dart` (its provider is in the same file); test the exact files in Step 2.

**Interfaces:** Keep `BackupRepository.getCandidates`/`getAllCounts` public signatures. Create `mobile/lib/infrastructure/repositories/raw_pair_backup_predicate.dart` exposing `rawPairBackupComplete(Drift db, String userId, String serverEndpoint) -> Expression<bool>` for use by both repositories. Receipts are scoped by server/user/pair key and never replace live remote checksum matches. Existing sync update/delete methods invalidate receipts for the affected remote IDs. Add `LocalAssetRepository.getAssetsToInspectForCleanup(String userId, DateTime cutoffDate, {AssetKeepType keepMediaType = AssetKeepType.none, bool keepFavorites = true, Set<String> keepAlbumIds = const {}}) -> Future<List<LocalAsset>>`, applying normal removal filters but selecting unknown iOS images before the pair-completion guard. `CleanupService` public signatures stay unchanged; its provider gains the existing asset service for metadata discovery and authoritative presence checks.

- [x] **Step 1: Write failing query and cleanup tests using medium fixtures.** Seed one selected local pair, known primary hash, and only its JPEG remotely:

```dart
expect((await backup.getCandidates(userId)).map((a) => a.id), contains(localId));
expect(await backup.getAllCounts(userId), (total: 1, remainder: 1, processing: 1)); // RAW not hashed.
expect((await assets.getRemovalCandidates(userId, cutoff)).assets, isEmpty);
// After RAW hash exists but before upload/stack: remainder == 1, processing == 0.
// After both live remote rows and completed scoped receipt: remainder == 0, total == 1.
```

Cover: both bytes uploaded/stack pending; other owner; unknown discovery; excluded album; trashed RAW; actual remote deletion after upload; full remote-sync reset; stale receipt from another endpoint; complete pair deliberately unstacked; ordinary Android/video/photo cleanup. Cleanup must recheck authoritative live remote status for pair candidates and refuse them when that check fails. Add `cleanup_selection_becomes_stale_before_delete`: change/remove a pair resource after listing candidates and verify native deletion is not called for that item.

- [x] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/medium/repositories/backup_repository_test.dart test/medium/repositories/local_asset_repository_test.dart test/domain/repositories/sync_stream_repository_test.dart test/services/cleanup.service_test.dart`.
- [x] **Step 3: Implement the shared completion predicate.** A completed pair requires known current evidence, both hashes, current owner's non-trashed remote rows, and a completed receipt matching the pair/account. Unknown/unhashed evidence counts as processing; unfinished uploads or initial stacking count as remainder. Count one local item, preserving existing album exclusions. Invalidate the relevant receipt ID/completion on authoritative trash/deletion, including remote reset; subsequent reappearance can be finalized again. Insert-only stubs from Task 4 prevent unnecessary duplicate uploads during ordinary sync lag; fresh bulk presence checks, not those stubs, govern cleanup. Unknown non-pairs discovered by cleanup retain normal eligibility; unknown/present-but-unhashed pairs remain protected without downloading arbitrary iCloud RAW files. Recheck pair evidence/completion in `CleanupService.deleteLocalAssets` immediately before each deletion batch, because the selection can become stale. This does not alter explicit manual deletion through other services. On network failure return/delete only safely verified cleanup candidates.
- [x] **Step 4: Rerun the focused tests.** Expect the state table in the spec to match counts, candidates, and removal eligibility, with one item counted for a pair.
- [x] **Step 5: Commit:** `jj commit -m 'fix(mobile): keep incomplete RAW pairs pending for backup'`.

## Task 6: Extend foreground/manual uploads with the existing companion-first flow

**Files:** Modify `mobile/lib/services/foreground_upload.service.dart` and its existing tests, plus `mobile/test/providers/backup/backup_provider_test.dart` for item counts and `mobile/test/unit/services/remote_album_service_test.dart` for manual album upload callbacks.

**Interfaces:** Preserve `uploadSingleAsset`, `uploadManual`, and `UploadCallbacks`. Add private `_uploadRawJpegPair(LocalAsset asset, Completer<void>? cancelToken, UploadCallbacks callbacks) -> Future<void>` using Tasks 2–4; no new transport. Task 3's preparation determines whether this path applies before the old remote-primary early return.

- [x] **Step 1: Write failing upload tests.** Use the existing capture helpers and mock storage/asset service:

```dart
// raw_missing_jpeg_remote: captured filenames == ['DSCF0001.RAF']; stack receives [jpegId, rawId].
// both_missing: captured filenames == ['DSCF0001.RAF', 'DSCF0001.JPG'].
// raw_failure: no JPEG upload, no stack, success callback count == 0.
// stack_failure_after_both_uploads: onError called; receipt IDs survive; next attempt uploads 0 files.
// unrelated_matching_photo_items: ordinary upload path; no stackWithoutMerging calls.
// standalone_raw_with_edited_jpeg: ordinary upload path; no stackWithoutMerging calls.
// successful_pair: onSuccess count == 1, returned remote ID == jpegId.
```

Assert exact selected filenames/bytes, only processed upload has cloud metadata, RAW has ordinary visibility, cancellation/quota behavior, temp-file ownership, same hash dedup checks, manual unhashed pair preparation, and no changes to existing Live Photo tests. A manual album action receives one successful JPEG ID for the local item; the RAW stays accessible through its stack.

- [x] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/services/foreground_upload.service_test.dart test/providers/backup/backup_provider_test.dart test/unit/services/remote_album_service_test.dart`.
- [x] **Step 3: Implement the RAW branch around the existing uploader.** Respect the current connectivity/cellular guard; prepare pair evidence/hashes, resolve remote IDs, export/upload the missing RAW, persist it, then upload/reuse processed image and finalize. A RAW error or cancellation stops advancement for this item. On success emit exactly one existing item callback after finalization. Use `finally` to clean only foreground-owned completed/partial exports. Do not call ordinary `_handleUploadSuccess`'s edited-stack path for pairs. Non-pairs, share-intent files without Photos pair proof, and Live Photos retain their existing paths.
- [x] **Step 4: Rerun those tests.** Confirm the already-remote JPEG case transfers only RAW and retry-after-stack-failure transfers neither file.
- [x] **Step 5: Commit:** `jj commit -m 'feat(mobile): upload RAW companions through foreground backup'`.

## Task 7: Extend persistent background task chaining and recovery

**Files:** Modify `mobile/lib/services/background_upload.service.dart`, `mobile/lib/repositories/upload.repository.dart` only where queue ownership requires it, `mobile/lib/infrastructure/repositories/local_asset.repository.dart`, `mobile/lib/providers/backup/backup.provider.dart`, and `mobile/lib/domain/services/background_worker.service.dart`; test the exact files in Step 2.

**Interfaces:** Extend `UploadTaskMetadata` with `componentRole` (`regular`, `livePhotoVideo`, `rawCompanion`, `rawPairProcessed`), nullable `pairKey`, `serverEndpoint`, `ownerId`, `rawAssetId`, and the existing checksum/local-asset fields. Keep Live Photo metadata needs. Add private `_handleRawPairUpload(TaskStatusUpdate update) -> Future<void>` and `getRawPairUploadTask(LocalAsset asset, {required PhotoResourceRole role, String? rawAssetId}) -> Future<UploadTask?>`. Use the existing queue/group registration and `buildUploadTask`; task IDs include asset ID, component role, and pair key.

Add `LocalAssetRepository.claimRawPairTask(String localId, RawPairReceipt scope, PhotoResourceRole role, String taskId) -> Future<bool>` and `releaseRawPairTaskClaim(String localId, RawPairReceipt scope, PhotoResourceRole role, String taskId) -> Future<void>`. Claims compare account/server/pair key and the current role task ID atomically. After a crash, reconcile a retained claim with the persistent queue/database; if no task exists, release the matching claim and retry the same deterministic task ID. A stale claimant cannot clear a newer claim.

- [ ] **Step 1: Write failing background tests.** Feed captured completion callbacks exactly as the current Live Photo tests do:

```dart
// RAW completion queues processed only when missing; existing JPEG goes directly to finalization.
// Processed completion finalizes [jpegId, rawId]; callback advances item count only once.
// Repeat/recovered callbacks: no duplicate dependent enqueue or repeated stack mutation.
// Old owner/endpoint/pairKey: no enqueue, receipt write, or stack call.
// App relaunch after RAW success: reuse recorded RAW ID; no RAW bytes retransferred.
// App relaunch after both successes/stack failure: retry finalization without new upload tasks.
// Original pair removed before completion: stack API never called.
// Foreground completion racing a recovered task: native evidence/scoped state prevent stale finalization.
```

Test Wi-Fi requirements, task failures/cancellation, component-specific filenames and IDs, one cloud metadata owner, and pending export ownership. Existing Live Photo tests must still pass. Metadata from pre-change queued tasks may be explicitly cancelled/rebuilt under the current format; do not add a compatibility parser for old metadata.

- [ ] **Step 2: Run to confirm failure.** From `mobile`: `flutter test test/services/background_upload.service_test.dart test/providers/backup/backup_provider_test.dart test/domain/services/background_worker_service_test.dart`.
- [ ] **Step 3: Implement the callback chain.** Before queueing, prepare/hash and skip components with confirmed live remote IDs. RAW completion validates task/account/resource scope, records live presence, then queues the processed task or finalizes an existing JPEG. Processed completion finalizes before reporting item success. Reconcile active tasks and stored receipts on restart rather than relying on one callback being delivered; claim dependent work using a compare-and-set transaction against the current receipt/task state and deduplicate against the persistent queue's deterministic IDs. Route pair callbacks outside the ordinary edited-stack callback. Delay pair temporary-file deletion until the owning task is complete/cancelled, and stop broad cache clearing from deleting files of active tasks when starting/resuming another batch.
- [ ] **Step 4: Rerun those tests.** Expect pending pairs to survive missed/duplicate callbacks, app restart, and switches between the existing foreground/background modes.
- [ ] **Step 5: Commit:** `jj commit -m 'feat(mobile): chain and recover background RAW pair uploads'`.

## Task 8: Verify the integrated feature and document device evidence

**Files:** Add one cross-layer regression in existing upload/medium tests rather than a new framework; use `docs/superpowers/plans/2026-10-25-ios-raw-companion-backup.md` to record actual verification commands/results and outstanding device checks. Update source/test files only when these checks expose a concrete defect.

**Interfaces:** Consume the contracts from Tasks 1–7; introduce no new product API or scope.

- [ ] **Step 1: Add an integrated regression for an upgraded JPEG-only backup.** Seed v35 data, migrate/discover a same-asset JPEG + RAF pair, retain its remote JPEG, fail the first RAW transfer, recreate services, complete RAW, and verify exactly one strict pair stack, no JPEG transfer, correct counts, and cleanup exclusion until completion. Repeat with two separate Photos items and assert zero new stack requests.
- [ ] **Step 2: Run that regression and confirm any intended failure before fixing the integration.** Then rerun the touched task's focused tests; do not add duplicate tests that merely mirror helpers.
- [ ] **Step 3: Run the required automated checks once the feature is connected.** From `server`: `pnpm test --run src/services/stack.service.spec.ts src/controllers/stack.controller.spec.ts`, `pnpm test:medium --run test/medium/specs/services/stack.service.spec.ts`, `pnpm check`, and ESLint/Prettier on the changed source/test files. From `mobile`: run the focused tests listed above plus `flutter test test/drift/main`, `dart format --output=none --set-exit-if-changed lib test`, `dart analyze --fatal-infos`, `dart run custom_lint`, and `dcm analyze lib --fatal-style --fatal-warnings`; record unavailable/licensed tooling honestly. Regenerate Pigeon/Drift/OpenAPI and confirm no unexplained tracked diff. Build iOS with `flutter build ios --simulator --debug` and Android with `flutter build apk --debug` when their SDKs are available. Run the standalone Swift selector checks from Task 2.
- [ ] **Step 4: Validate on a real iOS library when available.** Import one genuine JPEG + RAF item and one JPEG + DNG item, plus separate same-named JPEG/RAW items and an edited standalone RAW. Test iCloud-only RAW, interrupted foreground/background transfer, a preexisting JPEG backup, stack conflict, and later manual unstacking. Compare downloaded originals' hashes with the source files; verify JPEG primary and no extra stack members. If no device/library is available, explicitly list these checks as outstanding rather than claiming mocks establish PhotoKit runtime behavior.
- [ ] **Step 5: Obtain a whole-change review, address actionable findings, and record final evidence.** Use `superpowers:requesting-code-review` and `superpowers:verification-before-completion`; keep all version-control actions in Jujutsu. Commit any integrated fixes with `jj commit -m 'test: verify iOS RAW companion backup recovery'`. Return the local result and material verification limits; do not publish an upstream PR automatically.

## Plan self-review

The native negative cases enforce the same-item restriction; the server task enforces non-merging under concurrency. State/discovery covers migration and legacy JPEG matches, upload tasks cover both transports and one completion callback, and query/sync/cleanup tasks cover remote removal and delayed synchronization. Role/descriptor names and receipt scope above are shared across task interfaces. Task 8 records actual build/device evidence; it is not permission to claim unavailable checks passed.

Execution: native approach selected by the user on 2026-10-25. Implement in this chat with one independent review at the end.
