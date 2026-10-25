import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/network_capability_extensions.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/settings.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart' as api;
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

part 'background_upload.service.freezed.dart';

final backgroundUploadServiceProvider = Provider((ref) {
  final db = ref.watch(driftProvider);
  final service = BackgroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    db.localAssetRepository,
    db.backupRepository,
    ref.watch(assetMediaRepositoryProvider),
    ref.watch(assetServiceProvider),
    connectivityApi: ref.watch(connectivityApiProvider),
  );

  ref.onDispose(service.dispose);
  return service;
});

enum UploadComponentRole { regular, livePhotoVideo, rawCompanion, rawPairProcessed }

/// Metadata for upload tasks to track native components
@Freezed(fromJson: false, toJson: false)
abstract class UploadTaskMetadata with _$UploadTaskMetadata {
  const UploadTaskMetadata._();

  const factory UploadTaskMetadata({
    required String localAssetId,
    required UploadComponentRole componentRole,
    String? pairKey,
    String? serverEndpoint,
    String? ownerId,
    String? rawAssetId,
    String? taskClaim,
    required bool isLivePhotos,
    required String livePhotoVideoId,
    String? checksum,
  }) = _UploadTaskMetadata;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'localAssetId': localAssetId,
      'componentRole': componentRole.name,
      'pairKey': pairKey,
      'serverEndpoint': serverEndpoint,
      'ownerId': ownerId,
      'rawAssetId': rawAssetId,
      'taskClaim': taskClaim,
      'isLivePhotos': isLivePhotos,
      'livePhotoVideoId': livePhotoVideoId,
      'checksum': checksum,
    };
  }

  factory UploadTaskMetadata.fromMap(Map<String, dynamic> map) {
    return UploadTaskMetadata(
      localAssetId: map['localAssetId'] as String,
      componentRole: UploadComponentRole.values.byName(map['componentRole'] as String),
      pairKey: map['pairKey'] as String?,
      serverEndpoint: map['serverEndpoint'] as String?,
      ownerId: map['ownerId'] as String?,
      rawAssetId: map['rawAssetId'] as String?,
      taskClaim: map['taskClaim'] as String?,
      isLivePhotos: map['isLivePhotos'] as bool,
      livePhotoVideoId: map['livePhotoVideoId'] as String,
      checksum: map['checksum'] as String?,
    );
  }

  factory UploadTaskMetadata.fromJson(String source) =>
      UploadTaskMetadata.fromMap(json.decode(source) as Map<String, dynamic>);

  String toJson() => json.encode(toMap());
}

