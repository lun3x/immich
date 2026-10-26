import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

final cleanupServiceProvider = Provider<CleanupService>((ref) {
  return CleanupService(
    ref.watch(driftProvider).localAssetRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
  );
});

class CleanupService {
  static final int _deleteBatchSize = CurrentPlatform.isAndroid ? 2000 : 10000;
  final LocalAssetRepository _localAssetRepository;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  const CleanupService(this._localAssetRepository, this._assetMediaRepository, this._assetService);

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) async {
    final unknown = await _localAssetRepository.getAssetsToInspectForCleanup(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
    for (final asset in unknown) {
      try {
        await _assetService.inspectRawJpegPair(asset);
      } catch (_) {
        /* Unknown evidence remains protected. */
      }
    }
    final candidates = await _localAssetRepository.getRemovalCandidates(
      userId,
      cutoffDate,
      keepMediaType: keepMediaType,
      keepFavorites: keepFavorites,
      keepAlbumIds: keepAlbumIds,
    );
    final safe = <LocalAsset>[];
    for (final asset in candidates.assets) {
      if (await _verifyForCleanup(asset)) {
        safe.add(asset);
      }
    }
    return RemovalCandidatesResult(
      assets: safe,
      totalBytes: safe.length == candidates.assets.length
          ? candidates.totalBytes
          : safe.fold<int>(0, (sum, asset) => sum + (candidates.assetBytes[asset.id] ?? 0)),
    );
  }

  Future<bool> _verifyForCleanup(LocalAsset asset) async {
    if (!CurrentPlatform.isIOS || asset.type != AssetType.image) {
      return true;
    }
    try {
      await _localAssetRepository.markRawPairDiscoveryUnknown(asset.id);
      final current = await _assetService.inspectRawJpegPair(asset);
      if (current.rawPairDiscovery == RawPairDiscovery.present) {
        final receipt = current.rawPairReceipt;
        if (receipt?.completed != true) {
          return false;
        }
        final ids = await _assetService.resolveRawPairRemoteIds(current);
        if (ids.jpegTrashed ||
            ids.rawTrashed ||
            ids.jpegId == null ||
            ids.rawId == null ||
            ids.jpegId != receipt?.jpegId ||
            ids.rawId != receipt?.rawId) {
          return false;
        }
      }
      return await _localAssetRepository.isBackupCompleteForCleanup(asset.id);
    } catch (_) {
      return false;
    }
  }

  Future<int> deleteLocalAssets(List<String> localIds) async {
    if (localIds.isEmpty) {
      return 0;
    }
    int deletedCount = 0;
    for (int index = 0; index < localIds.length; index += _deleteBatchSize) {
      final end = index + _deleteBatchSize < localIds.length ? index + _deleteBatchSize : localIds.length;
      final batch = <String>[];
      for (final id in localIds.sublist(index, end)) {
        if (!CurrentPlatform.isIOS) {
          batch.add(id);
          continue;
        }
        final asset = await _localAssetRepository.getById(id);
        if (asset != null && await _verifyForCleanup(asset)) {
          batch.add(id);
        }
      }
      if (batch.isEmpty) {
        continue;
      }
      final deletedIds = await _assetMediaRepository.deleteAll(batch);
      if (deletedIds.isNotEmpty) {
        await _localAssetRepository.deleteAssets(deletedIds);
        deletedCount += deletedIds.length;
      }
    }
    return deletedCount;
  }

  Set<String> getDefaultKeepAlbumIds(List<(String id, String name)> albums) {
    const messagingApps = ['whatsapp', 'telegram', 'signal', 'messenger', 'viber', 'wechat', 'line'];
    final toKeep = <String>{};
    for (final (id, name) in albums) {
      final albumName = name.toLowerCase();
      if (messagingApps.any((app) => albumName.contains(app))) {
        toKeep.add(id);
      }
    }
    return toKeep;
  }
}
