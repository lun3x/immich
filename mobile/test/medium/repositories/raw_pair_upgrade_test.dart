import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/remote_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../api.mocks.dart';
import '../../drift/main/generated/schema.dart';
import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../unit/factories/user_factory.dart';
import '../../unit/mocks.dart';

void main() {
  test('v35 JPEG-only backup retries RAW, survives recreation and stacks only the verified Photos item', () async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const jpegHash = 'existing-jpeg-hash';
    final rawBytes = [82, 65, 70, 0, 1, 2, 3];
    final rawHash = base64Encode(sha1.convert(rawBytes).bytes);
    final schema = await SchemaVerifier(GeneratedHelper()).schemaAt(35);
    schema.rawDatabase.execute(
      "INSERT INTO local_asset_entity (id, name, type, checksum, created_at, updated_at) VALUES ('pair', 'IMG.JPG', 1, '$jpegHash', '2025-01-01T00:00:00.000Z', '2025-01-01T00:00:00.000Z')",
    );
    schema.rawDatabase.execute(
      "INSERT INTO local_album_entity (id, name, backup_selection) VALUES ('camera', 'Camera', 0)",
    );
    schema.rawDatabase.execute("INSERT INTO local_album_asset_entity (album_id, asset_id) VALUES ('camera', 'pair')");
    final db = Drift(schema.newConnection());
    await SchemaVerifier(GeneratedHelper()).migrateAndValidate(db, 36);
    final local = LocalAssetRepository(db);
    final remote = RemoteAssetRepository(db);
    final backup = BackupRepository(db);
    final mocks = RepositoryMocks();
    final storage = MockStorageRepository();
    final upload = MockUploadRepository();
    final exports = await Directory.systemTemp.createTemp('upgrade-raw-test');
    addTearDown(() async {
      await Store.dispose();
      await db.close();
      await exports.delete(recursive: true);
      debugDefaultTargetPlatformOverride = null;
    });
    await StoreService.init(storeRepository: StoreRepository(db));
    await Store.put(StoreKey.currentUser, UserFactory.createDto(id: 'owner'));
    await Store.put(StoreKey.serverEndpoint, 'https://photos.example/api');
    await Store.put(StoreKey.deviceId, 'device');
    await db.customStatement(
      "INSERT INTO user_entity (id, name, email, avatar_color, profile_changed_at) VALUES ('owner', 'owner', 'o@example.com', 0, '2025-01-01T00:00:00.000Z')",
    );
    var rawPresent = false;
    var failRaw = true;
    final sentNames = <String>[];
    final successes = <String>[];
    final errors = <String>[];
    registerFallbackValue(rawPair().request(PhotoResourceRole.raw));
    registerFallbackValue(File('file'));
    when(() => storage.getRawJpegPair('pair')).thenAnswer((_) async => rawPair());
    when(() => storage.hashPhotoResources(any(), allowNetworkAccess: true)).thenAnswer(
      (i) async => [
        for (final request in i.positionalArguments.single as List<PhotoResourceRequest>)
          PhotoResourceHashResult(
            assetId: request.assetId,
            resourceKey: request.resource.key,
            hash: request.resource.key == 'raw' ? rawHash : jpegHash,
          ),
      ],
    );
    when(
      () => storage.exportPhotoResource(any(), allowNetworkAccess: true, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer((i) async {
      final request = i.positionalArguments.single as PhotoResourceRequest;
      expect(request.resource.key, 'raw');
      return File('${exports.path}/IMG.RAF')..writeAsBytesSync(rawBytes);
    });
    when(() => mocks.assetApi.api.checkUploadChecksums(any())).thenAnswer((i) async {
      expect(i.positionalArguments.single, {'jpeg': jpegHash, 'raw': rawHash});
      return {
        'jpeg': (assetId: 'jpeg-id', isTrashed: false),
        'raw': (assetId: rawPresent ? 'raw-id' : null, isTrashed: false),
      };
    });
    when(() => mocks.assetApi.api.stackWithoutMerging('jpeg-id', 'raw-id')).thenAnswer(
      (_) async => const StackResponse(id: 'pair-stack', primaryAssetId: 'jpeg-id', assetIds: ['jpeg-id', 'raw-id']),
    );
    when(
      () => upload.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((i) async {
      sentNames.add(i.namedArguments[#originalFileName] as String);
      expect((i.namedArguments[#file] as File).readAsBytesSync(), rawBytes);
      if (failRaw) {
        return UploadResult.error(errorMessage: 'connection interrupted');
      }
      rawPresent = true;
      return UploadResult.success(remoteAssetId: 'raw-id');
    });
    AssetService service() => AssetService(
      remoteRepository: remote,
      exifRepository: mocks.remoteExif.repo,
      localRepository: local,
      apiRepository: mocks.assetApi.api,
      mediaRepository: mocks.assetMedia.api,
      trashedLocalRepository: mocks.trashedAsset,
      storageRepository: storage,
    );
    ForegroundUploadService transport() =>
        ForegroundUploadService(upload, storage, backup, MockConnectivityApi(), mocks.assetMedia.api, service());
    final old = (await local.getById('pair'))!;
    await remote.upsertUploadedResource(
      remoteId: 'jpeg-id',
      ownerId: 'owner',
      source: old,
      resource: rawPair().processed,
      checksum: jpegHash,
    );
    expect(old.rawPairDiscovery, RawPairDiscovery.unknown);
    expect(old.checksum, jpegHash);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 1, processing: 1));
    final callbacks = UploadCallbacks(
      onSuccess: (_, id) => successes.add(id),
      onError: (_, error) => errors.add(error),
    );
    await transport().uploadSingleAsset(old, null, callbacks: callbacks);
    expect(sentNames, ['IMG.RAF']);
    expect(successes, isEmpty);
    expect(errors, hasLength(1));
    expect((await local.getRemovalCandidates('owner', DateTime(2028))).assets, isEmpty);
    expect((await backup.getAllCounts('owner')).remainder, 1);
    failRaw = false;
    await transport().uploadSingleAsset((await local.getById('pair'))!, null, callbacks: callbacks);
    expect(sentNames, ['IMG.RAF', 'IMG.RAF']);
    expect(successes, ['jpeg-id']);
    expect(await backup.getAllCounts('owner'), (total: 1, remainder: 0, processing: 0));
    expect((await local.getById('pair'))!.rawPairReceipt!.completed, isTrue);
    verify(() => mocks.assetApi.api.stackWithoutMerging('jpeg-id', 'raw-id')).called(1);
    final stack = await db.select(db.stackEntity).getSingle();
    expect(stack.primaryAssetId, 'jpeg-id');
    for (final (id, hash) in [('separate-jpeg', jpegHash), ('separate-raw', rawHash)]) {
      await db.customStatement("INSERT INTO local_asset_entity (id, name, type, checksum) VALUES (?, 'IMG', 1, ?)", [
        id,
        hash,
      ]);
      when(() => storage.getRawJpegPair(id)).thenAnswer((_) async => null);
      await transport().uploadSingleAsset((await local.getById(id))!, null, callbacks: callbacks);
    }
    verifyNever(() => mocks.assetApi.api.stackWithoutMerging(any(), any()));
    expect(sentNames, ['IMG.RAF', 'IMG.RAF']);
  });
}
