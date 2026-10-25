import 'package:immich_mobile/platform/native_sync_api.g.dart';

enum PhotoResourceRole { processed, raw }

class PhotoResource {
  final String key;
  final int type;
  final String filename;
  final String uniformTypeIdentifier;

  const PhotoResource({
    required this.key,
    required this.type,
    required this.filename,
    required this.uniformTypeIdentifier,
  });

  factory PhotoResource.fromPlatform(PlatformPhotoResource value) => PhotoResource(
    key: value.key,
    type: value.type,
    filename: value.filename,
    uniformTypeIdentifier: value.uniformTypeIdentifier,
  );

  factory PhotoResource.fromMap(Map<String, dynamic> value) => PhotoResource(
    key: value['key'] as String,
    type: value['type'] as int,
    filename: value['filename'] as String,
    uniformTypeIdentifier: value['uniformTypeIdentifier'] as String,
  );

  Map<String, dynamic> toMap() => {
    'key': key,
    'type': type,
    'filename': filename,
    'uniformTypeIdentifier': uniformTypeIdentifier,
  };

  PlatformPhotoResource toPlatform() =>
      PlatformPhotoResource(key: key, type: type, filename: filename, uniformTypeIdentifier: uniformTypeIdentifier);
}

class RawJpegPair {
  final String assetId;
  final String pairKey;
  final PhotoResource jpegOriginal;
  final PhotoResource rawOriginal;
  final PhotoResource processed;

  const RawJpegPair({
    required this.assetId,
    required this.pairKey,
    required this.jpegOriginal,
    required this.rawOriginal,
    required this.processed,
  });

  factory RawJpegPair.fromPlatform(PlatformRawJpegPair pair) => RawJpegPair(
    assetId: pair.assetId,
    pairKey: pair.pairKey,
    jpegOriginal: PhotoResource.fromPlatform(pair.jpegOriginal),
    rawOriginal: PhotoResource.fromPlatform(pair.rawOriginal),
    processed: PhotoResource.fromPlatform(pair.processed),
  );

  factory RawJpegPair.fromMap(Map<String, dynamic> value) => RawJpegPair(
    assetId: value['assetId'] as String,
    pairKey: value['pairKey'] as String,
    jpegOriginal: PhotoResource.fromMap(value['jpegOriginal'] as Map<String, dynamic>),
    rawOriginal: PhotoResource.fromMap(value['rawOriginal'] as Map<String, dynamic>),
    processed: PhotoResource.fromMap(value['processed'] as Map<String, dynamic>),
  );

  Map<String, dynamic> toMap() => {
    'assetId': assetId,
    'pairKey': pairKey,
    'jpegOriginal': jpegOriginal.toMap(),
    'rawOriginal': rawOriginal.toMap(),
    'processed': processed.toMap(),
  };

  PhotoResourceRequest request(PhotoResourceRole role) => PhotoResourceRequest(
    assetId: assetId,
    pairKey: pairKey,
    resource: (role == PhotoResourceRole.raw ? rawOriginal : processed).toPlatform(),
  );
}
