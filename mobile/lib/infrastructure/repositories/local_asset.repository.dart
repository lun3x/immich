import 'dart:async';
import 'dart:convert';

import 'package:collection/collection.dart';
import 'package:drift/drift.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.drift.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.drift.dart';

class RemovalCandidatesResult {
  final List<LocalAsset> assets;
  final int totalBytes;

  const RemovalCandidatesResult({required this.assets, required this.totalBytes});
}

@DriftAccessor()
class LocalAssetRepository extends DatabaseAccessor<Drift> with $LocalAssetRepositoryMixin {
  LocalAssetRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  SingleOrNullSelectable<LocalAsset?> _assetSelectable(String id) {
    final query =
        _db.localAssetEntity.select().addColumns([_db.remoteAssetEntity.id]).join([
            leftOuterJoin(
              _db.remoteAssetEntity,
              _db.localAssetEntity.checksum.equalsExp(_db.remoteAssetEntity.checksum) &
                  _db.remoteAssetEntity.ownerId.isInQuery(
                    _db.selectOnly(_db.authUserEntity)
                      ..addColumns([_db.authUserEntity.id])
                      ..limit(1),
                  ),
              useColumns: false,
            ),
          ])
          ..where(_db.localAssetEntity.id.equals(id))
          ..limit(1);

    return query.map((row) {
      final asset = row.readTable(_db.localAssetEntity).toDto();
      return asset.copyWith(remoteId: row.read(_db.remoteAssetEntity.id));
    });
  }

  Future<LocalAsset?> get(String id) => _assetSelectable(id).getSingleOrNull();

  Future<List<LocalAsset?>> getByChecksum(String checksum) {
    final query = _db.localAssetEntity.select()..where((lae) => lae.checksum.equals(checksum));

    return query.map((row) => row.toDto()).get();
  }

  Stream<LocalAsset?> watch(String id) => _assetSelectable(id).watchSingleOrNull();

  Future<void> saveRawPairDiscovery(String localId, RawJpegPair? pair) => _db.transaction(() async {
    if (pair != null && pair.assetId != localId) {
      throw StateError('Photo resource parent mismatch');
    }
    final previous = await getById(localId);
    if (previous == null) {
      return;
    }
    final old = previous.rawJpegPair;
    final changed = old?.pairKey != pair?.pairKey;
    await (_db.localAssetEntity.update()..where((e) => e.id.equals(localId))).write(
      LocalAssetEntityCompanion(
        rawPairState: Value(pair == null ? RawPairDiscovery.absent : RawPairDiscovery.present),
        rawPair: Value(pair == null ? null : jsonEncode(pair.toMap())),
        checksum: changed ? const Value(null) : const Value.absent(),
        rawChecksum: changed && old?.rawOriginal.key != pair?.rawOriginal.key
            ? const Value(null)
            : const Value.absent(),
      ),
    );
    if (changed) {
      await clearRawPairReceipt(localId);
    }
  });

  Future<void> markRawPairDiscoveryUnknown(String localId) async {
    await (_db.localAssetEntity.update()..where((e) => e.id.equals(localId))).write(
      const LocalAssetEntityCompanion(rawPairState: Value(RawPairDiscovery.unknown)),
    );
  }

  Future<bool> saveRawPairHashes(String localId, String pairKey, {String? jpegChecksum, String? rawChecksum}) =>
      _db.transaction(() async {
        final asset = await getById(localId);
        if (asset?.rawJpegPair?.pairKey != pairKey || asset?.rawPairDiscovery != RawPairDiscovery.present) {
          return false;
        }
        await (_db.localAssetEntity.update()..where((e) => e.id.equals(localId))).write(
          LocalAssetEntityCompanion(
            checksum: jpegChecksum == null ? const Value.absent() : Value(jpegChecksum),
            rawChecksum: rawChecksum == null ? const Value.absent() : Value(rawChecksum),
          ),
        );
        return true;
      });

  Future<RawPairReceipt> getRawPairScope(String pairKey) async {
    final stored =
        await (_db.storeEntity.select()..where((e) => e.id.isIn([StoreKey.currentUser.id, StoreKey.serverEndpoint.id])))
            .get();
    final owner = stored.where((e) => e.id == StoreKey.currentUser.id).firstOrNull?.stringValue;
    final endpoint = stored.where((e) => e.id == StoreKey.serverEndpoint.id).firstOrNull?.stringValue;
    if (owner == null || endpoint == null) {
      throw StateError('No active backup account');
    }
    return RawPairReceipt(serverEndpoint: endpoint, ownerId: owner, pairKey: pairKey);
  }

  Future<bool> isRawPairScopeCurrent(RawPairReceipt scope) async {
    final stored =
        await (_db.storeEntity.select()..where((e) => e.id.isIn([StoreKey.currentUser.id, StoreKey.serverEndpoint.id])))
            .get();
    return stored.any((e) => e.id == StoreKey.currentUser.id && e.stringValue == scope.ownerId) &&
        stored.any((e) => e.id == StoreKey.serverEndpoint.id && e.stringValue == scope.serverEndpoint);
  }

