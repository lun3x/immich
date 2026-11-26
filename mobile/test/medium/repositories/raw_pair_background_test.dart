import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../../api.mocks.dart';
import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../../infrastructure/repository.mock.dart';
import '../../service.mocks.dart';
import '../../unit/factories/user_factory.dart';
import '../../unit/mocks.dart';
import '../repository_context.dart';

class _Queue extends Mock implements UploadRepository {
  @override
  void Function(TaskStatusUpdate)? onUploadStatus;
  @override
  void Function(TaskProgressUpdate)? onTaskProgress;
  final active = <String, Task>{};
  final records = <String, TaskRecord>{};
  final enqueued = <UploadTask>[];
  bool failEnqueue = false;
  @override
  Future<List<Task>> getActiveTasks(String group) async => active.values.where((t) => t.group == group).toList();
  @override
  Future<Task?> getTask(String id) async => active[id];
  @override
  Future<TaskRecord?> getTaskRecord(String id) async => records[id];
  @override
  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) async {
    if (failEnqueue) {
      throw StateError('queue unavailable');
    }
    return tasks.map((t) {
      if (active.containsKey(t.taskId)) {
        return false;
      }
      active[t.taskId] = t;
      enqueued.add(t);
      return true;
    }).toList();
  }

  @override
  Future<int> reset(String group) async {
    final ids = active.values.where((t) => t.group == group).map((t) => t.taskId).toList();
    for (final id in ids) {
      active.remove(id);
    }
    return ids.length;
  }

  @override
  Future<void> deleteDatabaseRecords(String group) async {
    records.removeWhere((_, record) => record.group == group);
  }

  @override
  Future<bool> cancelTasks(Iterable<String> ids) async {
    for (final id in ids) {
      active.remove(id);
    }
    return true;
  }

  @override
  Future<void> start() async {}
}