/// Service for handling background uploads using iOS URLSession (background_downloader)
///
/// This service handles asynchronous background uploads that can continue
/// even when the app is suspended. Primarily used for iOS background backup.
class BackgroundUploadService {
  BackgroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._localAssetRepository,
    this._backupRepository,
    this._assetMediaRepository,
    this._assetService, {
    required this._connectivityApi,
  }) {
    _uploadRepository.onUploadStatus = _onUploadCallback;
    _uploadRepository.onTaskProgress = _onTaskProgressCallback;
  }

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final LocalAssetRepository _localAssetRepository;
  final BackupRepository _backupRepository;
  final AssetMediaRepository _assetMediaRepository;
  final AssetService _assetService;
  final ConnectivityApi _connectivityApi;
  final Logger _logger = Logger('BackgroundUploadService');

  final StreamController<TaskStatusUpdate> _taskStatusController = StreamController<TaskStatusUpdate>.broadcast();
  final StreamController<TaskProgressUpdate> _taskProgressController = StreamController<TaskProgressUpdate>.broadcast();

  // ignore: unused-code
  Stream<TaskStatusUpdate> get taskStatusStream => _taskStatusController.stream;
  // ignore: unused-code
  Stream<TaskProgressUpdate> get taskProgressStream => _taskProgressController.stream;

  bool shouldAbortQueuingTasks = false;
  Completer<void> _queueCancellation = Completer<void>();

  void _onTaskProgressCallback(TaskProgressUpdate update) {
    if (!_taskProgressController.isClosed) {
      _taskProgressController.add(update);
    }
  }

  void _onUploadCallback(TaskStatusUpdate update) {
    unawaited(handleTaskStatusUpdate(update));
  }

  void dispose() {
    shouldAbortQueuingTasks = true;
    if (!_queueCancellation.isCompleted) {
      _queueCancellation.complete();
    }
    unawaited(_taskStatusController.close());
    unawaited(_taskProgressController.close());
  }

  /// Enqueue tasks to the background upload queue
  Future<List<bool>> enqueueTasks(List<UploadTask> tasks) {
    return _uploadRepository.enqueueBackgroundAll(tasks);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return _uploadRepository.getActiveTasks(group);
  }

  /// Start background upload using iOS URLSession
  ///
  /// Finds backup candidates, builds upload tasks, and enqueues them
  /// for background processing.
  Future<void> uploadBackupCandidates(String userId) async {
    await _storageRepository.clearCache();
    shouldAbortQueuingTasks = false;
    if (_queueCancellation.isCompleted) {
      _queueCancellation = Completer<void>();
    }

    final active = await _reconcileActiveTasks();
    final candidates = await _backupRepository.getCandidates(userId);
    if (candidates.isEmpty) {
      _logger.info("No new backup candidates found, finishing background upload");
      return;
    }

    _logger.info("Found ${candidates.length} backup candidates for background tasks");

    const batchSize = 100;
    final batch = candidates.take(batchSize).toList();
    final List<UploadTask> tasks = [];

    for (final asset in batch) {
      if (active.contains(asset.id)) {
        continue;
      }
      try {
        final task = await getUploadTask(asset);
        if (task != null) {
          tasks.add(task);
        }
      } catch (error, stack) {
        _logger.warning('Cannot prepare background upload', error, stack);
      }
    }

    if (tasks.isNotEmpty && !shouldAbortQueuingTasks) {
      _logger.info("Enqueuing ${tasks.length} background upload tasks");
      await _enqueueOwnedTasks(tasks);
    } else {
      for (final task in tasks) {
        await _discardOwnedTask(task);
      }
    }
  }

  /// Cancel all ongoing background uploads and reset the upload queue
  ///
  /// Returns the number of tasks left in the queue
  Future<int> cancel() async {
    shouldAbortQueuingTasks = true;
    if (!_queueCancellation.isCompleted) {
      _queueCancellation.complete();
    }

    final owned = [
      ...await _uploadRepository.getActiveTasks(kBackupGroup),
      ...await _uploadRepository.getActiveTasks(kBackupLivePhotoGroup),
    ].whereType<UploadTask>().toList();
    await _uploadRepository.reset(kBackupGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupGroup);
    await _uploadRepository.reset(kBackupLivePhotoGroup);
    await _uploadRepository.deleteDatabaseRecords(kBackupLivePhotoGroup);

    for (final task in owned) {
      await _discardOwnedTask(task);
    }
    final activeTasks = await _uploadRepository.getActiveTasks(kBackupGroup);
    return activeTasks.length;
  }

  /// Resume background backup processing
  Future<void> resume() async {
    await _uploadRepository.start();
    final user = Store.tryGet(StoreKey.currentUser);
    if (user != null) {
      await uploadBackupCandidates(user.id);
    }
  }

  @visibleForTesting
  Future<void> handleTaskStatusUpdate(TaskStatusUpdate update) async {
    UploadTaskMetadata? metadata;
    try {
      if (update.task.metaData.isNotEmpty) {
        metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      }
    } catch (error) {
      _logger.warning('Ignoring obsolete upload metadata', error);
      return;
    }
    if (metadata?.componentRole == UploadComponentRole.rawCompanion ||
        metadata?.componentRole == UploadComponentRole.rawPairProcessed) {
      await _handleRawPairUpload(update, metadata!);
      return;
    }
    if (!_taskStatusController.isClosed) {
      _taskStatusController.add(update);
    }
    switch (update.status) {
      case TaskStatus.complete:
        unawaited(_handleLivePhoto(update));
        unawaited(_stackEditedAsset(update));

        if (CurrentPlatform.isIOS) {
          try {
            final path = await update.task.filePath();
            await File(path).delete();
          } catch (e) {
            _logger.severe('Error deleting file path for iOS: $e');
          }
        }

      default:
        break;
    }
  }

  Future<void> _handleLivePhoto(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.task.metaData == '') {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      if (!metadata.isLivePhotos) {
        return;
      }

      if (update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }
      final response = jsonDecode(update.responseBody!);

      final localAsset = await _localAssetRepository.getById(metadata.localAssetId);
      if (localAsset == null) {
        return;
      }

      final uploadTask = await getLivePhotoUploadTask(localAsset, response['id'] as String);

      if (uploadTask == null) {
        return;
      }

      await enqueueTasks([uploadTask]);
    } catch (error, stackTrace) {
      dPrint(() => "Error handling live photo upload task: $error $stackTrace");
    }
  }

  Future<void> _stackEditedAsset(TaskStatusUpdate update) async {
    try {
      if (update.task.metaData.isEmpty || update.responseBody == null || update.responseBody!.isEmpty) {
        return;
      }

      final metadata = UploadTaskMetadata.fromJson(update.task.metaData);
      // The video half of a live photo carries isLivePhotos; the still that follows is the final asset
      if (metadata.isLivePhotos) {
        return;
      }

      await _assetService.stackEditedUpload(
        metadata.localAssetId,
        jsonDecode(update.responseBody!)['id'] as String,
        metadata.checksum,
      );
    } catch (error, stackTrace) {
      dPrint(() => "Error stacking edited asset upload: $error $stackTrace");
    }
  }

  @visibleForTesting
  Future<UploadTask?> getUploadTask(LocalAsset asset, {String group = kBackupGroup, int? priority}) async {
    if (CurrentPlatform.isIOS && asset.type == AssetType.image) {
      final prepared = await _assetService.prepareRawJpegPair(
        asset,
        allowNetworkAccess: await _allowResourceNetwork(asset),
        cancelToken: _queueCancellation,
      );
      if (prepared.rawPairDiscovery == RawPairDiscovery.present) {
        return _nextRawPairTask(prepared);
      }
    }
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      _logger.warning("Asset entity not found for ${asset.id} - ${asset.name}");
      return null;
    }

    File? file;

    /// iOS LivePhoto has two files: a photo and a video.
    /// They are uploaded separately, with video file being upload first, then returned with the assetId
    /// The assetId is then used as a metadata for the photo file upload task.
    ///
    /// We implement two separate upload groups for this, the normal one for the video file
    /// and the higher priority group for the photo file because the video file is already uploaded.

    if (entity.isLivePhoto) {
      file = await _storageRepository.getMotionFileForAsset(asset);
    } else {
      file = await _storageRepository.getFileForAsset(asset.id);
    }

    if (file == null) {
      _logger.warning("Failed to get file for asset ${asset.id} - ${asset.name}");
      return null;
    }

    final fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;
    // Some apps (e.g. DJI/Fusion) return names without an extension; fall back to the asset name for those.
    final extension = p.extension(file.path).isNotEmpty ? p.extension(file.path) : p.extension(asset.name);
    final originalFileName = p.setExtension(fileName, extension);

    final String metadata = UploadTaskMetadata(
      localAssetId: asset.id,
      componentRole: entity.isLivePhoto ? UploadComponentRole.livePhotoVideo : UploadComponentRole.regular,
      isLivePhotos: entity.isLivePhoto,
      livePhotoVideoId: '',
      checksum: asset.checksum,
    ).toJson();

    final requiresWiFi = _shouldRequireWiFi(asset);

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: metadata,
      group: group,
      priority: priority,
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      // Visibility hidden on upload to prevent the server from running regular jobs on the live photo asset
      fields: entity.isLivePhoto ? {'visibility': api.AssetVisibility.hidden.toString()} : null,
      cloudId: entity.isLivePhoto ? null : asset.cloudId,
      adjustmentTime: entity.isLivePhoto ? null : asset.adjustmentTime?.toIso8601String(),
      latitude: entity.isLivePhoto ? null : asset.latitude?.toString(),
      longitude: entity.isLivePhoto ? null : asset.longitude?.toString(),
    );
  }

  @visibleForTesting
  Future<UploadTask?> getLivePhotoUploadTask(LocalAsset asset, String livePhotoVideoId) async {
    final entity = await _storageRepository.getAssetEntityForAsset(asset);
    if (entity == null) {
      return null;
    }

    final file = await _storageRepository.getFileForAsset(asset.id);
    if (file == null) {
      return null;
    }

    final fields = {'livePhotoVideoId': livePhotoVideoId};

    final requiresWiFi = _shouldRequireWiFi(asset);
    final originalFileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

    return buildUploadTask(
      file,
      createdAt: asset.createdAt,
      modifiedAt: asset.updatedAt,
      originalFileName: originalFileName,
      deviceAssetId: asset.id,
      metadata: UploadTaskMetadata(
        localAssetId: asset.id,
        componentRole: UploadComponentRole.regular,
        isLivePhotos: false,
        livePhotoVideoId: livePhotoVideoId,
        checksum: asset.checksum,
      ).toJson(),
      fields: fields,
      group: kBackupLivePhotoGroup,
      priority: 0, // Highest priority to get upload immediately
      isFavorite: asset.isFavorite,
      requiresWiFi: requiresWiFi,
      cloudId: asset.cloudId,
      adjustmentTime: asset.adjustmentTime?.toIso8601String(),
      latitude: asset.latitude?.toString(),
      longitude: asset.longitude?.toString(),
    );
  }

  static final _buildingRawTasks = <String>{};
  static final _rawCallbacks = <String, Future<void>>{};

  Future<bool> _allowResourceNetwork(LocalAsset asset) async =>
      !_shouldRequireWiFi(asset) || (await _connectivityApi.getCapabilities()).isUnmetered;

  RawPairReceipt _metadataScope(UploadTaskMetadata metadata) =>
      RawPairReceipt(serverEndpoint: metadata.serverEndpoint!, ownerId: metadata.ownerId!, pairKey: metadata.pairKey!);

  String _rawQueueId(LocalAsset asset, RawPairReceipt scope, PhotoResourceRole role) =>
      'raw-pair-${sha256.convert(utf8.encode(jsonEncode([scope.serverEndpoint, scope.ownerId, asset.id, scope.pairKey, role.name])))}';

  Future<void> _deleteOwnedTaskFile(Task task) async {
    try {
      await File(await task.filePath()).delete();
    } catch (error) {
      _logger.fine('Resource export already removed', error);
    }
  }

  Future<Set<String>> _reconcileActiveTasks() async {
    final ordinary = <String>{};
    for (final group in [kBackupGroup, kBackupLivePhotoGroup]) {
      for (final task in await _uploadRepository.getActiveTasks(group)) {
        var current = false;
        try {
          final metadata = UploadTaskMetadata.fromJson(task.metaData);
          if (metadata.componentRole == UploadComponentRole.rawCompanion ||
              metadata.componentRole == UploadComponentRole.rawPairProcessed) {
            final asset = await _localAssetRepository.getById(metadata.localAssetId);
            current =
                await _localAssetRepository.isRawPairScopeCurrent(_metadataScope(metadata)) &&
                asset?.rawJpegPair?.pairKey == metadata.pairKey;
          } else {
            current = true;
            ordinary.add(metadata.localAssetId);
          }
        } catch (_) {
          /* Rebuild pre-change queue metadata rather than interpreting it. */
        }
        if (!current && await _uploadRepository.cancelTasks([task.taskId])) {
          await _deleteOwnedTaskFile(task);
        }
      }
    }
    return ordinary;
  }

  Future<UploadTask?> _nextRawPairTask(LocalAsset asset, {Task? completedTask, RawPairReceipt? expectedScope}) async {
    final scope = expectedScope ?? await _localAssetRepository.getRawPairScope(asset.rawJpegPair!.pairKey);
    final ids = await _assetService.resolveRawPairRemoteIds(asset, expectedScope: scope);
    ids.requireNoTrash();
    if (ids.rawId != null && ids.jpegId != null) {
      final current = await _localAssetRepository.getById(asset.id);
      final receipt = current?.rawPairReceipt;
      if (receipt?.completed == true &&
          receipt?.serverEndpoint == scope.serverEndpoint &&
          receipt?.ownerId == scope.ownerId &&
          receipt?.pairKey == scope.pairKey &&
          receipt?.rawId == ids.rawId &&
          receipt?.jpegId == ids.jpegId) {
        return null;
      }
      await _assetService.finalizeRawJpegPair(asset, jpegId: ids.jpegId!, rawId: ids.rawId!, expectedScope: scope);
      if (completedTask != null && !_taskStatusController.isClosed) {
        _taskStatusController.add(
          TaskStatusUpdate(completedTask, TaskStatus.complete, null, jsonEncode({'id': ids.jpegId})),
        );
      }
      return null;
    }
    return getRawPairUploadTask(
      asset,
      role: ids.rawId == null ? PhotoResourceRole.raw : PhotoResourceRole.processed,
      rawAssetId: ids.rawId,
      expectedScope: scope,
    );
  }

  Future<void> _discardOwnedTask(UploadTask task) async {
    final metadata = UploadTaskMetadata.fromJson(task.metaData);
    if (metadata.taskClaim == null) {
      return;
    }
    // An enqueue can have succeeded even when its response was lost.
    final active = await _uploadRepository.getTask(task.taskId);
    if (active != null && await active.filePath() == await task.filePath()) {
      return;
    }
    final role = metadata.componentRole == UploadComponentRole.rawCompanion
        ? PhotoResourceRole.raw
        : PhotoResourceRole.processed;
    await _localAssetRepository.releaseRawPairTaskClaim(
      metadata.localAssetId,
      _metadataScope(metadata),
      role,
      metadata.taskClaim!,
    );
    await _deleteOwnedTaskFile(task);
  }

  Future<void> _enqueueOwnedTasks(List<UploadTask> tasks) async {
    try {
      final accepted = await enqueueTasks(tasks);
      for (var i = 0; i < tasks.length; i++) {
        if (i >= accepted.length || !accepted[i]) {
          await _discardOwnedTask(tasks[i]);
        }
      }
    } catch (_) {
      for (final task in tasks) {
        await _discardOwnedTask(task);
      }
      rethrow;
    }
  }

  @visibleForTesting
  Future<UploadTask?> getRawPairUploadTask(
    LocalAsset asset, {
    required PhotoResourceRole role,
    String? rawAssetId,
    RawPairReceipt? expectedScope,
  }) async {
    final pair = asset.rawJpegPair!;
    final scope = expectedScope ?? await _localAssetRepository.getRawPairScope(pair.pairKey);
    final taskId = _rawQueueId(asset, scope, role);
    if (!_buildingRawTasks.add(taskId)) {
      return null;
    }
    String? claim;
    File? export;
    var handedOff = false;
    try {
      final ids = await _assetService.resolveRawPairRemoteIds(asset, expectedScope: scope);
      ids.requireNoTrash();
      if (role == PhotoResourceRole.raw ? ids.rawId != null : ids.jpegId != null) {
        return null;
      }
      if (role == PhotoResourceRole.processed &&
          (ids.rawId == null || (rawAssetId != null && ids.rawId != rawAssetId))) {
        throw StateError('RAW must be confirmed before queueing the processed resource');
      }
      if (await _uploadRepository.getTask(taskId) != null) {
        return null;
      }
      final current = await _localAssetRepository.getById(asset.id);
      final oldClaim = role == PhotoResourceRole.raw
          ? current?.rawPairReceipt?.rawTaskId
          : current?.rawPairReceipt?.jpegTaskId;
      if (oldClaim != null) {
        final record = await _uploadRepository.getTaskRecord(taskId);
        if (await _uploadRepository.getTask(taskId) != null) {
          return null;
        }
        await _localAssetRepository.releaseRawPairTaskClaim(asset.id, scope, role, oldClaim);
        if (record?.status.isFinalState == true) {
          await _deleteOwnedTaskFile(record!.task);
        }
      }
      claim = '$taskId:${const Uuid().v4()}';
      if (!await _localAssetRepository.claimRawPairTask(asset.id, scope, role, claim)) {
        return null;
      }
      export = await _storageRepository.exportPhotoResource(
        pair.request(role),
        allowNetworkAccess: await _allowResourceNetwork(asset),
        cancelToken: _queueCancellation,
      );
      final latest = await _localAssetRepository.getById(asset.id);
      final activeClaim = role == PhotoResourceRole.raw
          ? latest?.rawPairReceipt?.rawTaskId
          : latest?.rawPairReceipt?.jpegTaskId;
      if (shouldAbortQueuingTasks ||
          !await _localAssetRepository.isRawPairScopeCurrent(scope) ||
          latest?.rawJpegPair?.pairKey != pair.pairKey ||
          activeClaim != claim) {
        return null;
      }
      final resource = role == PhotoResourceRole.raw ? pair.rawOriginal : pair.processed;
      final task = await buildUploadTask(
        export,
        group: role == PhotoResourceRole.raw ? kBackupGroup : kBackupLivePhotoGroup,
        createdAt: asset.createdAt,
        modifiedAt: asset.updatedAt,
        originalFileName: resource.filename,
        deviceAssetId: taskId,
        priority: role == PhotoResourceRole.raw ? null : 0,
        metadata: UploadTaskMetadata(
          localAssetId: asset.id,
          isLivePhotos: false,
          livePhotoVideoId: '',
          componentRole: role == PhotoResourceRole.raw
              ? UploadComponentRole.rawCompanion
              : UploadComponentRole.rawPairProcessed,
          pairKey: pair.pairKey,
          serverEndpoint: scope.serverEndpoint,
          ownerId: scope.ownerId,
          taskClaim: claim,
          rawAssetId: ids.rawId,
          checksum: role == PhotoResourceRole.raw ? asset.rawChecksum : asset.checksum,
        ).toJson(),
        isFavorite: asset.isFavorite,
        requiresWiFi: _shouldRequireWiFi(asset),
        cloudId: role == PhotoResourceRole.processed ? asset.cloudId : null,
        adjustmentTime: role == PhotoResourceRole.processed ? asset.adjustmentTime?.toIso8601String() : null,
        latitude: role == PhotoResourceRole.processed ? asset.latitude?.toString() : null,
        longitude: role == PhotoResourceRole.processed ? asset.longitude?.toString() : null,
      );
      if (task.url != '${scope.serverEndpoint}/assets') {
        throw StateError('Backup endpoint changed while building task');
      }
      handedOff = true;
      return task;
    } finally {
      _buildingRawTasks.remove(taskId);
      if (!handedOff) {
        if (claim != null) {
          await _localAssetRepository.releaseRawPairTaskClaim(asset.id, scope, role, claim);
        }
        if (export != null) {
          try {
            await export.delete();
          } catch (_) {}
        }
      }
    }
  }

  Future<void> _handleRawPairUpload(TaskStatusUpdate update, UploadTaskMetadata metadata) async {
    if (!update.status.isFinalState) {
      if (!_taskStatusController.isClosed) {
        _taskStatusController.add(update);
      }
      return;
    }
    final previous = _rawCallbacks[metadata.localAssetId];
    final done = Completer<void>();
    _rawCallbacks[metadata.localAssetId] = done.future;
    await previous;
    try {
      final scope = _metadataScope(metadata);
      final role = metadata.componentRole == UploadComponentRole.rawCompanion
          ? PhotoResourceRole.raw
          : PhotoResourceRole.processed;
      final asset = await _localAssetRepository.getById(metadata.localAssetId);
      final claim = role == PhotoResourceRole.raw
          ? asset?.rawPairReceipt?.rawTaskId
          : asset?.rawPairReceipt?.jpegTaskId;
      if (metadata.taskClaim == null ||
          claim != metadata.taskClaim ||
          asset?.rawPairDiscovery != RawPairDiscovery.present ||
          asset?.rawJpegPair?.pairKey != metadata.pairKey ||
          !await _localAssetRepository.isRawPairScopeCurrent(scope) ||
          update.task.taskId != _rawQueueId(asset!, scope, role) ||
          update.task.url != '${scope.serverEndpoint}/assets' ||
          (role == PhotoResourceRole.raw ? asset.rawChecksum : asset.checksum) != metadata.checksum) {
        return;
      }
      try {
        if (update.status != TaskStatus.complete) {
          if (!_taskStatusController.isClosed) {
            _taskStatusController.add(update);
          }
          return;
        }
        final proof = await _storageRepository.getRawJpegPair(asset.id);
        if (proof?.pairKey != scope.pairKey) {
          await _localAssetRepository.markRawPairDiscoveryUnknown(asset.id);
          return;
        }
        final id = (jsonDecode(update.responseBody!) as Map<String, dynamic>)['id'] as String;
        await _assetService.recordRawPairUpload(asset, role: role, remoteId: id, expectedScope: scope);
        await _localAssetRepository.releaseRawPairTaskClaim(asset.id, scope, role, metadata.taskClaim!);
        final task = await _nextRawPairTask(
          (await _localAssetRepository.getById(asset.id))!.copyWith(cloudId: asset.cloudId),
          completedTask: update.task,
          expectedScope: scope,
        );
        if (task != null) {
          await _enqueueOwnedTasks([task]);
        }
      } finally {
        await _localAssetRepository.releaseRawPairTaskClaim(asset.id, scope, role, metadata.taskClaim!);
      }
    } catch (error, stack) {
      _logger.warning('Cannot advance RAW pair backup', error, stack);
      if (!_taskStatusController.isClosed) {
        _taskStatusController.add(TaskStatusUpdate(update.task, TaskStatus.failed, TaskException(error.toString())));
      }
    } finally {
      await _deleteOwnedTaskFile(update.task);
      done.complete();
      if (identical(_rawCallbacks[metadata.localAssetId], done.future)) {
        unawaited(_rawCallbacks.remove(metadata.localAssetId));
      }
    }
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    final backup = SettingsRepository.instance.appConfig.backup;
    if (asset.isVideo && backup.useCellularForVideos) {
      return false;
    }
    if (!asset.isVideo && backup.useCellularForPhotos) {
      return false;
    }
    return true;
  }

  Future<UploadTask> buildUploadTask(
    File file, {
    required String group,
    required DateTime createdAt,
    required DateTime modifiedAt,
    Map<String, String>? fields,
    String? originalFileName,
    String? deviceAssetId,
    String? metadata,
    int? priority,
    bool? isFavorite,
    bool requiresWiFi = true,
    String? cloudId,
    String? adjustmentTime,
    String? latitude,
    String? longitude,
  }) async {
    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final url = Uri.parse('$serverEndpoint/assets').toString();
    final headers = ApiService.getRequestHeaders();
    final deviceId = Store.get(StoreKey.deviceId);
    final (baseDirectory, directory, filename) = await Task.split(filePath: file.path);
    final fieldsMap = {
      'filename': originalFileName ?? filename,
      // deviceAssetId/deviceId required by server v2.7.5 and below (drop in v4.0 per #27818).
      'deviceAssetId': deviceAssetId ?? '',
      'deviceId': deviceId,
      'fileCreatedAt': createdAt.toUtc().toIso8601String(),
      'fileModifiedAt': modifiedAt.toUtc().toIso8601String(),
      'isFavorite': isFavorite?.toString() ?? 'false',
      'duration': '0',
      ...?fields,
      if (CurrentPlatform.isIOS && cloudId != null)
        'metadata': jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: cloudId,
              createdAt: createdAt.toIso8601String(),
              adjustmentTime: adjustmentTime,
              latitude: latitude,
              longitude: longitude,
            ),
          ),
        ]),
    };

    return UploadTask(
      taskId: deviceAssetId,
      displayName: originalFileName ?? filename,
      httpRequestMethod: 'POST',
      url: url,
      headers: headers,
      filename: filename,
      fields: fieldsMap,
      baseDirectory: baseDirectory,
      directory: directory,
      fileField: 'assetData',
      metaData: metadata ?? '',
      group: group,
      requiresWiFi: requiresWiFi,
      priority: priority ?? 5,
      updates: Updates.statusAndProgress,
      retries: 3,
    );
  }
}
