import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart';
import 'package:uuid/uuid.dart';

// ignore_for_file: avoid_slow_async_io

class StorageRepository {
  final log = Logger('StorageRepository');

  final NativeSyncApi _nativeSyncApi;

  StorageRepository(this._nativeSyncApi);

  Future<RawJpegPair?> getRawJpegPair(String assetId) async {
    final results = await _nativeSyncApi.getRawJpegPairs([assetId]);
    if (results.length != 1 || results.single.assetId != assetId) {
      throw StateError('Invalid original-resource discovery result for $assetId');
    }
    final result = results.single;
    if (result.error != null) {
      throw StateError(result.error!);
    }
    final pair = result.pair;
    if (pair != null && pair.assetId != assetId) {
      throw StateError('Original resources belong to another Photos item');
    }
    return pair == null ? null : RawJpegPair.fromPlatform(pair);
  }

  Future<List<PhotoResourceHashResult>> hashPhotoResources(
    List<PhotoResourceRequest> requests, {
    required bool allowNetworkAccess,
    Completer<void>? cancelToken,
  }) async {
    if (cancelToken?.isCompleted == true) {
      throw PlatformException(code: 'HASH_CANCELLED');
    }
    final operationId = const Uuid().v4();
    var finished = false;
    // Send the hash request first: its host handler registers ownership before
    // starting the PhotoKit read, including cancellation before request-ID assignment.
    final hashing = _nativeSyncApi.hashPhotoResources(requests, operationId, allowNetworkAccess: allowNetworkAccess);
    final cancellation = cancelToken?.future.then<List<PhotoResourceHashResult>>((_) async {
      if (!finished) {
        try {
          await _nativeSyncApi.cancelPhotoResourceHashing(operationId);
        } catch (error, stack) {
          log.warning('Failed to cancel photo resource hashing', error, stack);
        }
      }
      throw PlatformException(code: 'HASH_CANCELLED');
    });
    try {
      final results = await Future.any([hashing, ?cancellation]);
      if (cancelToken?.isCompleted == true) {
        throw PlatformException(code: 'HASH_CANCELLED');
      }
      return results;
    } finally {
      finished = true;
    }
  }

  Future<File> exportPhotoResource(
    PhotoResourceRequest request, {
    required bool allowNetworkAccess,
    Completer<void>? cancelToken,
  }) async {
    if (cancelToken?.isCompleted == true) {
      throw PlatformException(code: 'EXPORT_CANCELLED');
    }
    final directory = await Directory.systemTemp.createTemp('immich-raw-pair-');
    final destination = p.join(directory.path, p.basename(request.resource.filename));
    var finished = false;
    unawaited(
      cancelToken?.future
          .then((_) async {
            if (!finished) {
              await _nativeSyncApi.cancelPhotoResourceExport(destination);
            }
          })
          .catchError((Object error, StackTrace stack) {
            log.warning('Failed to cancel photo resource export', error, stack);
          }),
    );
    try {
      final path = await _nativeSyncApi.exportPhotoResource(
        request,
        destination,
        allowNetworkAccess: allowNetworkAccess,
      );
      if (cancelToken?.isCompleted == true) {
        throw PlatformException(code: 'EXPORT_CANCELLED');
      }
      final file = File(destination);
      if (path != destination || !await file.exists()) {
        throw StateError('Photo resource export did not produce its requested file');
      }
      return file;
    } catch (_) {
      await directory.delete(recursive: true);
      rethrow;
    } finally {
      finished = true;
    }
  }

  Future<File?> getFileForAsset(String assetId) async {
    File? file;
    final log = Logger('StorageRepository');

    try {
      final entity = await AssetEntity.fromId(assetId);
      file = await entity?.originFile;
      if (file == null) {
        log.warning("Cannot get file for asset $assetId");
        return null;
      }

      final exists = await file.exists();
      if (!exists) {
        log.warning("File for asset $assetId does not exist");
        return null;
      }
    } catch (error, stackTrace) {
      log.warning("Error getting file for asset $assetId", error, stackTrace);
    }
    return file;
  }

  // TODO(agg23): Unify these methods
  Future<File?> getMotionFileForAsset(LocalAsset asset) async {
    File? file;
    final log = Logger('StorageRepository');

    try {
      final entity = await AssetEntity.fromId(asset.id);
      file = await entity?.originFileWithSubtype;
      if (file == null) {
        log.warning(
          "Cannot get motion file for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        );
        return null;
      }

      final exists = await file.exists();
      if (!exists) {
        log.warning("Motion file for asset ${asset.id} does not exist");
        return null;
      }
    } catch (error, stackTrace) {
      log.warning(
        "Error getting motion file for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        error,
        stackTrace,
      );
    }
    return file;
  }

  Future<AssetEntity?> getAssetEntityForAsset(LocalAsset asset) async {
    final log = Logger('StorageRepository');

    AssetEntity? entity;

    try {
      entity = await AssetEntity.fromId(asset.id);
      if (entity == null) {
        log.warning(
          "Cannot get AssetEntity for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        );
      }
    } catch (error, stackTrace) {
      log.warning(
        "Error getting AssetEntity for asset ${asset.id}, name: ${asset.name}, created on: ${asset.createdAt}",
        error,
        stackTrace,
      );
    }
    return entity;
  }

  Future<bool> isAssetAvailableLocally(String assetId) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return false;
      }

      return await entity.isLocallyAvailable(isOrigin: true);
    } catch (error, stackTrace) {
      log.warning("Error checking if asset is locally available $assetId", error, stackTrace);
      return false;
    }
  }

  Future<File?> loadFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return null;
      }

      return await entity.loadFile(progressHandler: progressHandler);
    } catch (error, stackTrace) {
      log.warning("Error loading file from cloud for asset $assetId", error, stackTrace);
      return null;
    }
  }

  Future<File?> loadMotionFileFromCloud(String assetId, {PMProgressHandler? progressHandler}) async {
    try {
      final entity = await AssetEntity.fromId(assetId);
      if (entity == null) {
        log.warning("Cannot get AssetEntity for asset $assetId");
        return null;
      }

      return await entity.loadFile(withSubtype: true, progressHandler: progressHandler);
    } catch (error, stackTrace) {
      log.warning("Error loading motion file from cloud for asset $assetId", error, stackTrace);
      return null;
    }
  }

  Future<void> clearCache() async {
    // iOS cache files may still belong to persistent URLSession upload tasks.
    if (CurrentPlatform.isIOS) {
      return;
    }
    final log = Logger('StorageRepository');

    try {
      await PhotoManager.clearFileCache();
    } catch (error, stackTrace) {
      log.warning("Error clearing cache", error, stackTrace);
    }
  }
}
