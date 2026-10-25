import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/repositories/asset_api.repository.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _Assets extends Mock implements AssetsApi {}

class _Stacks extends Mock implements StacksApi {}

class _Trash extends Mock implements TrashApi {}

void main() {
  late _Assets assets;
  late _Stacks stacks;
  late AssetApiRepository sut;
  setUpAll(() {
    registerFallbackValue(StackCreateDto(assetIds: []));
    registerFallbackValue(AssetBulkUploadCheckDto());
  });
  setUp(() {
    assets = _Assets();
    stacks = _Stacks();
    sut = AssetApiRepository(assets, stacks, _Trash());
  });

  test('strict pair stack sends JPEG first and allowMerge false; normal stack stays unchanged', () async {
    when(
      () => stacks.createStack(any()),
    ).thenAnswer((_) async => StackResponseDto(id: 'stack', primaryAssetId: 'jpeg'));
    await sut.stackWithoutMerging('jpeg', 'raw');
    await sut.stack(['a', 'b']);
    final calls = verify(() => stacks.createStack(captureAny())).captured.cast<StackCreateDto>();
    expect(calls.first.assetIds, ['jpeg', 'raw']);
    expect(calls.first.allowMerge, const Optional<bool?>.present(false));
    expect(calls.last.allowMerge.isPresent, isFalse);
  });
  test('checksum checks preserve independent live and trashed results', () async {
    when(() => assets.checkBulkUpload(any())).thenAnswer(
      (_) async => AssetBulkUploadCheckResponseDto(
        results: [
          AssetBulkUploadCheckResult(
            id: 'raw',
            action: AssetUploadAction.reject,
            assetId: const Optional.present('raw-id'),
            isTrashed: const Optional.present(true),
          ),
          AssetBulkUploadCheckResult(
            id: 'jpeg',
            action: AssetUploadAction.reject,
            assetId: const Optional.present('jpeg-id'),
            isTrashed: const Optional.present(false),
          ),
        ],
      ),
    );
    final result = await sut.checkUploadChecksums({'jpeg': 'jpeg-hash', 'raw': 'raw-hash'});
    expect(result['jpeg'], (assetId: 'jpeg-id', isTrashed: false));
    expect(result['raw'], (assetId: 'raw-id', isTrashed: true));
    final request = verify(() => assets.checkBulkUpload(captureAny())).captured.single as AssetBulkUploadCheckDto;
    expect(request.assets, [
      AssetBulkUploadCheckItem(id: 'jpeg', checksum: 'jpeg-hash'),
      AssetBulkUploadCheckItem(id: 'raw', checksum: 'raw-hash'),
    ]);
  });
  test('missing response entries are errors instead of assumed absence', () async {
    when(() => assets.checkBulkUpload(any())).thenAnswer((_) async => AssetBulkUploadCheckResponseDto());
    await expectLater(sut.checkUploadChecksums({'raw': 'hash'}), throwsStateError);
  });
}
