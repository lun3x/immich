import 'dart:async';

import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/exif.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_exif.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/trashed_local_asset.repository.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:maplibre_gl/maplibre_gl.dart';

class AssetService {
  final StorageRepository _storageRepository;
  final RemoteAssetRepository _remoteRepository;
  final RemoteExifRepository _exifRepository;
  final LocalAssetRepository _localRepository;
  final AssetApiRepository _apiRepository;
  final AssetMediaRepository _mediaRepository;
  final TrashedLocalAssetRepository _trashedLocalRepository;

  const AssetService({
    required this._storageRepository,
    required this._remoteRepository,
    required this._exifRepository,
    required this._localRepository,
    required this._apiRepository,
    required this._mediaRepository,
    required this._trashedLocalRepository,
  });

  Future<LocalAsset> inspectRawJpegPair(LocalAsset asset) async {
    if (!CurrentPlatform.isIOS || asset.type != AssetType.image) {
      return asset;
    }
    final current = await _localRepository.getById(asset.id) ?? asset;
    if (current.rawPairDiscovery != RawPairDiscovery.unknown) {
      return current;
    }
    try {
      final pair = await _storageRepository.getRawJpegPair(asset.id);
      await _localRepository.saveRawPairDiscovery(asset.id, pair);
      return await _localRepository.getById(asset.id) ?? (throw StateError('Photos item no longer exists'));
    } catch (_) {
      await _localRepository.markRawPairDiscoveryUnknown(asset.id);
      rethrow;
    }
  }

  Future<LocalAsset> prepareRawJpegPair(
    LocalAsset asset, {
    required bool allowNetworkAccess,
    Completer<void>? cancelToken,
  }) async {
    final current = await inspectRawJpegPair(asset);
    if (!CurrentPlatform.isIOS || current.rawPairDiscovery != RawPairDiscovery.present) {
      return current;
    }
    final pair = current.rawJpegPair!;
    if (cancelToken?.isCompleted == true) {
      throw StateError('Photo resource hashing cancelled');
    }
    final requests = [
      if (current.checksum == null) pair.request(PhotoResourceRole.processed),
      if (current.rawChecksum == null) pair.request(PhotoResourceRole.raw),
    ];
    if (requests.isEmpty) {
      return current;
    }
    final results = await _storageRepository.hashPhotoResources(
      requests,
      allowNetworkAccess: allowNetworkAccess,
      cancelToken: cancelToken,
    );
    if (cancelToken?.isCompleted == true) {
      throw StateError('Photo resource hashing cancelled');
    }
    String? jpegHash;
    String? rawHash;
    for (final request in requests) {
      final matching = results.where((r) => r.assetId == asset.id && r.resourceKey == request.resource.key).toList();
      if (matching.length != 1 || matching.single.hash == null || matching.single.error != null) {
        continue;
      }
      if (request.resource.key == pair.processed.key) {
        jpegHash = matching.single.hash;
      }
      if (request.resource.key == pair.rawOriginal.key) {
        rawHash = matching.single.hash;
      }
    }
    if (!await _localRepository.saveRawPairHashes(
      asset.id,
      pair.pairKey,
      jpegChecksum: jpegHash,
      rawChecksum: rawHash,
    )) {
      throw StateError('Photo resources changed while hashing');
    }
    return (await _localRepository.getById(asset.id))!;
  }

  static final _rawPairFinalizations = <String, Future<void>>{};

  Future<LocalAsset> _assertRawPairCurrent(LocalAsset asset, RawPairReceipt scope) async {
    final current = await _localRepository.getById(asset.id);
    if (!CurrentPlatform.isIOS ||
        !await _localRepository.isRawPairScopeCurrent(scope) ||
        current?.rawPairDiscovery != RawPairDiscovery.present ||
        current?.rawJpegPair?.pairKey != scope.pairKey ||
        current?.checksum == null ||
        current?.rawChecksum == null ||
        current?.checksum != asset.checksum ||
        current?.rawChecksum != asset.rawChecksum) {
      throw StateError('Photo resources or backup account changed');
    }
    return current!;
  }