void main() {
  late MediumRepositoryContext ctx;
  late MediumRepositoryContext storeCtx;
  late LocalAssetRepository local;
  late MockStorageRepository storage;
  late MockAssetService service;
  late _Queue queue;
  late MockConnectivityApi connectivity;
  late BackgroundUploadService sut;
  late LocalAsset asset;
  late Directory exports;
  late Map<PhotoResourceRole, String> ids;
  late RepositoryMocks mocks;
  late MockBackupRepository backup;
  var exportNumber = 0;
  late List<TaskStatusUpdate> statuses;
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    drift.driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (_) async => 'test',
    );
    storeCtx = MediumRepositoryContext();
    await StoreService.init(storeRepository: StoreRepository(storeCtx.db));
    await Store.put(StoreKey.currentUser, UserFactory.createDto(id: 'owner'));
    await Store.put(StoreKey.serverEndpoint, 'https://photos.example/api');
    await Store.put(StoreKey.deviceId, 'device');
    await SettingsRepository.ensureInitialized(storeCtx.db);
    registerFallbackValue(rawPair().request(PhotoResourceRole.raw));
    registerFallbackValue(PhotoResourceRole.raw);
    registerFallbackValue(rawReceipt('revision-1'));
  });
  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    ctx = MediumRepositoryContext();
    local = LocalAssetRepository(ctx.db);
    mocks = RepositoryMocks();
    await ctx.newAuthUser(id: 'owner');
    await ctx.db.customStatement(
      "INSERT INTO store_entity (id, string_value) VALUES (2, 'owner'), (12, 'https://photos.example/api')",
    );
    final row = await ctx.newLocalAsset(iCloudId: 'cloud');
    await local.saveRawPairDiscovery(row.id, rawPair(assetId: row.id));
    await local.saveRawPairHashes(row.id, 'revision-1', jpegChecksum: 'jpeg', rawChecksum: 'raw');
    asset = (await local.getById(row.id))!.copyWith(cloudId: 'cloud');
    exports = await Directory.systemTemp.createTemp('background-pair-test');
    storage = MockStorageRepository();
    service = MockAssetService();
    queue = _Queue();
    ids = {};
    statuses = [];
    when(() => storage.clearCache()).thenAnswer((_) async {});
    when(() => storage.getRawJpegPair(asset.id)).thenAnswer((_) async => asset.rawJpegPair);
    when(
      () => service.prepareRawJpegPair(
        any(),
        allowNetworkAccess: any(named: 'allowNetworkAccess'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((_) async => asset);
    when(() => service.resolveRawPairRemoteIds(any(), expectedScope: any(named: 'expectedScope'))).thenAnswer(
      (_) async => RawPairRemoteIds(jpegId: ids[PhotoResourceRole.processed], rawId: ids[PhotoResourceRole.raw]),
    );
    when(
      () => service.recordRawPairUpload(
        any(),
        role: any(named: 'role'),
        remoteId: any(named: 'remoteId'),
        expectedScope: any(named: 'expectedScope'),
      ),
    ).thenAnswer((i) async {
      ids[i.namedArguments[#role] as PhotoResourceRole] = i.namedArguments[#remoteId] as String;
      final scope = await local.getRawPairScope('revision-1');
      final old = (await local.getById(asset.id))!.rawPairReceipt;
      await local.saveRawPairReceipt(
        asset.id,
        RawPairReceipt(
          serverEndpoint: scope.serverEndpoint,
          ownerId: scope.ownerId,
          pairKey: scope.pairKey,
          rawId: ids[PhotoResourceRole.raw],
          jpegId: ids[PhotoResourceRole.processed],
          rawTaskId: old?.rawTaskId,
          jpegTaskId: old?.jpegTaskId,
        ),
      );
    });
    when(
      () => service.finalizeRawJpegPair(
        any(),
        jpegId: any(named: 'jpegId'),
        rawId: any(named: 'rawId'),
        expectedScope: any(named: 'expectedScope'),
      ),
    ).thenAnswer((_) async {
      final scope = await local.getRawPairScope('revision-1');
      await local.saveRawPairReceipt(
        asset.id,
        RawPairReceipt(
          serverEndpoint: scope.serverEndpoint,
          ownerId: scope.ownerId,
          pairKey: scope.pairKey,
          rawId: ids[PhotoResourceRole.raw],
          jpegId: ids[PhotoResourceRole.processed],
          completed: true,
        ),
      );
    });
    when(
      () => storage.exportPhotoResource(
        any(),
        allowNetworkAccess: any(named: 'allowNetworkAccess'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((i) async {
      final r = i.positionalArguments.single as PhotoResourceRequest;
      final directory = Directory('${exports.path}/${exportNumber++}')..createSync();
      return File('${directory.path}/${r.resource.filename}')..writeAsStringSync(r.resource.key);
    });
    connectivity = MockConnectivityApi();
    when(() => connectivity.getCapabilities()).thenAnswer((_) async => [NetworkCapability.unmetered]);
    backup = MockBackupRepository();
    when(() => backup.getCandidates('owner')).thenAnswer((_) async => []);
    sut = BackgroundUploadService(
      queue,
      storage,
      local,
      backup,
      mocks.assetMedia.api,
      service,
      connectivityApi: connectivity,
    );
    sut.taskStatusStream.listen(statuses.add);
  });
  tearDown(() async {
    sut.dispose();
    await ctx.dispose();
    await exports.delete(recursive: true);
    debugDefaultTargetPlatformOverride = null;
  });
  tearDownAll(() async {
    await Store.dispose();
    await storeCtx.dispose();
  });
  Future<void> complete(UploadTask task, String remoteId) async {
    queue.active.remove(task.taskId);
    queue.records[task.taskId] = TaskRecord(task, TaskStatus.complete, 1, 0);
    await sut.handleTaskStatusUpdate(TaskStatusUpdate(task, TaskStatus.complete, null, jsonEncode({'id': remoteId})));
  }

  test('RAW completion chains processed once; JPEG completion reports one item', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    expect(raw.fields['filename'], 'IMG.RAF');
    expect(raw.requiresWiFi, isTrue);
    expect(raw.fields['metadata'], isNull);
    expect(raw.fields['visibility'], isNot('hidden'));
    await queue.enqueueBackgroundAll([raw]);
    await complete(raw, 'raw-id');
    final jpeg = queue.enqueued.last;
    expect(jpeg.fields['filename'], 'IMG.JPG');
    expect(jpeg.taskId, isNot(raw.taskId));
    expect(jpeg.fields['metadata'], isNotNull);
    await complete(raw, 'raw-id');
    expect(queue.enqueued, hasLength(2));
    await complete(jpeg, 'jpeg-id');
    await complete(jpeg, 'jpeg-id');
    verify(
      () => service.finalizeRawJpegPair(
        any(),
        jpegId: 'jpeg-id',
        rawId: 'raw-id',
        expectedScope: any(named: 'expectedScope'),
      ),
    ).called(1);
    verifyNever(() => service.stackEditedUpload(any(), any(), any()));
    await pumpEventQueue();
    expect(statuses.where((s) => s.status == TaskStatus.complete), hasLength(1));
  });
  test('already uploaded JPEG finalizes from RAW completion without another task', () async {
    ids[PhotoResourceRole.processed] = 'jpeg-id';
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    await complete(raw, 'raw-id');
    expect(queue.enqueued, isEmpty);
    verify(
      () => service.finalizeRawJpegPair(
        any(),
        jpegId: 'jpeg-id',
        rawId: 'raw-id',
        expectedScope: any(named: 'expectedScope'),
      ),
    ).called(1);
  });
  test('restart after a missed RAW callback reuses RAW and rebuilds only JPEG', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    ids[PhotoResourceRole.raw] = 'raw-id';
    queue.records[raw.taskId] = TaskRecord(raw, TaskStatus.complete, 1, 0);
    final jpeg = await sut.getUploadTask(asset);
    expect(jpeg!.fields['filename'], 'IMG.JPG');
  });
  test('restart after both resources exist retries finalization without exports', () async {
    ids[PhotoResourceRole.raw] = 'raw-id';
    ids[PhotoResourceRole.processed] = 'jpeg-id';
    expect(await sut.getUploadTask(asset), isNull);
    verifyNever(
      () => storage.exportPhotoResource(
        any(),
        allowNetworkAccess: any(named: 'allowNetworkAccess'),
        cancelToken: any(named: 'cancelToken'),
      ),
    );
    verify(
      () => service.finalizeRawJpegPair(
        any(),
        jpegId: 'jpeg-id',
        rawId: 'raw-id',
        expectedScope: any(named: 'expectedScope'),
      ),
    ).called(1);
  });
  test('an active component is not exported again and cache clearing preserves its file', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    await queue.enqueueBackgroundAll([raw]);
    expect(await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw), isNull);
    await StorageRepository(MockNativeSyncApi()).clearCache();
    expect(File(await raw.filePath()).existsSync(), isTrue);
    verify(
      () => storage.exportPhotoResource(any(), allowNetworkAccess: true, cancelToken: any(named: 'cancelToken')),
    ).called(1);
  });
  test('metered networks forbid iCloud export while retaining the queued Wi-Fi requirement', () async {
    when(() => connectivity.getCapabilities()).thenAnswer((_) async => [NetworkCapability.cellular]);
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    expect(raw.requiresWiFi, isTrue);
    verify(
      () => storage.exportPhotoResource(any(), allowNetworkAccess: false, cancelToken: any(named: 'cancelToken')),
    ).called(1);
  });
  test('stale attempt cannot release or delete a replacement with the same queue ID', () async {
    final first = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    final second = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    expect(first.taskId, second.taskId);
    expect(first.metaData, isNot(second.metaData));
    final claim = (await local.getById(asset.id))!.rawPairReceipt!.rawTaskId;
    await sut.handleTaskStatusUpdate(TaskStatusUpdate(first, TaskStatus.complete, null, '{"id":"raw-id"}'));
    expect((await local.getById(asset.id))!.rawPairReceipt!.rawTaskId, claim);
    expect(File(await second.filePath()).existsSync(), isTrue);
    expect(queue.enqueued, isEmpty);
  });
  test('cancel releases queue claims and cleans their files without a platform callback', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    await queue.enqueueBackgroundAll([raw]);
    await sut.cancel();
    expect((await local.getById(asset.id))!.rawPairReceipt!.rawTaskId, isNull);
    expect(File(await raw.filePath()).existsSync(), isFalse);
  });
  test('failed enqueue retains RAW presence but releases the unqueued JPEG export', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    queue.failEnqueue = true;
    await complete(raw, 'raw-id');
    final receipt = (await local.getById(asset.id))!.rawPairReceipt!;
    expect(receipt.rawId, 'raw-id');
    expect(receipt.jpegTaskId, isNull);
    expect(queue.enqueued, isEmpty);
  });
  test('cancel interrupts an in-flight native export and releases its claim', () async {
    final started = Completer<void>();
    Completer<void>? cancellation;
    when(
      () => storage.exportPhotoResource(
        any(),
        allowNetworkAccess: any(named: 'allowNetworkAccess'),
        cancelToken: any(named: 'cancelToken'),
      ),
    ).thenAnswer((i) async {
      cancellation = i.namedArguments[#cancelToken] as Completer<void>?;
      started.complete();
      if (cancellation == null) {
        throw StateError('missing export cancellation');
      }
      await cancellation!.future;
      throw PlatformException(code: 'EXPORT_CANCELLED');
    });
    final building = sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw);
    final failed = expectLater(building, throwsA(isA<PlatformException>()));
    await started.future;
    expect(cancellation, isNotNull);
    await sut.cancel();
    await failed;
    expect((await local.getById(asset.id))!.rawPairReceipt!.rawTaskId, isNull);
  });

  test('old queue metadata is canceled and rebuilt without a compatibility parser', () async {
    final file = File('${exports.path}/old.jpg')..writeAsStringSync('old');
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final task = UploadTask(
      taskId: 'old',
      url: 'https://photos.example/api/assets',
      filename: filename,
      directory: directory,
      baseDirectory: baseDirectory,
      group: kBackupGroup,
      metaData: '{"localAssetId":"old","isLivePhotos":false,"livePhotoVideoId":""}',
    );
    queue.active[task.taskId] = task;
    await sut.uploadBackupCandidates('owner');
    expect(queue.active, isEmpty);
    expect(file.existsSync(), isFalse);
  });

  test('stale endpoint and removed pair callbacks do not advance work', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    await ctx.db.customStatement("UPDATE store_entity SET string_value = 'https://other/api' WHERE id = 12");
    await complete(raw, 'raw-id');
    verifyNever(
      () => service.recordRawPairUpload(
        any(),
        role: any(named: 'role'),
        remoteId: any(named: 'remoteId'),
        expectedScope: any(named: 'expectedScope'),
      ),
    );
    expect(queue.enqueued, isEmpty);
  });
  test('a vanished original pair cannot complete or queue its JPEG', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    when(() => storage.getRawJpegPair(asset.id)).thenAnswer((_) async => null);
    await complete(raw, 'raw-id');
    expect(queue.enqueued, isEmpty);
    verifyNever(
      () => service.finalizeRawJpegPair(
        any(),
        jpegId: any(named: 'jpegId'),
        rawId: any(named: 'rawId'),
        expectedScope: any(named: 'expectedScope'),
      ),
    );
  });
  test('failed and canceled tasks release only their claim and delete only their export', () async {
    final raw = (await sut.getRawPairUploadTask(asset, role: PhotoResourceRole.raw))!;
    final file = File(await raw.filePath());
    final unrelated = File('${exports.path}/other')..writeAsStringSync('pending');
    await sut.handleTaskStatusUpdate(TaskStatusUpdate(raw, TaskStatus.failed));
    expect(file.existsSync(), isFalse);
    expect(unrelated.existsSync(), isTrue);
    expect((await local.getById(asset.id))!.rawPairReceipt!.rawTaskId, isNull);
    expect(queue.enqueued, isEmpty);
  });
}
