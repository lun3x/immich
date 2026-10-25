import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/data/db/main/database.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../api.mocks.dart';
import '../fixtures/asset.stub.dart';
import '../fixtures/raw_jpeg_pair.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';
import '../service.mocks.dart';
import '../unit/factories/user_factory.dart';

void main() {
  late ForegroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockBackupRepository mockBackupRepository;
  late MockConnectivityApi mockConnectivityApi;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late MockAssetService mockAssetService;
  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: StoreRepository(db));
    await SettingsRepository.ensureInitialized(db);

    await Store.put(StoreKey.serverEndpoint, 'http://demo.immich.app');
    await Store.put(StoreKey.deviceId, 'device-id');

    registerFallbackValue(PhotoResourceRole.raw);
    registerFallbackValue(rawPair().request(PhotoResourceRole.raw));
    registerFallbackValue(LocalAssetStub.image1);
    registerFallbackValue(File('file'));
    registerFallbackValue(<String, String>{});
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockBackupRepository = MockBackupRepository();
    mockConnectivityApi = MockConnectivityApi();
    mockAssetMediaRepository = MockAssetMediaRepository();
    mockAssetService = MockAssetService();
    when(() => mockAssetService.getLocalAsset(any())).thenAnswer((_) async => null);
    when(
      () =>
          mockAssetService.prepareRawJpegPair(any(), allowNetworkAccess: true, cancelToken: any(named: 'cancelToken')),
    ).thenAnswer(
      (i) async => (i.positionalArguments.single as LocalAsset).copyWith(rawPairDiscovery: RawPairDiscovery.absent),
    );
    when(() => mockAssetService.stackEditedUpload(any(), any(), any())).thenAnswer((_) async {});

    sut = ForegroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockBackupRepository,
      mockConnectivityApi,
      mockAssetMediaRepository,
      mockAssetService,
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  List<Map<String, String>> captureFields() {
    final captured = <Map<String, String>>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      final fields = invocation.namedArguments[#fields] as Map<String, String>;
      captured.add(Map.of(fields));
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  List<String> captureOriginalFileNames() {
    final captured = <String>[];
    when(
      () => mockUploadRepository.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
      ),
    ).thenAnswer((invocation) async {
      captured.add(invocation.namedArguments[#originalFileName] as String);
      return UploadResult.success(remoteAssetId: 'remote-${captured.length}');
    });
    return captured;
  }

  group('verified RAW pair upload', () {
    late LocalAsset pairAsset;
    late Directory exports;
    late Map<PhotoResourceRole, String> remote;
    late List<String> filenames;
    late List<Map<String, String>> fields;
    late List<List<int>> bytes;
    late List<File> files;
    late List<String> success;
    late List<String> errors;
    UploadResult? failure;

    setUp(() async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await Store.put(StoreKey.currentUser, UserFactory.createDto(id: 'owner'));
      exports = await Directory.systemTemp.createTemp('pair-foreground-test');
      pairAsset = LocalAssetStub.image1.copyWith(
        rawPairDiscovery: RawPairDiscovery.present,
        rawJpegPair: rawPair(assetId: LocalAssetStub.image1.id),
        checksum: 'jpeg-hash',
        rawChecksum: 'raw-hash',
        cloudId: 'cloud',
      );
      remote = {};
      filenames = [];
      fields = [];
      bytes = [];
      files = [];
      success = [];
      errors = [];
      failure = null;
      when(
        () => mockAssetService.prepareRawJpegPair(
          any(),
          allowNetworkAccess: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((_) async => pairAsset);
      when(() => mockAssetService.resolveRawPairRemoteIds(pairAsset)).thenAnswer(
        (_) async =>
            RawPairRemoteIds(jpegId: remote[PhotoResourceRole.processed], rawId: remote[PhotoResourceRole.raw]),
      );
      when(
        () => mockStorageRepository.exportPhotoResource(
          any(),
          allowNetworkAccess: true,
          cancelToken: any(named: 'cancelToken'),
        ),
      ).thenAnswer((i) async {
        final request = i.positionalArguments.single as PhotoResourceRequest;
        final file = File('${exports.path}/${request.resource.filename}');
        await file.writeAsBytes(request.resource.key == 'raw' ? [1, 2, 3] : [4, 5]);
        files.add(file);
        return file;
      });
      when(
        () => mockUploadRepository.uploadFile(
          file: any(named: 'file'),
          originalFileName: any(named: 'originalFileName'),
          fields: any(named: 'fields'),
          cancelToken: any(named: 'cancelToken'),
          onProgress: any(named: 'onProgress'),
          logContext: any(named: 'logContext'),
        ),
      ).thenAnswer((i) async {
        final file = i.namedArguments[#file] as File;
        filenames.add(i.namedArguments[#originalFileName] as String);
        fields.add(Map.of(i.namedArguments[#fields] as Map<String, String>));
        bytes.add(await file.readAsBytes());
        return failure ?? UploadResult.success(remoteAssetId: filenames.last.endsWith('.RAF') ? 'raw-id' : 'jpeg-id');
      });
      when(
        () => mockAssetService.recordRawPairUpload(
          pairAsset,
          role: any(named: 'role'),
          remoteId: any(named: 'remoteId'),
        ),
      ).thenAnswer((i) async {
        remote[i.namedArguments[#role] as PhotoResourceRole] = i.namedArguments[#remoteId] as String;
      });
      when(
        () => mockAssetService.finalizeRawJpegPair(pairAsset, jpegId: 'jpeg-id', rawId: 'raw-id'),
      ).thenAnswer((_) async {});
    });
    tearDown(() async {
      debugDefaultTargetPlatformOverride = null;
      await exports.delete(recursive: true);
    });
    Future<void> upload({Completer<void>? cancelToken}) => sut.uploadSingleAsset(
      pairAsset,
      cancelToken,
      callbacks: UploadCallbacks(onSuccess: (_, id) => success.add(id), onError: (_, error) => errors.add(error)),
    );

    test('existing JPEG transfers only RAW and emits one JPEG success after finalization', () async {
      remote[PhotoResourceRole.processed] = 'jpeg-id';
      when(
        () => mockAssetService.getLocalAsset(pairAsset.id),
      ).thenAnswer((_) async => pairAsset.copyWith(remoteId: 'jpeg-id'));
      await upload();
      expect(filenames, ['IMG.RAF']);
      expect(bytes, [
        [1, 2, 3],
      ]);
      expect(success, ['jpeg-id']);
      expect(errors, isEmpty);
      expect(fields.single.containsKey('metadata'), isFalse);
      expect(fields.single['visibility'], isNot('hidden'));
      verify(() => mockAssetService.finalizeRawJpegPair(pairAsset, jpegId: 'jpeg-id', rawId: 'raw-id')).called(1);
      verifyNever(() => mockAssetService.stackEditedUpload(any(), any(), any()));
      expect(files.single.existsSync(), isFalse);
    });
    test('both missing uploads exact RAW bytes before processed JPEG; only JPEG gets cloud metadata', () async {
      await upload();
      expect(filenames, ['IMG.RAF', 'IMG.JPG']);
      expect(bytes, [
        [1, 2, 3],
        [4, 5],
      ]);
      expect(fields.first.containsKey('metadata'), isFalse);
      expect(fields.last['metadata'], contains('cloud'));
      expect(success, ['jpeg-id']);
      for (final file in files) {
        expect(file.existsSync(), isFalse);
      }
    });
    test('RAW failure stops JPEG stack and item success', () async {
      failure = UploadResult.error(errorMessage: 'Quota has been exceeded!');
      await upload();
      expect(filenames, ['IMG.RAF']);
      expect(success, isEmpty);
      expect(errors, hasLength(1));
      expect(sut.shouldAbortUpload, isTrue);
      verifyNever(
        () => mockAssetService.finalizeRawJpegPair(
          any(),
          jpegId: any(named: 'jpegId'),
          rawId: any(named: 'rawId'),
        ),
      );
    });
    test('cancelled RAW stops advancement and cleans only its export', () async {
      failure = UploadResult.cancelled();
      final unrelated = File('${exports.path}/pending-other.RAF')..writeAsStringSync('pending');
      await upload();
      expect(filenames, ['IMG.RAF']);
      expect(success, isEmpty);
      expect(sut.shouldAbortUpload, isTrue);
      expect(unrelated.existsSync(), isTrue);
      expect(files.single.existsSync(), isFalse);
    });
    test('stack failure retries finalization without uploading either file again', () async {
      when(
        () => mockAssetService.finalizeRawJpegPair(pairAsset, jpegId: 'jpeg-id', rawId: 'raw-id'),
      ).thenThrow(StateError('conflict'));
      await upload();
      expect(filenames, ['IMG.RAF', 'IMG.JPG']);
      expect(success, isEmpty);
      expect(errors, hasLength(1));
      when(
        () => mockAssetService.finalizeRawJpegPair(pairAsset, jpegId: 'jpeg-id', rawId: 'raw-id'),
      ).thenAnswer((_) async {});
      await upload();
      expect(filenames, ['IMG.RAF', 'IMG.JPG']);
      expect(success, ['jpeg-id']);
    });
    test('trashed RAW returns backup error without any upload', () async {
      when(
        () => mockAssetService.resolveRawPairRemoteIds(pairAsset),
      ).thenAnswer((_) async => const RawPairRemoteIds(jpegId: 'jpeg-id', rawTrashed: true));
      await upload();
      expect(filenames, isEmpty);
      expect(success, isEmpty);
      expect(errors.single, contains('Restore'));
    });
    test('manual unhashed input is prepared before choosing the pair path', () async {
      final unhashed = LocalAssetStub.image1;
      remote[PhotoResourceRole.raw] = 'raw-id';
      remote[PhotoResourceRole.processed] = 'jpeg-id';
      await sut.uploadSingleAsset(unhashed, null, callbacks: UploadCallbacks(onSuccess: (_, id) => success.add(id)));
      verify(
        () => mockAssetService.prepareRawJpegPair(unhashed, allowNetworkAccess: true, cancelToken: null),
      ).called(1);
      expect(success, ['jpeg-id']);
      expect(filenames, isEmpty);
    });
  });

  group('uploadSingleAsset', () {
    test('should upload the motion part hidden and keep the still image visible', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(2));
      expect(captured[0]['visibility'], equals('hidden'));
      expect(captured[0].containsKey('livePhotoVideoId'), isFalse);
      expect(captured[1].containsKey('visibility'), isFalse);
      expect(captured[1]['livePhotoVideoId'], equals('remote-1'));
    });

    test('should not set visibility for a regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');

      final captured = captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(captured, hasLength(1));
      expect(captured[0].containsKey('visibility'), isFalse);
    });

    test('corrects the extension when iOS returns a rendered file for a .dng asset', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_6499.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_6499.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_6499.jpg']));
    });

    test('keeps the .dng extension for a genuine RAW original', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/IMG_5210.dng');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'IMG_5210.dng');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['IMG_5210.dng']));
    });

    test('borrows the extension from the asset name for an extensionless name (DJI/Fusion)', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/DJI_0001');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'DJI_0001');

      final names = captureOriginalFileNames();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      expect(names, equals(['DJI_0001.jpg']));
    });

    test('stacks a plain photo after its upload', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/photo.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'photo.jpg');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.getLocalAsset(asset.id)).called(1);
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-1', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });

    test('stacks the still of a live photo, not its video', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final mockEntity = MockAssetEntity();
      final stillFile = File('/path/to/still.heic');
      final videoFile = File('/path/to/motion.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => stillFile);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => videoFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'live.heic');
      captureFields();

      await sut.uploadSingleAsset(asset, null, callbacks: const UploadCallbacks());

      verify(() => mockAssetService.getLocalAsset(asset.id)).called(1);
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote-2', 'sha')).called(1);
      verifyNoMoreInteractions(mockAssetService);
    });

    test('does not upload a photo the server already has', () async {
      final asset = LocalAssetStub.image1.copyWith(checksum: 'sha');
      final succeeded = <String>[];
      when(() => mockAssetService.getLocalAsset(asset.id)).thenAnswer((_) async => asset.copyWith(remoteId: 'remote'));

      await sut.uploadSingleAsset(
        asset,
        null,
        callbacks: UploadCallbacks(onSuccess: (_, remoteId) => succeeded.add(remoteId)),
      );

      expect(succeeded, equals(['remote']));
      verify(() => mockAssetService.stackEditedUpload(asset.localId!, 'remote', 'sha')).called(1);
      verifyZeroInteractions(mockStorageRepository);
      verifyZeroInteractions(mockUploadRepository);
    });
  });
}
