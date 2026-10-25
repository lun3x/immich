import 'package:immich_mobile/platform/native_sync_api.g.dart';

enum RawPairDiscovery { unknown, absent, present }

class RawPairReceipt {
  final String serverEndpoint;
  final String ownerId;
  final String pairKey;
  final String? rawId;
  final String? jpegId;
  final String? rawTaskId;
  final String? jpegTaskId;
  final bool completed;

  const RawPairReceipt({
    required this.serverEndpoint,
    required this.ownerId,
    required this.pairKey,
    this.rawId,
    this.jpegId,
    this.rawTaskId,
    this.jpegTaskId,
    this.completed = false,
  });

  Object get _identity => (serverEndpoint, ownerId, pairKey, rawId, jpegId, rawTaskId, jpegTaskId, completed);
  @override
  bool operator ==(Object other) => other is RawPairReceipt && _identity == other._identity;
  @override
  int get hashCode => _identity.hashCode;
}

class RawPairRemoteIds {
  final String? jpegId;
  final String? rawId;
  final bool jpegTrashed;
  final bool rawTrashed;
  const RawPairRemoteIds({this.jpegId, this.rawId, this.jpegTrashed = false, this.rawTrashed = false});
  void requireNoTrash() {
    if (jpegTrashed || rawTrashed) {
      throw StateError(
        'A JPEG or RAW resource is in the server trash. Restore it or permanently delete it before retrying backup.',
      );
    }
  }
}

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

  @override
  bool operator ==(Object other) => other is RawJpegPair && assetId == other.assetId && pairKey == other.pairKey;
  @override
  int get hashCode => Object.hash(assetId, pairKey);

  PhotoResourceRequest request(PhotoResourceRole role) => PhotoResourceRequest(
    assetId: assetId,
    pairKey: pairKey,
    resource: (role == PhotoResourceRole.raw ? rawOriginal : processed).toPlatform(),
  );
}
