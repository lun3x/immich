import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';

import '../../fixtures/raw_jpeg_pair.stub.dart';
import '../repository_context.dart';

void main() {
  late MediumRepositoryContext ctx;
  late LocalAssetRepository sut;
  late String id;
  final scope = rawReceipt('revision-1');
  setUp(() async {
    ctx = MediumRepositoryContext();
    sut = LocalAssetRepository(ctx.db);
    await ctx.newAuthUser(id: 'owner');
    await ctx.db.customStatement(
      "INSERT INTO store_entity (id, string_value) VALUES (2, 'owner'), (12, 'https://photos.example/api')",
    );
    id = (await ctx.newLocalAsset()).id;
    await sut.saveRawPairDiscovery(id, rawPair(assetId: id));
  });
  tearDown(() => ctx.dispose());
  test('one builder claims a component and a stale claimant cannot clear a replacement', () async {
    final results = await Future.wait([
      sut.claimRawPairTask(id, scope, PhotoResourceRole.raw, 'queue-id:attempt-1'),
      sut.claimRawPairTask(id, scope, PhotoResourceRole.raw, 'queue-id:attempt-2'),
    ]);
    expect(results.where((r) => r), hasLength(1));
    final first = (await sut.getById(id))!.rawPairReceipt!.rawTaskId!;
    await sut.releaseRawPairTaskClaim(id, scope, PhotoResourceRole.raw, first);
    expect(await sut.claimRawPairTask(id, scope, PhotoResourceRole.raw, 'queue-id:attempt-3'), isTrue);
    await sut.releaseRawPairTaskClaim(id, scope, PhotoResourceRole.raw, first);
    expect((await sut.getById(id))!.rawPairReceipt!.rawTaskId, 'queue-id:attempt-3');
  });
  test('a receipt update cannot clear a claim assigned after its snapshot', () async {
    await sut.saveRawPairReceipt(id, scope);
    expect(await sut.claimRawPairTask(id, scope, PhotoResourceRole.raw, 'new-attempt'), isTrue);
    await sut.saveRawPairReceipt(id, scope);
    expect((await sut.getById(id))!.rawPairReceipt!.rawTaskId, 'new-attempt');
  });

  test('old account and revision cannot claim work', () async {
    expect(await sut.claimRawPairTask(id, rawReceipt('old-revision'), PhotoResourceRole.raw, 'old'), isFalse);
    await ctx.db.customStatement("UPDATE store_entity SET string_value = 'new-owner' WHERE id = 2");
    expect(await sut.claimRawPairTask(id, scope, PhotoResourceRole.raw, 'old-owner'), isFalse);
  });
}