  Future<RawPairRemoteIds> resolveRawPairRemoteIds(LocalAsset asset, {RawPairReceipt? expectedScope}) async {
    final scope = expectedScope ?? await _localRepository.getRawPairScope(asset.rawJpegPair?.pairKey ?? '');
    await _assertRawPairCurrent(asset, scope);
    final result = await _apiRepository.checkUploadChecksums({'jpeg': asset.checksum!, 'raw': asset.rawChecksum!});
    await _assertRawPairCurrent(asset, scope);
    final jpeg = result['jpeg'];
    final raw = result['raw'];
    if (jpeg == null || raw == null) {
      throw StateError('Incomplete resource presence check');
    }
    final ids = RawPairRemoteIds(
      jpegId: jpeg.isTrashed ? null : jpeg.assetId,
      rawId: raw.isTrashed ? null : raw.assetId,
      jpegTrashed: jpeg.isTrashed,
      rawTrashed: raw.isTrashed,
    );
    final current = await _assertRawPairCurrent(asset, scope);
    final old = current.rawPairReceipt;
    if (old != null &&
        old.serverEndpoint == scope.serverEndpoint &&
        old.ownerId == scope.ownerId &&
        old.pairKey == scope.pairKey &&
        (old.rawId != ids.rawId || old.jpegId != ids.jpegId)) {
      if (!await _localRepository.saveRawPairReceipt(asset.id, _rawPairReceipt(scope, current, ids))) {
        throw StateError('Stale resource presence');
      }
    }
    return ids;
  }

  RawPairReceipt _rawPairReceipt(
    RawPairReceipt scope,
    LocalAsset current,
    RawPairRemoteIds ids, {
    bool completed = false,
  }) {
    final old = current.rawPairReceipt;
    final sameScope =
        old?.serverEndpoint == scope.serverEndpoint && old?.ownerId == scope.ownerId && old?.pairKey == scope.pairKey;
    return RawPairReceipt(
      serverEndpoint: scope.serverEndpoint,
      ownerId: scope.ownerId,
      pairKey: scope.pairKey,
      rawId: ids.rawId,
      jpegId: ids.jpegId,
      rawTaskId: sameScope ? old?.rawTaskId : null,
      jpegTaskId: sameScope ? old?.jpegTaskId : null,
      completed: completed,
    );
  }

  Future<void> recordRawPairUpload(
    LocalAsset asset, {
    required PhotoResourceRole role,
    required String remoteId,
    RawPairReceipt? expectedScope,
  }) async {
    final scope = expectedScope ?? await _localRepository.getRawPairScope(asset.rawJpegPair!.pairKey);
    final ids = await resolveRawPairRemoteIds(asset, expectedScope: scope);
    ids.requireNoTrash();
    if ((role == PhotoResourceRole.raw ? ids.rawId : ids.jpegId) != remoteId) {
      throw StateError('Uploaded resource could not be confirmed on the server');
    }
    final current = await _assertRawPairCurrent(asset, scope);
    final old = current.rawPairReceipt;
    final completed =
        old?.completed == true &&
        old?.serverEndpoint == scope.serverEndpoint &&
        old?.ownerId == scope.ownerId &&
        old?.pairKey == scope.pairKey &&
        old?.jpegId == ids.jpegId &&
        old?.rawId == ids.rawId;
    if (!await _localRepository.saveRawPairReceipt(
      asset.id,
      _rawPairReceipt(scope, current, ids, completed: completed),
    )) {
      throw StateError('Photo resources changed after upload');
    }
    await _remoteRepository.upsertUploadedResource(
      remoteId: remoteId,
      ownerId: scope.ownerId,
      source: asset,
      resource: role == PhotoResourceRole.raw ? asset.rawJpegPair!.rawOriginal : asset.rawJpegPair!.processed,
      checksum: role == PhotoResourceRole.raw ? asset.rawChecksum! : asset.checksum!,
    );
  }

