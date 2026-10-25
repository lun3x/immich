import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/utils/option.dart';

import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalAssetRepository assets;
  setUp(() async {
    ctx = MediumRepositoryContext();
    assets = LocalAssetRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.db.customStatement(
      "INSERT INTO store_entity (id, string_value) VALUES (2, 'owner'), (12, 'https://photos.example/api')",
    );
  });
  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    await ctx.dispose();
  });

  test('old primary checksum does not skip pair discovery', () async {
    final local = await ctx.newLocalAsset(checksum: 'old-jpeg');
    final album = await ctx.newLocalAlbum();
    await ctx.newLocalAlbumAsset(assetId: local.id, albumId: album.id);
    final candidates = await LocalAlbumRepository(ctx.db).getAssetsToDiscoverRawPairs(album.id);
    expect(candidates.map((a) => a.id), contains(local.id));
    await assets.saveRawPairDiscovery(local.id, null);
    expect(await LocalAlbumRepository(ctx.db).getAssetsToDiscoverRawPairs(album.id), isEmpty);
    expect((await assets.getById(local.id))!.checksum, 'old-jpeg');
  });

  test('first verified pair hashes exact resources instead of trusting legacy checksum', () async {
    final local = await ctx.newLocalAsset(checksum: 'legacy-unknown-resource');
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id));
    final actual = (await assets.getById(local.id))!;
    expect(actual.rawPairDiscovery, RawPairDiscovery.present);
    expect(actual.checksum, isNull);
    expect(actual.rawChecksum, isNull);
  });

  test('processed edit preserves raw hash and invalidates completed receipt', () async {
    final local = await ctx.newLocalAsset();
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id));
    await assets.saveRawPairHashes(local.id, 'revision-1', jpegChecksum: 'jpeg-hash', rawChecksum: 'raw-hash');
    await assets.saveRawPairReceipt(local.id, rawReceipt('revision-1', completed: true));
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id, pairKey: 'revision-2'));
    final actual = (await assets.getById(local.id))!;
    expect(actual.checksum, isNull);
    expect(actual.rawChecksum, 'raw-hash');
    expect(actual.rawPairReceipt?.completed ?? false, isFalse);
    expect(await assets.saveRawPairHashes(local.id, 'revision-1', rawChecksum: 'stale'), isFalse);
    expect(await assets.saveRawPairReceipt(local.id, rawReceipt('revision-1')), isFalse);
  });

  test('metadata-only rediscovery preserves completed receipt and both hashes', () async {
    final local = await ctx.newLocalAsset();
    final pair = rawPair(assetId: local.id);
    await assets.saveRawPairDiscovery(local.id, pair);
    await assets.saveRawPairHashes(local.id, pair.pairKey, jpegChecksum: 'jpeg', rawChecksum: 'raw');
    await assets.saveRawPairReceipt(local.id, rawReceipt(pair.pairKey, completed: true));
    await assets.markRawPairDiscoveryUnknown(local.id);
    await assets.saveRawPairDiscovery(local.id, pair);
    final actual = (await assets.getById(local.id))!;
    expect(actual.checksum, 'jpeg');
    expect(actual.rawChecksum, 'raw');
    expect(actual.rawPairReceipt!.completed, isTrue);
  });

  test('Photos metadata updates mark pair evidence unknown without discarding hashes', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    final row = await ctx.newLocalAsset();
    final pair = rawPair(assetId: row.id);
    await assets.saveRawPairDiscovery(row.id, pair);
    await assets.saveRawPairHashes(row.id, pair.pairKey, jpegChecksum: 'jpeg', rawChecksum: 'raw');
    final local = (await assets.getById(row.id))!;
    await LocalAlbumRepository(ctx.db).upsert(
      LocalAlbum(id: 'album', name: 'Camera', updatedAt: DateTime.now()),
      toUpsert: [local.copyWith(updatedAt: local.updatedAt.add(const Duration(seconds: 1)))],
    );
    final actual = (await assets.getById(row.id))!;
    expect(actual.rawPairDiscovery, RawPairDiscovery.unknown);
    expect(actual.rawChecksum, 'raw');
    expect(actual.checksum, 'jpeg');
  });

  test('receipt from a previous account or endpoint is rejected', () async {
    final local = await ctx.newLocalAsset();
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id));
    expect(
      await assets.saveRawPairReceipt(
        local.id,
        const RawPairReceipt(serverEndpoint: 'https://other/api', ownerId: 'owner', pairKey: 'revision-1'),
      ),
      isFalse,
    );
    expect(
      await assets.saveRawPairReceipt(
        local.id,
        const RawPairReceipt(serverEndpoint: 'https://photos.example/api', ownerId: 'other', pairKey: 'revision-1'),
      ),
      isFalse,
    );
  });

  test('cloud reconciliation cannot supply an exact pair resource hash', () async {
    final remote = await ctx.newRemoteAsset(ownerId: 'owner', checksum: 'cloud-hash');
    final cloud = await ctx.newRemoteAssetCloudId(id: remote.id);
    final local = await ctx.newLocalAsset(
      checksumOption: const Option.none(),
      iCloudId: cloud.cloudId,
      createdAt: cloud.createdAt,
      adjustmentTime: cloud.adjustmentTime,
      latitude: cloud.latitude,
      longitude: cloud.longitude,
    );
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id));
    await assets.reconcileHashesFromCloudId();
    expect((await assets.getById(local.id))!.checksum, isNull);
  });

  test('removed or replaced original clears its hash and receipt', () async {
    final local = await ctx.newLocalAsset();
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id));
    await assets.saveRawPairHashes(local.id, 'revision-1', jpegChecksum: 'jpeg', rawChecksum: 'raw');
    await assets.saveRawPairDiscovery(local.id, rawPair(assetId: local.id, pairKey: 'revision-2', rawKey: 'new-raw'));
    expect((await assets.getById(local.id))!.rawChecksum, isNull);
    await assets.saveRawPairHashes(local.id, 'revision-2', jpegChecksum: 'jpeg2', rawChecksum: 'raw2');
    await assets.saveRawPairDiscovery(local.id, null);
    final actual = (await assets.getById(local.id))!;
    expect(actual.rawPairDiscovery, RawPairDiscovery.absent);
    expect(actual.rawJpegPair, isNull);
    expect(actual.rawChecksum, isNull);
    expect(actual.checksum, isNull);
    expect(actual.rawPairReceipt, isNull);
  });
}
