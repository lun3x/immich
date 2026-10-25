import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart' hide AssetEditAction;
import 'package:immich_mobile/domain/models/stack.model.dart';
import 'package:immich_mobile/domain/models/tag.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/repositories/api.repository.dart';
import 'package:immich_mobile/utils/option.dart';
import 'package:maplibre_gl/maplibre_gl.dart';
import 'package:openapi/api.dart' as api show AssetVisibility;
import 'package:openapi/api.dart' hide AssetVisibility;

final assetApiRepositoryProvider = Provider(
  (ref) => AssetApiRepository(
    ref.watch(apiServiceProvider).assetsApi,
    ref.watch(apiServiceProvider).stacksApi,
    ref.watch(apiServiceProvider).trashApi,
  ),
);

class AssetApiRepository extends ApiRepository {
  final AssetsApi _api;
  final StacksApi _stacksApi;
  final TrashApi _trashApi;

  AssetApiRepository(this._api, this._stacksApi, this._trashApi);

  Future<void> delete(List<String> ids, bool force) async {
    return _api.deleteAssets(AssetBulkDeleteDto(ids: ids, force: Optional.present(force)));
  }

  Future<void> restoreTrash(List<String> ids) async {
    await _trashApi.restoreAssets(BulkIdsDto(ids: ids));
  }

  Future<int> emptyTrash() async {
    final response = await _trashApi.emptyTrash();
    return response?.count ?? 0;
  }

  Future<int> restoreAllTrash() async {
    final response = await _trashApi.restoreTrash();
    return response?.count ?? 0;
  }

  Future<Map<String, ({String? assetId, bool isTrashed})>> checkUploadChecksums(Map<String, String> checksums) async {
    if (checksums.isEmpty) {
      return {};
    }
    final response = await checkNull(
      _api.checkBulkUpload(
        AssetBulkUploadCheckDto(
          assets: [
            for (final entry in checksums.entries) AssetBulkUploadCheckItem(id: entry.key, checksum: entry.value),
          ],
        ),
      ),
    );
    final result = <String, ({String? assetId, bool isTrashed})>{};
    for (final item in response.results) {
      if (!checksums.containsKey(item.id) || result.containsKey(item.id)) {
        throw StateError('Invalid checksum check response');
      }
      if (item.action == AssetUploadAction.accept) {
        result[item.id] = (assetId: null, isTrashed: false);
      } else {
        final id = item.assetId.orElse(null);
        final trashed = item.isTrashed.orElse(null);
        if (id == null || trashed == null || item.reason.orElse(null) == AssetRejectReason.unsupportedFormat) {
          throw StateError('Cannot establish server resource presence');
        }
        result[item.id] = (assetId: id, isTrashed: trashed);
      }
    }
    if (result.length != checksums.length) {
      throw StateError('Incomplete checksum check response');
    }
    return result;
  }

  Future<StackResponse> stackWithoutMerging(String jpegId, String rawId) async {
    return (await checkNull(
      _stacksApi.createStack(StackCreateDto(assetIds: [jpegId, rawId], allowMerge: const Optional.present(false))),
    )).toStack();
  }

  Future<StackResponse> stack(List<String> ids) async {
    final responseDto = await checkNull(_stacksApi.createStack(StackCreateDto(assetIds: ids)));

    return responseDto.toStack();
  }

  Future<void> unStack(List<String> ids) async {
    return _stacksApi.deleteStacks(BulkIdsDto(ids: ids));
  }

  api.AssetVisibility _mapVisibility(AssetVisibility visibility) => switch (visibility) {
    AssetVisibility.timeline => api.AssetVisibility.timeline,
    AssetVisibility.hidden => api.AssetVisibility.hidden,
    AssetVisibility.locked => api.AssetVisibility.locked,
    AssetVisibility.archive => api.AssetVisibility.archive,
  };

  Future<String?> getAssetMIMEType(String assetId) async {
    final response = await checkNull(_api.getAssetInfo(assetId));

    // we need to get the MIME of the thumbnail once that gets added to the API
    return response.originalMimeType.orElse(null);
  }

  Future<List<Tag>> getAssetTags(String assetId) async {
    final response = await checkNull(_api.getAssetInfo(assetId));
    return response.tags.orElse(null)?.map((tag) => Tag(id: tag.id, value: tag.value)).toList() ?? const [];
  }

  Future<String> getChecksum(String id) async {
    return (await checkNull(_api.getAssetInfo(id))).checksum;
  }

  Future<void> updateDescription(String assetId, String description) {
    return _api.updateAsset(assetId, UpdateAssetDto(description: Optional.present(description)));
  }

  Future<void> updateRating(String assetId, int? rating) {
    return _api.updateAsset(assetId, UpdateAssetDto(rating: Optional.present(rating)));
  }

  Future<AssetEditsResponseDto?> editAsset(String assetId, List<AssetEdit> edits) {
    return _api.editAsset(assetId, AssetEditsCreateDto(edits: edits.map((e) => e.toApi()).toList()));
  }

  Future<void> removeEdits(String assetId) async {
    return _api.removeAssetEdits(assetId);
  }

  Future<void> update(
    List<String> remoteIds, {
    Option<bool> isFavorite = const .none(),
    Option<AssetVisibility> visibility = const .none(),
    Option<String> dateTimeOriginal = const .none(),
    Option<LatLng> location = const .none(),
  }) {
    return _api.updateAssets(
      AssetBulkUpdateDto(
        ids: remoteIds,
        isFavorite: isFavorite.toOptional(),
        visibility: visibility.map(_mapVisibility).toOptional(),
        dateTimeOriginal: dateTimeOriginal.toOptional(),
        latitude: location.map((loc) => loc.latitude).toOptional(),
        longitude: location.map((loc) => loc.longitude).toOptional(),
      ),
    );
  }
}

extension on StackResponseDto {
  StackResponse toStack() {
    return StackResponse(id: id, primaryAssetId: primaryAssetId, assetIds: assets.map((asset) => asset.id).toList());
  }
}

extension on AssetEdit {
  AssetEditActionItemDto toApi() {
    return switch (this) {
      CropEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.crop,
        parameters: parameters.toJson(),
      ),
      RotateEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.rotate,
        parameters: parameters.toJson(),
      ),
      MirrorEdit(:final parameters) => AssetEditActionItemDto(
        action: AssetEditAction.mirror,
        parameters: parameters.toJson(),
      ),
    };
  }
}