  Future<void> finalizeRawJpegPair(
    LocalAsset asset, {
    required String jpegId,
    required String rawId,
    RawPairReceipt? expectedScope,
  }) async {
    final scope = expectedScope ?? await _localRepository.getRawPairScope(asset.rawJpegPair!.pairKey);
    final lockKey = [scope.serverEndpoint, scope.ownerId, asset.id].join('|');
    final previous = _rawPairFinalizations[lockKey];
    final done = Completer<void>();
    _rawPairFinalizations[lockKey] = done.future;
    await previous;
    try {
      var current = await _assertRawPairCurrent(asset, scope);
      final ids = await resolveRawPairRemoteIds(asset, expectedScope: scope);
      ids.requireNoTrash();
      if (jpegId == rawId || ids.jpegId != jpegId || ids.rawId != rawId) {
        throw StateError('Both original resources must exist before stacking');
      }
      final proof = await _storageRepository.getRawJpegPair(asset.id);
      if (proof?.pairKey != scope.pairKey) {
        await _localRepository.markRawPairDiscoveryUnknown(asset.id);
        throw StateError('Photos original resources changed before stacking');
      }
      current = await _assertRawPairCurrent(asset, scope);
      final old = current.rawPairReceipt;
      if (old?.completed == true &&
          old?.serverEndpoint == scope.serverEndpoint &&
          old?.ownerId == scope.ownerId &&
          old?.pairKey == scope.pairKey &&
          old?.jpegId == jpegId &&
          old?.rawId == rawId) {
        return;
      }
      if (!await _localRepository.saveRawPairReceipt(asset.id, _rawPairReceipt(scope, current, ids))) {
        throw StateError('Stale pair receipt');
      }
      final stack = await _apiRepository.stackWithoutMerging(jpegId, rawId);
      current = await _assertRawPairCurrent(asset, scope);
      await _remoteRepository.upsertUploadedResource(
        remoteId: jpegId,
        ownerId: scope.ownerId,
        source: asset,
        resource: proof!.processed,
        checksum: asset.checksum!,
      );
      await _remoteRepository.upsertUploadedResource(
        remoteId: rawId,
        ownerId: scope.ownerId,
        source: asset,
        resource: proof.rawOriginal,
        checksum: asset.rawChecksum!,
      );
      await _remoteRepository.stack(scope.ownerId, stack);
      if (!await _localRepository.saveRawPairReceipt(asset.id, _rawPairReceipt(scope, current, ids, completed: true))) {
        throw StateError('Stale pair completion');
      }
    } finally {
      done.complete();
      if (identical(_rawPairFinalizations[lockKey], done.future)) {
        unawaited(_rawPairFinalizations.remove(lockKey));
      }
    }
  }

  Future<BaseAsset?> getAsset(BaseAsset asset) {
    final id = asset is LocalAsset ? asset.id : (asset as RemoteAsset).id;
    return asset is LocalAsset ? _localRepository.get(id) : _remoteRepository.get(id);
  }

  Stream<BaseAsset?> watchAsset(BaseAsset asset) {
    final id = asset is LocalAsset ? asset.id : (asset as RemoteAsset).id;
    return asset is LocalAsset ? _localRepository.watch(id) : _remoteRepository.watch(id);
  }

  Future<List<LocalAsset?>> getLocalAssetsByChecksum(String checksum) {
    return _localRepository.getByChecksum(checksum);
  }

  Future<List<RemoteAsset>> getAllRemoteAssetDebugByChecksum(String checksum) {
    return _remoteRepository.getAllDebugForChecksum(checksum);
  }

  Future<RemoteAsset?> getRemoteAsset(String id) {
    return _remoteRepository.get(id);
  }

  Future<List<RemoteAsset>> getStack(RemoteAsset asset) async {
    if (asset.stackId == null) {
      return const [];
    }

    final stack = await _remoteRepository.getStackChildren(asset);
    // Include the primary asset in the stack as the first item
    return [asset, ...stack];
  }

  Stream<ExifInfo?> watchExif(BaseAsset asset) {
    if (!asset.hasRemote) {
      return Stream.value(null);
    }

    final id = asset is LocalAsset ? asset.remoteId! : (asset as RemoteAsset).id;
    return _remoteRepository.watchExif(id);
  }

