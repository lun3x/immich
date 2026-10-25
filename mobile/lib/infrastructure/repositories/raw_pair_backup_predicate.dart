import 'package:drift/drift.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';

Future<String> backupServerEndpoint(Drift db) async =>
    (await (db.storeEntity.select()..where((e) => e.id.equals(StoreKey.serverEndpoint.id))).getSingleOrNull())
        ?.stringValue ??
    '';

Expression<bool> primaryBackupExists(Drift db, String userId) => existsQuery(
  db.remoteAssetEntity.selectOnly()
    ..addColumns([db.remoteAssetEntity.id])
    ..where(
      db.remoteAssetEntity.ownerId.equals(userId) &
          db.remoteAssetEntity.deletedAt.isNull() &
          db.remoteAssetEntity.checksum.equalsExp(db.localAssetEntity.checksum),
    ),
);

/// The companion requirement for the same local item. Ordinary assets have no companion requirement.
Expression<bool> rawPairBackupComplete(Drift db, String userId, String serverEndpoint) {
  if (!CurrentPlatform.isIOS) {
    return const Constant(true);
  }
  final local = db.localAssetEntity;
  final remote = db.remoteAssetEntity;
  Expression<bool> resourceExists(Expression<String> hash, Expression<String> id) => existsQuery(
    remote.selectOnly()
      ..addColumns([remote.id])
      ..where(
        remote.checksum.equalsExp(hash) &
            remote.id.equalsExp(id) &
            remote.ownerId.equals(userId) &
            remote.deletedAt.isNull(),
      ),
  );
  return local.type.equalsValue(AssetType.image).not() |
      local.rawPairState.equalsValue(RawPairDiscovery.absent) |
      (local.rawPairState.equalsValue(RawPairDiscovery.present) &
          local.rawPair.isNotNull() &
          local.checksum.isNotNull() &
          local.rawChecksum.isNotNull() &
          local.rawPairCompleted.equals(true) &
          local.rawReceiptServer.equals(serverEndpoint) &
          local.rawReceiptUserId.equals(userId) &
          local.rawReceiptPairKey.equalsExp(
            const CustomExpression<String>("json_extract(local_asset_entity.raw_pair, '\$.pairKey')"),
          ) &
          resourceExists(local.checksum, local.rawReceiptJpegId) &
          resourceExists(local.rawChecksum, local.rawReceiptRawId));
}

Expression<bool> rawPairBackupProcessing(Drift db) {
  final local = db.localAssetEntity;
  return local.checksum.isNull() |
      (CurrentPlatform.isIOS
          ? local.type.equalsValue(AssetType.image) &
                (local.rawPairState.equalsValue(RawPairDiscovery.unknown) |
                    (local.rawPairState.equalsValue(RawPairDiscovery.present) & local.rawChecksum.isNull()))
          : const Constant(false));
}
