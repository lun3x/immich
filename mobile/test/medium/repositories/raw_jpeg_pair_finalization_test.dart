import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/mocks.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalAssetRepository local;
  late RemoteAssetRepository remote;
  late MockStorageRepository storage;
  late RepositoryMocks mocks;
  late AssetService sut;
  late LocalAsset asset;
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    ctx = MediumRepositoryContext();
    local = LocalAssetRepository(ctx.db);
    remote = RemoteAssetRepository(ctx.db);
    await ctx.newUser(id: 'owner');
    await ctx.newAuthUser(id: 'owner');
    await ctx.db.customStatement(
      "INSERT INTO store_entity (id, string_value) VALUES (2, 'owner'), (12, 'https://photos.example/api')",
    );
    final row = await ctx.newLocalAsset();
    await local.saveRawPairDiscovery(row.id, rawPair(assetId: row.id));
    await local.saveRawPairHashes(row.id, 'revision-1', jpegChecksum: 'jpeg-hash', rawChecksum: 'raw-hash');
    asset = (await local.getById(row.id))!;
    storage = MockStorageRepository();
    mocks = RepositoryMocks();
    sut = AssetService(
      remoteRepository: remote,
      exifRepository: mocks.remoteExif.repo,
      localRepository: local,
      apiRepository: mocks.assetApi.api,
      mediaRepository: mocks.assetMedia.api,
      trashedLocalRepository: mocks.trashedAsset,
      storageRepository: storage,
    );
    when(() => storage.getRawJpegPair(asset.id)).thenAnswer((_) async => asset.rawJpegPair);
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {'jpeg': (assetId: 'jpeg-id', isTrashed: false), 'raw': (assetId: 'raw-id', isTrashed: false)},
    );
    when(() => mocks.assetApi.api.stackWithoutMerging('jpeg-id', 'raw-id')).thenAnswer(
      (_) async => const StackResponse(id: 'stack', primaryAssetId: 'jpeg-id', assetIds: ['jpeg-id', 'raw-id']),
    );
  });
  tearDown(() async {
    await ctx.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('old JPEG is reused while missing RAW stays pending', () async {
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {'jpeg': (assetId: 'jpeg-id', isTrashed: false), 'raw': (assetId: null, isTrashed: false)},
    );
    final ids = await sut.resolveRawPairRemoteIds(asset);
    expect(ids.jpegId, 'jpeg-id');
    expect(ids.rawId, isNull);
  });
  test('fresh missing RAW invalidates a completed receipt for retry', () async {
    await local.saveRawPairReceipt(
      asset.id,
      const RawPairReceipt(
        serverEndpoint: 'https://photos.example/api',
        ownerId: 'owner',
        pairKey: 'revision-1',
        rawId: 'raw-id',
        jpegId: 'jpeg-id',
        completed: true,
      ),
    );
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {'jpeg': (assetId: 'jpeg-id', isTrashed: false), 'raw': (assetId: null, isTrashed: false)},
    );
    await sut.resolveRawPairRemoteIds(asset);
    final receipt = (await local.getById(asset.id))!.rawPairReceipt!;
    expect(receipt.completed, isFalse);
    expect(receipt.rawId, isNull);
    expect(receipt.jpegId, 'jpeg-id');
  });

  test('trashed RAW is not reusable presence', () async {
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {'jpeg': (assetId: 'jpeg-id', isTrashed: false), 'raw': (assetId: 'raw-id', isTrashed: true)},
    );
    final ids = await sut.resolveRawPairRemoteIds(asset);
    expect(ids.rawId, isNull);
    expect(ids.rawTrashed, isTrue);
    await expectLater(sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'), throwsStateError);
    verifyNever(() => mocks.assetApi.api.stackWithoutMerging(any(), any()));
  });
  test('successful upload persists receipt and inserts a visible sync stub without overwriting trash', () async {
    await sut.recordRawPairUpload(asset, role: PhotoResourceRole.raw, remoteId: 'raw-id');
    expect((await local.getById(asset.id))!.rawPairReceipt!.rawId, 'raw-id');
    expect((await remote.get('raw-id'))!.visibility, AssetVisibility.timeline);
    await ctx.db.customStatement(
      "UPDATE remote_asset_entity SET deleted_at = '2026-01-01T00:00:00.000Z' WHERE id = 'raw-id'",
    );
    await sut.recordRawPairUpload(asset, role: PhotoResourceRole.raw, remoteId: 'raw-id');
    expect((await remote.get('raw-id'))!.deletedAt, isNotNull);
  });
  test('failed stack retains both uploaded IDs without marking complete', () async {
    when(() => mocks.assetApi.api.stackWithoutMerging(any(), any())).thenThrow(StateError('conflict'));
    await expectLater(sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'), throwsStateError);
    final receipt = (await local.getById(asset.id))!.rawPairReceipt!;
    expect(receipt.rawId, 'raw-id');
    expect(receipt.jpegId, 'jpeg-id');
    expect(receipt.completed, isFalse);
  });
  test('completed pair is not automatically restacked after manual unstack', () async {
    await sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id');
    await remote.unStack(['stack']);
    await sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id');
    verify(() => mocks.assetApi.api.stackWithoutMerging('jpeg-id', 'raw-id')).called(1);
    verifyNever(() => mocks.assetApi.api.stack(any()));
  });
  test('concurrent finalizers make one automatic stack request', () async {
    await Future.wait([
      sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'),
      sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'),
    ]);
    verify(() => mocks.assetApi.api.stackWithoutMerging('jpeg-id', 'raw-id')).called(1);
  });
  test('identical remote IDs never create a pair stack', () async {
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer(
      (_) async => {'jpeg': (assetId: 'same', isTrashed: false), 'raw': (assetId: 'same', isTrashed: false)},
    );
    await expectLater(sut.finalizeRawJpegPair(asset, jpegId: 'same', rawId: 'same'), throwsStateError);
    verifyNever(() => mocks.assetApi.api.stackWithoutMerging(any(), any()));
  });

  test('fresh native evidence rejects a changed Photos item', () async {
    when(
      () => storage.getRawJpegPair(asset.id),
    ).thenAnswer((_) async => rawPair(assetId: asset.id, pairKey: 'new-revision'));
    await expectLater(sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'), throwsStateError);
    verifyNever(() => mocks.assetApi.api.stackWithoutMerging(any(), any()));
  });
  test('changed endpoint while checking presence rejects stale results', () async {
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer((_) async {
      await ctx.db.customStatement("UPDATE store_entity SET string_value = 'https://other/api' WHERE id = 12");
      return {'jpeg': (assetId: 'jpeg-id', isTrashed: false), 'raw': (assetId: 'raw-id', isTrashed: false)};
    });
    await expectLater(sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id'), throwsStateError);
    verifyNever(() => mocks.assetApi.api.stackWithoutMerging(any(), any()));
  });
  test('common existing stack preserves server primary and other members', () async {
    when(() => mocks.assetApi.api.stackWithoutMerging(any(), any())).thenAnswer(
      (_) async =>
          const StackResponse(id: 'existing', primaryAssetId: 'raw-id', assetIds: ['raw-id', 'jpeg-id', 'third']),
    );
    await sut.finalizeRawJpegPair(asset, jpegId: 'jpeg-id', rawId: 'raw-id');
    final row = await ctx.db.select(ctx.db.stackEntity).getSingle();
    expect(row.id, 'existing');
    expect(row.primaryAssetId, 'raw-id');
    expect((await local.getById(asset.id))!.rawPairReceipt!.completed, isTrue);
  });
}
