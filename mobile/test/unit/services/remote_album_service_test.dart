import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../fixtures/asset.stub.dart';
import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../service.mocks.dart';
import '../factories/user_factory.dart';
import '../mocks.dart';

void main() {
  late RemoteAlbumService sut;
  final mocks = RepositoryMocks();

  setUpAll(() {
    registerFallbackValue(<String>[]);
    registerFallbackValue(const UploadCallbacks());
  });

  setUp(() {
    sut = RemoteAlbumService(mocks.remoteAlbum, mocks.albumApi, MockForegroundUploadService());
  });

  tearDown(() {
    mocks.resetAll();
  });

  test('a manually uploaded pair adds the single JPEG callback to the album', () async {
    final upload = MockForegroundUploadService();
    sut = RemoteAlbumService(mocks.remoteAlbum, mocks.albumApi, upload);
    final pair = LocalAssetStub.image1.copyWith(
      rawJpegPair: rawPair(assetId: LocalAssetStub.image1.id),
      rawPairDiscovery: RawPairDiscovery.present,
    );
    when(
      () => upload.uploadManual(
        any(),
        callbacks: any(named: 'callbacks'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((i) async {
      (i.namedArguments[#callbacks] as UploadCallbacks).onSuccess!(pair.id, 'jpeg-id');
    });
    when(
      () => mocks.albumApi.addAssets('album', ['jpeg-id']),
    ).thenAnswer((_) async => (added: ['jpeg-id'], failed: <String>[]));
    when(() => mocks.remoteAlbum.addAssets('album', ['jpeg-id'])).thenAnswer((_) async => 1);
    when(
      () => mocks.remoteAlbum.upsertRemoteAssetStub(remoteId: 'jpeg-id', ownerId: 'owner', source: pair),
    ).thenAnswer((_) async {});
    final count = await sut.addAssetsToAlbum(
      albumId: 'album',
      uploader: UserFactory.createDto(id: 'owner'),
      candidates: AlbumAssetCandidates(remoteAssetIds: [], localAssetsToUpload: [pair]),
    );
    expect(count, 1);
    verify(() => mocks.albumApi.addAssets('album', ['jpeg-id'])).called(1);
  });

  group('RemoteAlbumService', () {
    group('removeAssets', () {
      test('persists only the assets the server actually removed, not the whole request', () async {
        const albumId = 'album-1';
        const requested = ['asset-1', 'asset-2', 'asset-3'];
        const removed = ['asset-1', 'asset-3'];

        // The server rejected 'asset-2'
        when(
          () => mocks.albumApi.removeAssets(albumId, requested),
        ).thenAnswer((_) async => (removed: removed, failed: ['asset-2']));
        when(() => mocks.remoteAlbum.removeAssets(albumId, any())).thenAnswer((_) async {});

        final count = await sut.removeAssets(albumId: albumId, assetIds: requested);

        final persisted =
            verify(() => mocks.remoteAlbum.removeAssets(albumId, captureAny())).captured.single as List<String>;
        expect(persisted, removed);
        expect(persisted, isNot(contains('asset-2')));

        expect(count, removed.length);
      });
    });
  });
}