  Future<List<(String, String)>> getPlaces(String userId) {
    return _remoteRepository.getPlaces(userId);
  }

  Future<(int local, int remote)> getAssetCounts() async {
    return (await _localRepository.getCount(), await _remoteRepository.getCount());
  }

  Future<int> getLocalHashedCount() {
    return _localRepository.getHashedCount();
  }

  Future<List<LocalAlbum>> getSourceAlbums(String localAssetId, {BackupSelection? backupSelection}) {
    return _localRepository.getSourceAlbums(localAssetId, backupSelection: backupSelection);
  }

  Future<void> restoreTrash(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.restoreTrash(remoteIds);
    await _remoteRepository.restoreTrash(remoteIds);
  }

  Future<void> stack(String userId, List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    final stack = await _apiRepository.stack(remoteIds);
    await _remoteRepository.stack(userId, stack);
  }

  Future<void> unstack(List<String> stackIds) async {
    if (stackIds.isEmpty) {
      return;
    }

    await _remoteRepository.unStack(stackIds);
    await _apiRepository.unStack(stackIds);
  }

  Future<void> update(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<LatLng> location = const .none(),
    Option<String> dateTime = const .none(),
  }) async {
    if (remoteIds.isEmpty) {
      return;
    }

    final parsedDateTime = dateTime.map((dt) => DateTime.parse(dt));
    final offset = RegExp(r'[+-]\d{2}:\d{2}$').firstMatch(dateTime.unwrapOrNull ?? '')?.group(0);

    await _apiRepository.update(
      remoteIds,
      isFavorite: isFavorite,
      visibility: visibility,
      location: location,
      dateTimeOriginal: dateTime,
    );
    await _remoteRepository.updateAssets(
      remoteIds,
      isFavorite: isFavorite,
      visibility: visibility,
      createdAt: parsedDateTime,
    );
    await _exifRepository.updateExif(
      remoteIds,
      location: location,
      dateTimeOriginal: parsedDateTime,
      timeZone: .fromNullable(offset).map((o) => 'UTC$o'),
    );
  }

  Future<void> trash(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.delete(remoteIds, false);
    await _remoteRepository.trash(remoteIds);
  }

  Future<void> delete(List<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return;
    }

    await _apiRepository.delete(remoteIds, true);
    await _remoteRepository.deleteAssets(remoteIds);
  }

  Future<void> applyEdits(String remoteId, List<AssetEdit> edits) async {
    if (edits.isEmpty) {
      await _apiRepository.removeEdits(remoteId);
    } else {
      await _apiRepository.editAsset(remoteId, edits);
    }
  }

  Future<int> deleteLocal(List<String> localIds, {bool trash = true}) async {
    if (localIds.isEmpty) {
      return 0;
    }

    final deletedIds = await _mediaRepository.deleteAll(localIds, trash: trash);
    if (deletedIds.isEmpty) {
      return 0;
    }

    if (trash && CurrentPlatform.isAndroid && Store.get(StoreKey.manageLocalMediaAndroid, false)) {
      await _trashedLocalRepository.applyTrashedAssets(deletedIds);
    } else {
      await _localRepository.deleteAssets(deletedIds);
    }
    return deletedIds.length;
  }

  Future<LocalAsset?> getLocalAsset(String id) {
    return _localRepository.get(id);
  }

  Future<List<Tag>> getTags(String assetId) {
    return _apiRepository.getAssetTags(assetId);
  }

  Future<void> stackEditedUpload(String localId, String remoteId, String? checksum) async {
    // a manual upload of an asset that was never hashed has no checksum yet, so we need to fetch it from the server
    final uploadedChecksum = checksum ?? await _apiRepository.getChecksum(remoteId);
    try {
      // previous_checksum still points at the version the server had before this upload
      final previousId = await _localRepository.getPreviousRemoteId(localId);
      if (previousId != null && previousId != remoteId) {
        await _apiRepository.stack([remoteId, previousId]);
      }
    } finally {
      // the upload went through even when the stack call did not, so this version is the new base
      await _localRepository.updatePreviousChecksum(localId, uploadedChecksum);
    }
  }
}
