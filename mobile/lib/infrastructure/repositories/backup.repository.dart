import 'dart:async';

import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/data/db/main/table/local/album_asset.drift.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/raw_pair_backup_predicate.dart';

@DriftAccessor()
class BackupRepository extends DatabaseAccessor<Drift> with $BackupRepositoryMixin {
  BackupRepository(super.attachedDatabase);

  Drift get _db => attachedDatabase;

  JoinedSelectStatement<$LocalAlbumAssetEntityTable, LocalAlbumAssetEntityData> _getExcludedSubquery() {
    return _db.localAlbumAssetEntity.selectOnly()
      ..addColumns([_db.localAlbumAssetEntity.assetId])
      ..join([
        innerJoin(
          _db.localAlbumEntity,
          _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
          useColumns: false,
        ),
      ])
      ..where(_db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.excluded));
  }

  /// Returns all backup-related counts in a single query.
  ///
  /// - total:     number of distinct assets in selected albums, excluding those that are also in excluded albums
  /// - backup:    number of those assets that already exist on the server for [userId]
  /// - remainder: number of those assets that do not yet exist on the server for [userId]
  ///              (includes processing)
  /// - processing: number of those assets that are still preparing/have a null checksum
  Future<({int total, int remainder, int processing})> getAllCounts(String userId) async {
    final local = _db.localAssetEntity;
    final complete =
        primaryBackupExists(_db, userId) & rawPairBackupComplete(_db, userId, await backupServerEndpoint(_db));
    final total = local.id.count();
    final remainder = local.id.count(filter: complete.not());
    final processing = local.id.count(filter: rawPairBackupProcessing(_db));
    final row =
        await (_db.selectOnly(local)
              ..addColumns([total, remainder, processing])
              ..where(_selectedAssets()))
            .getSingle();
    return (total: row.read(total) ?? 0, remainder: row.read(remainder) ?? 0, processing: row.read(processing) ?? 0);
  }

  Expression<bool> _selectedAssets() =>
      existsQuery(
        _db.localAlbumAssetEntity.selectOnly()
          ..addColumns([_db.localAlbumAssetEntity.assetId])
          ..join([
            innerJoin(
              _db.localAlbumEntity,
              _db.localAlbumAssetEntity.albumId.equalsExp(_db.localAlbumEntity.id),
              useColumns: false,
            ),
          ])
          ..where(
            _db.localAlbumAssetEntity.assetId.equalsExp(_db.localAssetEntity.id) &
                _db.localAlbumEntity.backupSelection.equalsValue(BackupSelection.selected),
          ),
      ) &
      _db.localAssetEntity.id.isNotInQuery(_getExcludedSubquery());

  Future<List<LocalAsset>> getCandidates(String userId, {bool onlyHashed = true}) async {
    final complete =
        primaryBackupExists(_db, userId) & rawPairBackupComplete(_db, userId, await backupServerEndpoint(_db));
    final query = _db.localAssetEntity.select()
      ..where((_) => _selectedAssets() & complete.not())
      ..orderBy([(localAsset) => OrderingTerm.desc(localAsset.createdAt)]);

    if (onlyHashed) {
      query.where((lae) => lae.checksum.isNotNull());
    }

    return query.map((localAsset) => localAsset.toDto()).get();
  }
}