  Future<bool> saveRawPairReceipt(String localId, RawPairReceipt receipt) => _db.transaction(() async {
    if (!await isRawPairScopeCurrent(receipt)) {
      return false;
    }
    final asset = await getById(localId);
    if (asset?.rawPairDiscovery != RawPairDiscovery.present || asset?.rawJpegPair?.pairKey != receipt.pairKey) {
      return false;
    }
    await (_db.localAssetEntity.update()..where((e) => e.id.equals(localId))).write(
      LocalAssetEntityCompanion(
        rawReceiptServer: Value(receipt.serverEndpoint),
        rawReceiptUserId: Value(receipt.ownerId),
        rawReceiptPairKey: Value(receipt.pairKey),
        rawReceiptRawId: Value(receipt.rawId),
        rawReceiptJpegId: Value(receipt.jpegId),
        rawReceiptRawTaskId: Value(receipt.rawTaskId),
        rawReceiptJpegTaskId: Value(receipt.jpegTaskId),
        rawPairCompleted: Value(receipt.completed),
      ),
    );
    return true;
  });

  Future<void> clearRawPairReceipt(String localId) async {
    await (_db.localAssetEntity.update()..where((e) => e.id.equals(localId))).write(
      const LocalAssetEntityCompanion(
        rawReceiptServer: Value(null),
        rawReceiptUserId: Value(null),
        rawReceiptPairKey: Value(null),
        rawReceiptRawId: Value(null),
        rawReceiptJpegId: Value(null),
        rawReceiptRawTaskId: Value(null),
        rawReceiptJpegTaskId: Value(null),
        rawPairCompleted: Value(false),
      ),
    );
  }

  Future<void> updateHashes(Map<String, String> hashes) {
    if (hashes.isEmpty) {
      return Future.value();
    }

    return _db.batch((batch) async {
      for (final entry in hashes.entries) {
        batch.update(
          _db.localAssetEntity,
          LocalAssetEntityCompanion(checksum: Value(entry.value)),
          where: (e) => e.id.equals(entry.key),
        );
      }
    });
  }

  Future<void> deleteAssets(List<String> ids) {
    if (ids.isEmpty) {
      return Future.value();
    }

    return _db.batch((batch) {
      for (final id in ids) {
        batch.deleteWhere(_db.localAssetEntity, (e) => e.id.equals(id));
      }
    });
  }

  Future<LocalAsset?> getById(String id) {
    final query = _db.localAssetEntity.select()..where((lae) => lae.id.equals(id));

    return query.map((row) => row.toDto()).getSingleOrNull();
  }

  Future<int> getCount() {
    return _db.managers.localAssetEntity.count();
  }

  Future<int> getHashedCount() {
    return _db.managers.localAssetEntity.filter((e) => e.checksum.isNull().not()).count();
  }

  Future<List<LocalAlbum>> getSourceAlbums(String localAssetId, {BackupSelection? backupSelection}) {
    final query = _db.localAlbumEntity.select()
      ..where(
        (lae) => existsQuery(
          _db.localAlbumAssetEntity.selectOnly()
            ..addColumns([_db.localAlbumAssetEntity.albumId])
            ..where(
              _db.localAlbumAssetEntity.albumId.equalsExp(lae.id) &
                  _db.localAlbumAssetEntity.assetId.equals(localAssetId),
            ),
        ),
      )
      ..orderBy([(lae) => OrderingTerm.asc(lae.name)]);
    if (backupSelection != null) {
      query.where((lae) => lae.backupSelection.equalsValue(backupSelection));
    }
    return query.map((localAlbum) => localAlbum.toDto()).get();
  }

  Future<Map<String, List<LocalAsset>>> getAssetsFromBackupAlbums(Iterable<String> remoteIds) async {
    if (remoteIds.isEmpty) {
      return {};
    }

    final result = <String, List<LocalAsset>>{};

    for (final slice in remoteIds.toSet().slices(kDriftMaxChunk)) {
      final rows =
          await (_db.select(_db.localAlbumAssetEntity).join([
                innerJoin(
                  _db.localAlbumEntity,
                  _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
                  useColumns: false,
                ),
                innerJoin(_db.localAssetEntity, _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id)),
                innerJoin(
                  _db.remoteAssetEntity,
                  _db.localAssetEntity.checksum.equalsExp(_db.remoteAssetEntity.checksum),
                  useColumns: false,
                ),
              ])..where(
                _db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected) &
                    _db.remoteAssetEntity.id.isIn(slice),
              ))
              .get();

