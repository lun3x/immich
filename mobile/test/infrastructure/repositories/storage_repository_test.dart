import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:mocktail/mocktail.dart';

class MockNativeSyncApi extends Mock implements NativeSyncApi {}

void main() {
  late MockNativeSyncApi native;
  late StorageRepository sut;
  final jpeg = PlatformPhotoResource(
    key: 'jpeg',
    type: 1,
    filename: 'camera.JPG',
    uniformTypeIdentifier: 'public.jpeg',
  );
  final raw = PlatformPhotoResource(
    key: 'raw',
    type: 4,
    filename: 'camera.RAF',
    uniformTypeIdentifier: 'com.fuji.raw-image',
  );
  final request = PhotoResourceRequest(assetId: 'local', pairKey: 'pair-1', resource: raw);

  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(request);
  });

  setUp(() {
    native = MockNativeSyncApi();
    sut = StorageRepository(native);
  });

  test('discovers original pair metadata without exporting resource bytes', () async {
    when(() => native.getRawJpegPairs(['local'])).thenAnswer(
      (_) async => [
        RawJpegPairResult(
          assetId: 'local',
          pair: PlatformRawJpegPair(
            assetId: 'local',
            pairKey: 'pair-1',
            jpegOriginal: jpeg,
            rawOriginal: raw,
            processed: jpeg,
          ),
        ),
      ],
    );

    final pair = await sut.getRawJpegPair('local');

    expect(pair?.assetId, 'local');
    expect(pair?.rawOriginal.filename, 'camera.RAF');
    expect(pair?.processed.filename, 'camera.JPG');
    verifyNever(() => native.exportPhotoResource(any(), any(), allowNetworkAccess: any(named: 'allowNetworkAccess')));
  });

  test('keeps failed discovery distinct from absence', () async {
    when(
      () => native.getRawJpegPairs(['local']),
    ).thenAnswer((_) async => [RawJpegPairResult(assetId: 'local', error: 'Ambiguous originals')]);
    await expectLater(sut.getRawJpegPair('local'), throwsA(isA<StateError>()));
  });

  test('returns absence only for a successful no-pair result', () async {
    when(() => native.getRawJpegPairs(['local'])).thenAnswer((_) async => [RawJpegPairResult(assetId: 'local')]);
    expect(await sut.getRawJpegPair('local'), isNull);
  });

  test('rejects a discovery result for another parent', () async {
    when(() => native.getRawJpegPairs(['local'])).thenAnswer((_) async => [RawJpegPairResult(assetId: 'other')]);
    await expectLater(sut.getRawJpegPair('local'), throwsA(isA<StateError>()));
  });

  test('exports exact RAW bytes to a unique path retaining the original extension', () async {
    final paths = <String>[];
    when(() => native.exportPhotoResource(any(), any(), allowNetworkAccess: false)).thenAnswer((call) async {
      final actual = call.positionalArguments[0] as PhotoResourceRequest;
      expect(actual.assetId, 'local');
      expect(actual.pairKey, 'pair-1');
      expect(actual.resource.key, 'raw');
      final path = call.positionalArguments[1] as String;
      paths.add(path);
      await File(path).writeAsBytes([0, 1, 2, 255]);
      return path;
    });

    final first = await sut.exportPhotoResource(request, allowNetworkAccess: false);
    final second = await sut.exportPhotoResource(request, allowNetworkAccess: false);
    try {
      expect(await first.readAsBytes(), [0, 1, 2, 255]);
      expect(first.path.endsWith('.RAF'), isTrue);
      expect(paths.toSet(), hasLength(2));
    } finally {
      await first.parent.delete(recursive: true);
      await second.parent.delete(recursive: true);
    }
  });

  test('cancels the owning export and deletes its partial file', () async {
    final started = Completer<String>();
    final finished = Completer<String>();
    final cancellation = Completer<void>();
    when(() => native.exportPhotoResource(any(), any(), allowNetworkAccess: true)).thenAnswer((call) async {
      final path = call.positionalArguments[1] as String;
      await File(path).writeAsBytes([1, 2]);
      started.complete(path);
      return finished.future;
    });
    when(() => native.cancelPhotoResourceExport(any())).thenAnswer((call) async {
      expect(call.positionalArguments[0], await started.future);
      finished.completeError(PlatformException(code: 'EXPORT_CANCELLED'));
    });

    final future = sut.exportPhotoResource(request, allowNetworkAccess: true, cancelToken: cancellation);
    final assertion = expectLater(future, throwsA(isA<PlatformException>()));
    final path = await started.future;
    cancellation.complete();
    await assertion;
    expect(File(path).existsSync(), isFalse);
  });

  test('cancels only its in-flight resource hash and returns without waiting for PhotoKit', () async {
    final started = Completer<String>();
    final pending = Completer<List<PhotoResourceHashResult>>();
    final cancellation = Completer<void>();
    when(() => native.hashPhotoResources(any(), any(), allowNetworkAccess: true)).thenAnswer((call) {
      started.complete(call.positionalArguments[1] as String);
      return pending.future;
    });
    when(() => native.cancelPhotoResourceHashing(any())).thenAnswer((_) async {});

    final future = sut.hashPhotoResources([request], allowNetworkAccess: true, cancelToken: cancellation);
    final assertion = expectLater(
      future,
      throwsA(isA<PlatformException>().having((e) => e.code, 'code', 'HASH_CANCELLED')),
    );
    final operation = await started.future;
    cancellation.complete();
    await assertion.timeout(const Duration(seconds: 1));

    verify(() => native.cancelPhotoResourceHashing(operation)).called(1);
    verifyNever(native.cancelHashing);
    pending.completeError(PlatformException(code: 'HASH_CANCELLED'));
  });

  test('finished resource hash ignores later cancellation', () async {
    final cancellation = Completer<void>();
    when(() => native.hashPhotoResources(any(), any(), allowNetworkAccess: false)).thenAnswer((_) async => []);
    await sut.hashPhotoResources([request], allowNetworkAccess: false, cancelToken: cancellation);
    cancellation.complete();
    await Future<void>.delayed(Duration.zero);
    verifyNever(() => native.cancelPhotoResourceHashing(any()));
  });

  test('serialized original evidence retains all resource identities', () {
    final pair = RawJpegPair(
      assetId: 'local',
      pairKey: 'pair-1',
      jpegOriginal: PhotoResource.fromPlatform(jpeg),
      rawOriginal: PhotoResource.fromPlatform(raw),
      processed: PhotoResource.fromPlatform(jpeg),
    );
    final restored = RawJpegPair.fromMap(pair.toMap());
    expect(restored.assetId, 'local');
    expect(restored.pairKey, 'pair-1');
    expect(restored.rawOriginal.uniformTypeIdentifier, 'com.fuji.raw-image');
    expect(restored.jpegOriginal.type, 1);
  });
}
