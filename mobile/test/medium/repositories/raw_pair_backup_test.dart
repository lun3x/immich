import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_album.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/sync_stream.repository.dart';
import 'package:immich_mobile/services/cleanup.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart' as api;
import 'package:openapi/api.dart' show SyncAssetDeleteV1;

import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/mocks.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalAssetRepository assets;
  late BackupRepository backup;
  late LocalAsset local;
  late MockStorageRepository storage;
  late RepositoryMocks mocks;
  late CleanupService cleanup;
  final cutoff = DateTime(2028);
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    ctx = MediumRepositoryContext();
    assets = LocalAssetRepository(ctx.db);
    backup = BackupRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.db.customStatement(
      "INSERT INTO store_entity (id, string_value) VALUES (2, 'owner'), (12, 'https://photos.example/api')",
    );
    final row = await ctx.newLocalAsset(createdAt: DateTime(2025));
    final album = await ctx.newLocalAlbum(backupSelection: BackupSelection.selected);
    await ctx.newLocalAlbumAsset(assetId: row.id, albumId: album.id);
    await assets.saveRawPairDiscovery(row.id, rawPair(assetId: row.id));
    await assets.saveRawPairHashes(row.id, 'revision-1', jpegChecksum: 'jpeg-hash');
    await ctx.newRemoteAsset(id: 'remote-jpeg', ownerId: 'owner', checksum: 'jpeg-hash');
    local = (await assets.getById(row.id))!;
    storage = MockStorageRepository();
    mocks = RepositoryMocks();
    when(() => storage.getRawJpegPair(local.id)).thenAnswer((_) async => local.rawJpegPair);
    final service = AssetService(
      remoteRepository: RemoteAssetRepository(ctx.db),
      exifRepository: mocks.remoteExif.repo,
      localRepository: assets,
      apiRepository: mocks.assetApi.api,
      mediaRepository: mocks.assetMedia.api,
      trashedLocalRepository: mocks.trashedAsset,
      storageRepository: storage,
    );
    cleanup = CleanupService(assets, mocks.assetMedia.api, service);
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {
        'jpeg': (assetId: 'remote-jpeg', isTrashed: false),
        'raw': (assetId: 'remote-raw', isTrashed: false),
      },
    );
    when(
      () => mocks.assetMedia.api.deleteAll(any()),
    ).thenAnswer((i) async => i.positionalArguments.single as List<String>);
  });
  tearDown(() async {
    await ctx.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  Future<void> complete() async {
    await assets.saveRawPairHashes(local.id, 'revision-1', rawChecksum: 'raw-hash');
    await ctx.newRemoteAsset(id: 'remote-raw', ownerId: 'owner', checksum: 'raw-hash');
    await assets.saveRawPairReceipt(local.id, rawReceipt('revision-1', completed: true));
  }

  test('JPEG-only pair remains pending and processing until RAW is hashed', () async {
    expect((await backup.getCandidates('owner')).map((a) => a.id), contains(local.id));
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 1));
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
    await assets.saveRawPairHashes(local.id, 'revision-1', rawChecksum: 'raw-hash');
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
    await ctx.newRemoteAsset(id: 'remote-raw', ownerId: 'owner', checksum: 'raw-hash');
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
  });
  test('excluded membership prevents automatic pair discovery even through a selected album', () async {
    await assets.markRawPairDiscoveryUnknown(local.id);
    final excluded = await ctx.newLocalAlbum(backupSelection: BackupSelection.excluded);
    await ctx.newLocalAlbumAsset(albumId: excluded.id, assetId: local.id);
    final selected = await ctx.db
        .customSelect(
          'SELECT album_id FROM local_album_asset_entity WHERE asset_id = ? AND album_id != ?',
          variables: [Variable.withString(local.id), Variable.withString(excluded.id)],
        )
        .getSingle();
    expect(await LocalAlbumRepository(ctx.db).getAssetsToDiscoverRawPairs(selected.read<String>('album_id')), isEmpty);
    expect((await backup.getAllCounts('owner')).total, 0);
  });

  test('completed pair counts once and stays complete after manual unstack', () async {
    await complete();
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 0, processing: 0));
    expect(await backup.getCandidates('owner'), isEmpty);
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets.map((a) => a.id), [local.id]);
  });
  test('deletion invalidates completion and reset retains the invalidated receipt', () async {
    await complete();
    await SyncStreamRepository(ctx.db).deleteAssetsV1([SyncAssetDeleteV1(assetId: 'remote-raw')]);
    final receipt = (await assets.getById(local.id))!.rawPairReceipt!;
    expect(receipt.rawId, isNull);
    expect(receipt.jpegId, 'remote-jpeg');
    expect(receipt.completed, isFalse);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 0));
    await SyncStreamRepository(ctx.db).reset();
    expect((await assets.getById(local.id))!.rawPairReceipt, receipt);
  });
  test('reset retains completion history but requires remote presence for backup and cleanup', () async {
    await complete();
    await SyncStreamRepository(ctx.db).reset();
    expect((await assets.getById(local.id))!.rawPairReceipt!.completed, isTrue);
    expect((await backup.getAllCounts('owner')).remainder, 1);
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.newRemoteAsset(id: 'remote-jpeg', ownerId: 'owner', checksum: 'jpeg-hash');
    await ctx.newRemoteAsset(id: 'remote-raw', ownerId: 'owner', checksum: 'raw-hash');
    expect((await backup.getAllCounts('owner')).remainder, 0);
  });
  test('authoritative trash update invalidates RAW receipt and cleanup', () async {
    await complete();
    await SyncStreamRepository(ctx.db).updateAssetsV2([
      api.SyncAssetV2(
        id: 'remote-raw',
        checksum: 'raw-hash',
        originalFileName: 'IMG.RAF',
        type: api.AssetTypeEnum.IMAGE,
        ownerId: 'owner',
        createdAt: DateTime(2025),
        deletedAt: DateTime(2026),
        duration: null,
        fileCreatedAt: DateTime(2025),
        fileModifiedAt: DateTime(2025),
        height: null,
        width: null,
        isEdited: false,
        isFavorite: false,
        libraryId: null,
        livePhotoVideoId: null,
        localDateTime: null,
        stackId: null,
        thumbhash: null,
        visibility: api.AssetVisibility.timeline,
      ),
    ]);
    expect((await assets.getById(local.id))!.rawPairReceipt!.completed, isFalse);
    expect((await assets.getById(local.id))!.rawPairReceipt!.rawId, isNull);
    expect((await backup.getAllCounts('owner')).remainder, 1);
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
  });

  test('stale endpoint receipt and unknown discovery cannot establish completion', () async {
    await complete();
    await ctx.db.customStatement("UPDATE store_entity SET string_value = 'https://other/api' WHERE id = 12");
    expect((await backup.getAllCounts('owner')).remainder, 1);
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
    await assets.markRawPairDiscoveryUnknown(local.id);
    expect((await backup.getAllCounts('owner')).processing, 1);
  });
  test('another owners RAW does not complete the pair', () async {
    await ctx.newUser(id: 'other');
    await assets.saveRawPairHashes(local.id, 'revision-1', rawChecksum: 'raw-hash');
    await ctx.newRemoteAsset(id: 'remote-raw', ownerId: 'other', checksum: 'raw-hash');
    await assets.saveRawPairReceipt(local.id, rawReceipt('revision-1', completed: true));
    expect((await backup.getAllCounts('owner')).remainder, 1);
    expect((await assets.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
  });

  test('cleanup can inspect an unknown ordinary photo without downloading resources', () async {
    await assets.saveRawPairDiscovery(local.id, null);
    await assets.updateHashes({local.id: 'jpeg-hash'});
    await assets.markRawPairDiscoveryUnknown(local.id);
    when(() => storage.getRawJpegPair(local.id)).thenAnswer((_) async => null);
    expect((await cleanup.getRemovalCandidates('owner', cutoff)).assets.map((a) => a.id), [local.id]);
    verifyNever(() => storage.hashPhotoResources(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
  });

  test('cleanup refuses fresh missing or trashed RAW and network errors', () async {
    await complete();
    for (final trashed in [false, true]) {
      when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
        (_) async => {
          'jpeg': (assetId: 'remote-jpeg', isTrashed: false),
          'raw': (assetId: trashed ? 'remote-raw' : null, isTrashed: trashed),
        },
      );
      expect((await cleanup.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
    }
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenThrow(StateError('offline'));
    expect((await cleanup.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
  });
  test('cleanup reports bytes for the safe subset when a pair cannot be verified', () async {
    await complete();
    final ordinary = await ctx.newLocalAsset(checksum: 'ordinary', createdAt: DateTime(2025));
    await ctx.newRemoteAsset(id: 'ordinary-remote', ownerId: 'owner', checksum: 'ordinary');
    await ctx.db.customStatement(
      "INSERT INTO remote_exif_entity (asset_id, file_size) VALUES ('ordinary-remote', 987)",
    );
    when(() => storage.getRawJpegPair(ordinary.id)).thenAnswer((_) async => null);
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenThrow(StateError('offline'));
    final result = await cleanup.getRemovalCandidates('owner', cutoff);
    expect(result.assets.map((a) => a.id), [ordinary.id]);
    expect(result.totalBytes, 987);
  });

  test('cleanup selection becomes stale before delete', () async {
    await complete();
    expect((await cleanup.getRemovalCandidates('owner', cutoff)).assets, hasLength(1));
    when(
      () => storage.getRawJpegPair(local.id),
    ).thenAnswer((_) async => rawPair(assetId: local.id, pairKey: 'new-revision'));
    expect(await cleanup.deleteLocalAssets([local.id]), 0);
    verifyNever(() => mocks.assetMedia.api.deleteAll(any()));
  });
  test('cleanup metadata discovery protects old uninspected JPEG-only backups without hashing RAW', () async {
    await assets.markRawPairDiscoveryUnknown(local.id);
    expect((await cleanup.getRemovalCandidates('owner', cutoff)).assets, isEmpty);
    verifyNever(() => storage.hashPhotoResources(any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
  });
}