      for (final row in rows) {
        final albumId = row.readTable(_db.localAlbumAssetEntity).albumId;
        final asset = row.readTable(_db.localAssetEntity).toDto();
        (result[albumId] ??= <LocalAsset>[]).add(asset);
      }
    }

    return result;
  }

  Future<RemovalCandidatesResult> getRemovalCandidates(
    String userId,
    DateTime cutoffDate, {
    AssetKeepType keepMediaType = AssetKeepType.none,
    bool keepFavorites = true,
    Set<String> keepAlbumIds = const {},
  }) async {
    final iosSharedAlbumAssets = _db.localAlbumAssetEntity.selectOnly()
      ..addColumns([_db.localAlbumAssetEntity.assetId])
      ..join([
        innerJoin(
          _db.localAlbumEntity,
          _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
          useColumns: false,
        ),
      ])
      ..where(_db.localAlbumEntity.isIosSharedAlbum.equals(true));

    final query = _db.localAssetEntity.select().join([
      innerJoin(_db.remoteAssetEntity, _db.localAssetEntity.checksum.equalsExp(_db.remoteAssetEntity.checksum)),
      leftOuterJoin(_db.remoteExifEntity, _db.remoteAssetEntity.id.equalsExp(_db.remoteExifEntity.assetId)),
    ]);

    Expression<bool> whereClause =
        _db.localAssetEntity.createdAt.isSmallerOrEqualValue(cutoffDate) &
        _db.remoteAssetEntity.ownerId.equals(userId) &
        _db.remoteAssetEntity.deletedAt.isNull();

    // Exclude assets that are in iOS shared albums
    whereClause = whereClause & _db.localAssetEntity.id.isNotInQuery(iosSharedAlbumAssets);

    if (keepAlbumIds.isNotEmpty) {
      final keepAlbumAssets = _db.localAlbumAssetEntity.selectOnly()
        ..addColumns([_db.localAlbumAssetEntity.assetId])
        ..where(_db.localAlbumAssetEntity.albumId.isIn(keepAlbumIds));
      whereClause = whereClause & _db.localAssetEntity.id.isNotInQuery(keepAlbumAssets);
    }

    if (keepMediaType == AssetKeepType.photosOnly) {
      // Keep photos = delete only videos
      whereClause = whereClause & _db.localAssetEntity.type.equalsValue(AssetType.video);
    } else if (keepMediaType == AssetKeepType.videosOnly) {
      // Keep videos = delete only photos
      whereClause = whereClause & _db.localAssetEntity.type.equalsValue(AssetType.image);
    }

    if (keepFavorites) {
      whereClause =
          whereClause & _db.localAssetEntity.isFavorite.equals(false) & _db.remoteAssetEntity.isFavorite.equals(false);
    }

    query.where(whereClause);

    final rows = await query.get();
    final assets = rows.map((row) => row.readTable(_db.localAssetEntity).toDto()).toList();
    final totalBytes = rows.fold<int>(0, (sum, row) {
      final fileSize = row.readTableOrNull(_db.remoteExifEntity)?.fileSize;
      return sum + (fileSize ?? 0);
    });

    return RemovalCandidatesResult(assets: assets, totalBytes: totalBytes);
  }

  Future<void> reconcileHashesFromCloudId() async {
    await _db.customUpdate(
      '''
      UPDATE local_asset_entity
      SET checksum = remote_asset_entity.checksum
      FROM remote_asset_cloud_id_entity
      INNER JOIN remote_asset_entity
        ON remote_asset_cloud_id_entity.asset_id = remote_asset_entity.id
      WHERE local_asset_entity.i_cloud_id = remote_asset_cloud_id_entity.cloud_id
        AND local_asset_entity.checksum IS NULL
        AND local_asset_entity.raw_pair IS NULL
        AND remote_asset_cloud_id_entity.adjustment_time IS local_asset_entity.adjustment_time
        AND remote_asset_cloud_id_entity.latitude IS local_asset_entity.latitude
        AND remote_asset_cloud_id_entity.longitude IS local_asset_entity.longitude
        AND remote_asset_cloud_id_entity.created_at IS local_asset_entity.created_at
      ''',
      updates: {_db.localAssetEntity},
      updateKind: UpdateKind.update,
    );
  }

  Future<String?> getPreviousRemoteId(String id) {
    final query = _db.selectOnly(_db.localAssetEntity)
      ..join([
        innerJoin(
          _db.remoteAssetEntity,
          _db.remoteAssetEntity.checksum.equalsExp(_db.localAssetEntity.previousChecksum),
        ),
        innerJoin(_db.authUserEntity, _db.authUserEntity.id.equalsExp(_db.remoteAssetEntity.ownerId)),
      ])
      ..addColumns([_db.remoteAssetEntity.id])
      ..where(_db.localAssetEntity.id.equals(id))
      ..limit(1);

    return query.map((row) => row.read(_db.remoteAssetEntity.id)).getSingleOrNull();
  }

  Future<void> updatePreviousChecksum(String id, String checksum) async {
    final query = _db.localAssetEntity.update()..where((row) => row.id.equals(id));
    await query.write(LocalAssetEntityCompanion(previousChecksum: Value(checksum)));
  }
}
