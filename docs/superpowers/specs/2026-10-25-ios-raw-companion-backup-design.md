# iOS JPEG + RAW companion backup

Status: proposed for user approval. Approach 1 selected by the user.

## Intent and agreed behavior

Back up both files belonging to one JPEG + RAW item in iOS Photos. Keep one
local photo and create an Immich stack whose primary is the processed image.
This addresses [discussion #18201](https://github.com/immich-app/immich/discussions/18201).

The user explicitly requires that uploading the JPEG must not exclude the RAW
from subsequent backups. The user chose optional companion state on the existing
local photo, rather than a general model of separate resource records.

This is a coordinated mobile change: native resource access, local database,
hashing, both upload services, completion reporting, and cleanup eligibility.

## Goals

- Upload the processed image and original RAW bytes with their correct filenames.
- Discover missing RAW companions even when the JPEG was uploaded before this fix.
- Retry each missing component and a failed stack operation after interruption or
  restart, without repeatedly uploading the successful component.
- Cover foreground, manual, and iOS background backup, including iCloud resources.
- Keep the processed image primary in the initial automatic stack.
- Keep backup counts and automatic local cleanup consistent with pair completion.

## Scope and constraints

Retain one local asset, its Photos identifier, and its album memberships. Add
optional RAW fields to that row. Use the current server's upload, checksum
deduplication, and stack APIs; no server changes or older-server compatibility
layer are planned. Preserve the existing behavior of ordinary photos, standalone
RAW images, videos, Android, and Live Photos.

The implementer proposes supporting processed HEIF + RAW as well as JPEG + RAW
when PhotoKit exposes the same two-resource structure. Do not infer a pair from
matching filenames or from unrelated assets. Do not build a generic resource
framework, new settings screen, or new stack UI.

All version-control operations use Jujutsu. Any Python tooling must use the
project's `.venv`. Generated Pigeon and Drift files come from their generators.

## Approaches

1. **Optional companion state on the existing photo (selected).** Add discovery,
   checksum, and completion information for a single RAW companion. This fits the
   existing one-row-per-Photos-item model and keeps timeline and album identities
   intact. It deliberately specializes the backup model to processed + RAW pairs.
2. **Separate resource records.** Store each underlying file beneath its parent
   Photos item. This generalizes to other compound formats but broadens the
   database, sync, and upload abstractions beyond this request. The user selected
   approach 1 to keep the change focused.

## Current behavior and relevant code

- `mobile/ios/Runner/Sync/PHAssetExtensions.swift` selects one resource.
- `mobile/ios/Runner/Sync/MessagesImpl.swift` hashes that one resource.
- `mobile/pigeon/native_sync_api.dart` exposes one hash per asset.
- `LocalAlbumRepository.getAssetsToHash` selects only null primary checksums.
- `BackupRepository.getCandidates` and its counts consider a primary checksum
  match sufficient to complete backup.
- `ForegroundUploadService.uploadSingleAsset` exits early for an existing remote
  JPEG. Both it and `BackgroundUploadService` retrieve one image through
  `StorageRepository` and `photo_manager`, with separate handling for Live Photos.
- `LocalAssetRepository.getRemovalCandidates` considers the primary checksum
  sufficient for automatic local cleanup.
- The stack API accepts the primary first; the existing mobile asset service can
  update the local remote-asset and stack state.

## Native resource contract

Discover pairs by enumerating `PHAssetResource` entries without downloading their
contents. Classify RAW using the resource's uniform type and RAW-image
conformance, including camera RAW such as RAF and DNG. Resource position and
`.alternatePhoto` alone are insufficient identifiers of the RAW component.
Adjustment data, proxies, and paired video are not RAW companions.

For a genuine pair, select exactly one processed image and its original RAW.
Use the current edited processed rendition when one exists, preserving the
existing preference for edited output; otherwise use the imported processed
original. Keep the original RAW independent of processed-image edits. The exact
resource selector must be shared by hashing and export so that each stored hash
describes the exact uploaded bytes. Do not route pair export through an API that
silently renders RAW to JPEG.

Expose the metadata discovery, role-specific hashing, and exact file export
through the native bridge. Return a resource descriptor (role, resource type,
original filename, uniform type) and independent failures. A missing or failed
RAW request must never be interpreted as proof that there is no RAW.

Stream hashing and export rather than buffering full RAW files. Respect the
existing network policy and cancellation. Use unique temporary paths and clean
up partial exports; background upload files remain available until their tasks
finish or are cancelled. Regenerate the Dart, Swift, and Kotlin bridge outputs;
Android reports no companion and retains its existing upload path.

Apple documents [multiple resources per Photos asset](https://developer.apple.com/documentation/photos/phassetresource)
and [resource-specific file export](https://developer.apple.com/documentation/photos/phassetresourcemanager/writedata(for:tofile:options:completionhandler:)).

## Persistent state and discovery

Add optional fields to `LocalAssetEntity` and the local domain model for:

- RAW discovery: unknown, no companion, or companion present.
- The selected RAW resource descriptor and its checksum, nullable until hashed.
- Durable successful-upload and stack-completion information tied to the current
  authenticated server/user and the exact primary + RAW checksums or remote IDs.

Keep the current checksum as the processed-image checksum for pairs. A primary
checksum already restored through an iCloud mapping does not establish RAW
discovery or RAW upload success. If a legacy checksum represents a different
resource, resolve the pair's processed checksum using the shared native selector;
do not misclassify its previously uploaded RAW as the JPEG.

Use a Drift migration that preserves existing photos and primary checksums.
Existing iOS image rows begin with unknown companion discovery. Before backup
completion or automatic cleanup is trusted, perform bounded discovery on unknown
images, including images with non-null checksums and existing remote matches.
Discovery requires metadata only; download and hash missing RAW data only when
existing backup/network policy permits it. Persist successful discovery so a
restart resumes rather than rescanning every known photo.

Update full and incremental local sync so discovery and hash state remain valid
only for the matching resources. Reevaluate resource metadata on Photos changes;
preserve unchanged RAW hashes across processed-image edits. A replaced or removed
companion invalidates its old upload/stack receipt. Removing a local asset removes
its companion state. Unknown or ambiguous discovery remains retryable.

The exact column names and native method signatures are implementer decisions;
the state distinctions and account/resource scoping above are requirements.

## Backup selection and completion

Use one shared definition of completion in backup queries, service success
callbacks, counts, and automatic local cleanup:

| State | Backup action | Complete / eligible for cleanup |
| --- | --- | --- |
| Companion unknown | Discover resources | No |
| No companion | Existing single-asset behavior | Existing behavior |
| Pair, missing primary | Upload primary; also schedule missing RAW | No |
| Pair, primary present, missing RAW/hash | Hash or upload RAW | No |
| Pair, both files present, initial stack pending | Retry stacking only | No |
| Pair, both present, initial stack completed | No work | Yes |

Keep backup totals in units of local Photos items: a pair counts once. An unknown
or unhashed companion contributes to processing/remainder rather than backed-up
counts. Album selection/exclusion and cellular restrictions apply to the entire
pair. A JPEG remote match may still be used to show its thumbnail, but must not
make a pair eligible for cleanup or trigger a backup-success callback prematurely.

Remote presence must be checked for the current account and must exclude trashed
or permanently removed components. A cached upload receipt bridges delayed remote
sync; it cannot permanently override a later authoritative remote deletion.

The implementer proposes leaving deliberately trashed components in Trash rather
than restoring them automatically. A required component in Trash leaves the pair
pending and produces a backup error explaining that the user can restore it or
permanently delete the remote copy before retrying. The existing server checksum
check exposes `isTrashed`; validate deduplication IDs against live status because
the duplicate-upload response itself can return a trashed asset ID. This avoids
reporting a recoverable backup where no live component exists, without reversing
a deliberate remote deletion. This policy is a proposed default for user review.

## Upload orchestration and retries

Put shared pair preparation, presence resolution, durable completion, and stack
finalization in a focused helper/service used by both upload paths. Keep transport
details in the existing foreground and background services.

1. Discover/select the pair and resolve its component hashes and remote presence.
2. Reuse a remote primary when present; otherwise upload it normally.
3. Upload the missing RAW as a normal server asset, not a hidden Live Photo video.
   Only the processed component carries the Photos cloud-ID metadata used to
   merge the local item with its remote counterpart.
4. Persist successful component uploads before proceeding. Server deduplication
   responses supply existing remote IDs; only non-trashed components count as
   successful presence.
5. Once both exist, create/update the stack with the processed ID first, update
   local remote/stack data, and persist the completion receipt.
6. Report success for the local Photos item only after finalization succeeds.

Failures leave enough state to retry only missing work. Network loss, quota
errors, cancellation, RAW export failure, and stack failure do not erase a
successful primary upload. A restart with two successful uploads but a failed
stack retries the stack, even though both hashes are already on the server.

Use component-specific background task IDs and task metadata; the two files must
not collide under the single Photos identifier. Completion may arrive in either
order and after app relaunch. Serialize finalization per item, reject stale
callbacks for replaced resources or another account, and check actual synced
membership before retrying a stack whose response was lost.

Existing edited-upload stacking must run in a defined sequence so it cannot
overwrite the RAW pair. Preserve other members of an existing stack when adding
the RAW. Once automatic pairing has completed, do not continually recreate the
stack or reverse subsequent deliberate user unstacking/primary changes. A new
processed revision or newly uploaded replacement component may require a new
initial finalization; a manual stack change by itself does not.

## Errors, cleanup, and observable behavior

Use existing backup progress and error presentation, identifying the actual
component filename. Byte progress can run per component; item completion happens
once. Do not add a settings or migration prompt. Successful upload counts must
not be incremented for both component callbacks.

Automatic cleanup must independently confirm discovery and both live remote
components; it must not depend on the JPEG's merged storage state. Manual user
deletion retains its existing explicit behavior. Temporary-file cleanup must not
remove files belonging to pending background tasks.

## Verification

Add regression coverage for the behavior, using the existing Dart repository and
upload tests and native selector coverage where the project tooling supports it:

- JPEG already remote + RAW missing remains a candidate and uploads only RAW.
- Both files are missing; both reach the server, with JPEG as stack primary.
- RAW-first PhotoKit ordering and processed-as-alternate ordering select correctly.
- A RAW failure/restart retains the JPEG and retries RAW; stack failure retries
  stacking without uploading either file again.
- Background callbacks in either order, duplicate callbacks, cancelled tasks,
  delayed remote sync, stale callbacks, and account switches are handled safely.
- Existing non-null JPEG checksums still enter discovery after database upgrade.
- Unknown discovery, missing/unhashed RAW, and trashed RAW prevent automatic
  cleanup and do not count as fully backed up.
- A duplicate response pointing at Trash leaves backup pending with a useful
  error; restoring that component allows a later retry to finish.
- Processed edits preserve unchanged RAW and produce the correct primary/stack.
- Regular JPEG, standalone RAW, HEIF + RAW, Live Photo, and Android paths retain
  their intended behavior; original filenames/extensions and cloud-ID roles agree.

Run the focused unit and migration tests, applicable mobile analysis/formatting,
and an iOS build if the local Flutter/Xcode setup permits it. Finally validate on
an iOS device using imported Fujifilm JPEG + RAF and a DNG pair, including an
iCloud-only RAW and interrupted background transfer. Report device-only checks
as outstanding if no suitable device/library is available; do not claim that
mocked tests establish PhotoKit's real resource behavior.

## Implementation discretion

The implementer chooses private helper organization, field names, batching,
temporary-directory layout, and test harness details. Preserve the completion
invariants without expanding the feature into a general asset-resource rewrite.
No product code should be written until this design is approved.
