# iOS JPEG + RAW companion backup

Status: approved by the user on 2026-10-25. Approach 1 selected by the user;
reuse the existing Live Photo upload flow for component sequencing, with strict
same-Photos-item eligibility and protection for existing stacks.

## Intent and agreed behavior

Back up both files belonging to one JPEG + RAW item in iOS Photos. Keep one
local photo and create an Immich stack whose primary is the processed image.
This addresses [discussion #18201](https://github.com/immich-app/immich/discussions/18201).

The user explicitly requires that uploading the JPEG must not exclude the RAW
from subsequent backups. The user chose optional companion state on the existing
local photo, rather than a general model of separate resource records.
The user subsequently asked whether existing combined-photo flows can be reused.
This revision proposes making the Live Photo upload sequence the starting point,
with new state limited to RAW discovery, presence, and stack completion.
The user also requires that automatic stacking occur only for a combined
RAW + JPEG item in iOS Photos, without grouping unrelated photos.

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
- Create an automatic stack only from a verified original RAW + JPEG resource
  pair within the same iOS Photos asset; never infer a relationship across items.

## Scope and constraints

Retain one local asset, its Photos identifier, and its album memberships. Add
optional RAW fields to that row. Use the current server's upload, checksum
deduplication, and stack APIs. Add a narrow opt-in guard to the existing stack
API so RAW pairing cannot merge or rearrange an existing stack. Regenerate its
API/SDK models; no older-server compatibility layer is planned. Preserve the
existing behavior of ordinary photos, standalone RAW images, videos, Android,
and Live Photos.

Limit this change to verified JPEG + RAW original pairs. Leave HEIF + RAW and
other compound formats on their existing paths. Do not infer a pair from
filenames, capture times, camera metadata, burst IDs, visual similarity, or
unrelated local or remote assets. Do not build a generic resource framework, new
settings screen, or new stack UI.

All version-control operations use Jujutsu. Any Python tooling must use the
project's `.venv`. Generated Pigeon and Drift files come from their generators.

## Approaches

1. **Optional companion state on the existing photo (selected).** Add discovery,
   checksum, and completion information for a single RAW companion. This fits the
   existing one-row-per-Photos-item model and keeps timeline and album identities
   intact. Extend the existing Live Photo component upload sequence and callback
   handling, with the existing stack API as the RAW pair's final association.
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

### Existing combined-photo flows to reuse

Live Photos already retain one local Photos item while uploading two files. The
foreground service uploads the motion video first, then the image with the
returned `livePhotoVideoId`. The background service queues the video, records its
role in task metadata, and queues the higher-priority image from the completion
callback. The upload repository supplies the HTTP transport, persistent
background queue, progress, and per-task retries. The server stores a dedicated
image-to-motion relationship and hides the motion asset; metadata extraction can
also associate matching Live Photo content identifiers.

Use this same companion-first sequence for RAW + processed pairs. Extend the
current services and task metadata; do not introduce another upload queue,
transport, scheduler, or parallel pair-orchestration service. Extract small
private helpers only where actual duplicated code requires them. RAW is a normal
image asset, so final association uses the existing stack API rather than
`livePhotoVideoId` or hidden-motion visibility.

Live Photos do not currently provide independent persistent local checksums and
completion state for both files. In the foreground path a failed motion upload
can still be followed by a successful image upload. Candidate selection then
considers the image checksum alone. Reusing that completion rule would violate
the user's requirement for RAW retries, so the RAW-specific pending state and
candidate changes in this design remain necessary. Fixing existing Live Photo
partial-backup behavior is outside this change.

Bursts do not supply a reusable compound-file uploader in this codebase. The
native bridge does not carry burst identifiers or explicitly expand burst
sequences; album fetches do not set `includeAllBurstAssets`. PhotoKit's
[default fetch behavior](https://developer.apple.com/documentation/photos/phfetchoptions/includeallburstassets)
returns the representative and user-picked members as separate assets. The server
extracts burst grouping metadata into `autoStackId`, but that is not a mobile
multi-component upload or retry flow. Preserve existing burst behavior.

## Native resource contract

Discover pairs by enumerating `PHAssetResource` entries without downloading their
contents. Classify RAW using the resource's uniform type and RAW-image
conformance, including camera RAW such as RAF and DNG. Resource position and
`.alternatePhoto` alone are insufficient identifiers of the RAW component.
Adjustment data, proxies, and paired video are not RAW companions.

### Strict automatic-stacking eligibility

The source of truth is one currently accessible `PHAsset.localIdentifier` with
both a RAW original and a JPEG original in its original photo resources:

1. Enumerate the resources of that exact Photos asset. Require an unambiguous
   original pair across `.photo` and `.alternatePhoto`, classified by actual
   uniform type: one RAW and one JPEG. Either format may occupy either role.
2. Do not treat a JPEG thumbnail, a preview embedded in RAW, or a JPEG generated
   by editing/exporting a standalone RAW as the second original. In particular,
   `.fullSizePhoto`, adjustment-base resources, and other edited derivatives
   cannot establish the existence of a combined original pair.
3. Carry the parent Photos identifier and selected original resource descriptors
   through hashing and upload. Obtain each remote component ID only from its
   exact-byte checksum match or the corresponding upload response. Filename or
   EXIF matches never supply association evidence.
4. Revalidate the same original pair before initial stack finalization. Stale
   callbacks, a changed/deleted Photos item, or uncertain resource classification
   must not trigger a stack operation.
5. Only verified pairs enter the new automatic-stacking path. JPEG and RAW stored
   as two separate Photos items follow their existing independent upload paths,
   even if their filenames, timestamps, or contents suggest a relationship.

Ambiguity leaves pairing unresolved and surfaces an error through the existing
backup flow; it never falls back to guessing. For a confirmed original pair,
existing edited-rendition selection may determine the processed upload, but an
edited rendition cannot turn a standalone RAW into an eligible pair.

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
| Pair, missing primary | Upload/reuse RAW, then upload primary | No |
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

Extend the companion handling already present in `ForegroundUploadService` and
`BackgroundUploadService`. Reuse `UploadRepository.uploadFile`,
`buildUploadTask`, the current background queue, task completion callbacks, and
the existing stack service. Add RAW resource export and independent pending
state at the storage/repository boundary. Avoid a new orchestration service;
small shared helpers may consolidate the presence and completion predicates.

1. Discover/select the pair and resolve its component hashes and remote presence.
2. Upload or reuse the RAW companion first, following the existing Live Photo
   video-first sequence. Persist its confirmed live remote ID before advancing.
   Upload RAW as a normal server image asset with its original filename.
3. Upload the processed image normally, or reuse its existing live remote ID.
   When the JPEG is already present, the RAW task still runs and its completion
   proceeds directly to stack finalization. Only the processed component carries
   the Photos cloud-ID metadata used to merge the local item with its remote
   counterpart.
4. Persist successful component uploads before proceeding. Server deduplication
   responses supply existing remote IDs; only non-trashed components count as
   successful presence.
5. Once both exist and the original-pair evidence is revalidated, create the
   stack with the processed ID first, subject to the stack-membership guard
   below. Update local remote/stack data and persist the completion receipt.
6. Report success for the local Photos item only after finalization succeeds.

Failures leave enough state to retry only missing work. Network loss, quota
errors, cancellation, RAW export failure, and stack failure do not erase a
successful primary upload. A restart with two successful uploads but a failed
stack retries the stack, even though both hashes are already on the server.

For background backup, extend the existing role metadata and completion callback
chain: RAW completion queues the processed image if needed, otherwise finalizes
the pair. Use component-specific task IDs; the two files must not collide under
the single Photos identifier. Recovered/duplicate callbacks must be safe after
app relaunch or a switch between foreground and background backup. Serialize
finalization per item, reject stale callbacks for replaced resources or another
account, and check actual synced
membership before retrying a stack whose response was lost.

Existing edited-upload stacking must run in a defined sequence so it cannot
overwrite the RAW pair or indirectly merge unrelated stacks. Apply these
membership guards to all automatic pair finalization:

- If both remote components are unstacked, create a stack containing exactly
  those two IDs, with the JPEG component first.
- If both are already in the same stack, accept that existing grouping without
  rewriting its membership or chosen primary. Existing user grouping takes
  precedence over the default for a newly created pair stack.
- If either component is in a different or non-matching stack, upload missing
  bytes but leave automatic pairing unresolved with a clear conflict error.
  Never merge stacks, pull an asset out of another stack, add unrelated members,
  or change an unrelated stack's primary to make this operation succeed.

The implementer proposes the conservative conflict behavior above to satisfy
the user's restriction; it is an explicit default for design review. Client-only
membership checks are insufficient because the existing stack API can merge
stacks and membership can change between a check and the request. Add an opt-in
non-merging mode to that same API, used for verified RAW + JPEG pair requests.
Within the server transaction, serialize access to the requested assets, check
their current memberships, and either create the exact two-item stack, return
their existing common stack unchanged, or reject a membership conflict without
mutating any stack. Existing ordinary stack calls retain their intended merge
behavior. A private helper and an API option name are implementer decisions;
enforcing the membership guard atomically on the server is a requirement.

This small server/API change replaces the earlier proposal of no server changes:
it is necessary to enforce the user's grouping restriction under concurrent
stack changes while continuing to use the existing stack endpoint.

Once automatic pairing has completed, do not continually recreate the stack or
reverse subsequent deliberate user unstacking/primary changes. A new
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
- Separate Photos items with matching filenames/times, burst siblings, similar
  images, and standalone RAW with an edited JPEG derivative never trigger the
  new stack path. HEIF + RAW remains unchanged.
- Uncertain/multiple candidate originals and stale pair evidence never trigger
  an automatic stack call.
- A deduplicated component already in another stack causes no merge, detachment,
  primary change, or extra stack members; an existing shared stack is preserved.
- Server tests cover the opt-in non-merging mode and concurrent membership
  changes; ordinary stack requests retain the existing merge behavior.
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
