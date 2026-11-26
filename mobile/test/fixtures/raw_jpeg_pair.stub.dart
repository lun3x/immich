import 'package:immich_mobile/domain/models/asset/raw_jpeg_pair.model.dart';

RawJpegPair rawPair({String assetId = 'pair', String pairKey = 'revision-1', String rawKey = 'raw'}) {
  const jpeg = PhotoResource(key: 'jpeg', type: 1, filename: 'IMG.JPG', uniformTypeIdentifier: 'public.jpeg');
  return RawJpegPair(
    assetId: assetId,
    pairKey: pairKey,
    jpegOriginal: jpeg,
    rawOriginal: PhotoResource(key: rawKey, type: 4, filename: 'IMG.RAF', uniformTypeIdentifier: 'com.fuji.raw-image'),
    processed: jpeg,
  );
}

RawPairReceipt rawReceipt(String pairKey, {bool completed = false}) => RawPairReceipt(
  serverEndpoint: 'https://photos.example/api',
  ownerId: 'owner',
  pairKey: pairKey,
  rawId: 'remote-raw',
  jpegId: 'remote-jpeg',
  completed: completed,
);
