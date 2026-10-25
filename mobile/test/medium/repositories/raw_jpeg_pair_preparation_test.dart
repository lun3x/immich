import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/table/local/asset.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/mocks.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late MockStorageRepository storage;
  late AssetService sut;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    ctx = MediumRepositoryContext();
    storage = MockStorageRepository();
    final mocks = RepositoryMocks();
    sut = AssetService(
      remoteRepository: mocks.remoteAsset.repo,
      exifRepository: mocks.remoteExif.repo,
      localRepository: LocalAssetRepository(ctx.db),
      apiRepository: mocks.assetApi.api,
      mediaRepository: mocks.assetMedia.api,
      trashedLocalRepository: mocks.trashedAsset,
      storageRepository: storage,
    );
  });
  tearDown(() async {
    await ctx.dispose();
    debugDefaultTargetPlatformOverride = null;
  });

  test('Android bypasses resource discovery', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final asset = (await ctx.newLocalAsset()).toDto();
    expect(await sut.inspectRawJpegPair(asset), asset);
    verifyNever(() => storage.getRawJpegPair(any()));
  });
  test('no pair is persisted and is inspected only once', () async {
    final asset = (await ctx.newLocalAsset()).toDto();
    when(() => storage.getRawJpegPair(asset.id)).thenAnswer((_) async => null);
    final inspected = await sut.inspectRawJpegPair(asset);
    expect(inspected.rawPairDiscovery, RawPairDiscovery.absent);
    await sut.inspectRawJpegPair(inspected);
    verify(() => storage.getRawJpegPair(asset.id)).called(1);
  });
  test('inspection error remains unknown and does not prove absence', () async {
    final asset = (await ctx.newLocalAsset()).toDto();
    when(() => storage.getRawJpegPair(asset.id)).thenThrow(StateError('Photos unavailable'));
    await expectLater(sut.inspectRawJpegPair(asset), throwsStateError);
    expect((await LocalAssetRepository(ctx.db).getById(asset.id))!.rawPairDiscovery, RawPairDiscovery.unknown);
  });
  test('manual preparation hashes both exact resources with explicit network policy', () async {
    final asset = (await ctx.newLocalAsset()).toDto();
    final pair = rawPair(assetId: asset.id);
    when(() => storage.getRawJpegPair(asset.id)).thenAnswer((_) async => pair);
    when(() => storage.hashPhotoResources(any(), allowNetworkAccess: true)).thenAnswer((invocation) async {
      final requests = invocation.positionalArguments.single as List<PhotoResourceRequest>;
      expect(requests.map((r) => r.resource.key).toSet(), {'jpeg', 'raw'});
      return requests
          .map(
            (r) => PhotoResourceHashResult(
              assetId: r.assetId,
              resourceKey: r.resource.key,
              hash: '${r.resource.key}-hash',
            ),
          )
          .toList();
    });
    final prepared = await sut.prepareRawJpegPair(asset, allowNetworkAccess: true);
    expect(prepared.checksum, 'jpeg-hash');
    expect(prepared.rawChecksum, 'raw-hash');
    expect(prepared.rawPairReceipt, isNull);
  });
}
