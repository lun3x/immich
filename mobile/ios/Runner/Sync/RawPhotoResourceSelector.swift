import Foundation
import CryptoKit
import UniformTypeIdentifiers

struct RawPhotoResourceDescriptor: Equatable {
  let assetId: String
  let key: String
  let type: Int
  let filename: String
  let uniformTypeIdentifier: String
  let isCurrent: Bool
}

struct RawPhotoResourceSelection {
  let assetId: String
  let pairKey: String
  let jpegOriginal: RawPhotoResourceDescriptor
  let rawOriginal: RawPhotoResourceDescriptor
  let processed: RawPhotoResourceDescriptor
}

enum RawPhotoResourceSelectionError: Error {
  case ambiguousOriginals
  case unknownOriginalType
}

func photoResourceKey(_ values: [String]) -> String {
  let data = try! JSONEncoder().encode(values)
  return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

func selectRawJpegPair(
  assetId: String,
  revision: String,
  resources: [RawPhotoResourceDescriptor]
) throws -> RawPhotoResourceSelection? {
  let sameParent = resources.filter { $0.assetId == assetId }
  // PHAssetResourceType.photo / alternatePhoto are the original formats.
  // fullSizePhoto and adjustment-base renditions cannot prove a combined item.
  let originals = sameParent.filter { $0.type == 1 || $0.type == 4 }
  guard originals.contains(where: { $0.type == 1 }), originals.contains(where: { $0.type == 4 }) else {
    return nil
  }
  guard Set(originals.map(\.key)).count == originals.count else {
    throw RawPhotoResourceSelectionError.ambiguousOriginals
  }
  for resource in originals {
    guard let type = UTType(resource.uniformTypeIdentifier), type.conforms(to: .image) else {
      throw RawPhotoResourceSelectionError.unknownOriginalType
    }
  }
  let raws = originals.filter { UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) == true }
  let jpegs = originals.filter { UTType($0.uniformTypeIdentifier)?.conforms(to: .jpeg) == true }
  guard !raws.isEmpty, !jpegs.isEmpty else { return nil }
  guard originals.count == 2, raws.count == 1, jpegs.count == 1, raws[0].type != jpegs[0].type else {
    throw RawPhotoResourceSelectionError.ambiguousOriginals
  }

  let rendered = sameParent.filter {
    $0.type == 5 && UTType($0.uniformTypeIdentifier)?.conforms(to: .image) == true
      && UTType($0.uniformTypeIdentifier)?.conforms(to: .rawImage) != true
  }
  guard rendered.count <= 1 else { throw RawPhotoResourceSelectionError.ambiguousOriginals }
  let processed = rendered.first ?? jpegs[0]
  let pairKey = photoResourceKey([assetId, revision, jpegs[0].key, raws[0].key, processed.key])
  return RawPhotoResourceSelection(
    assetId: assetId, pairKey: pairKey, jpegOriginal: jpegs[0], rawOriginal: raws[0], processed: processed
  )
}
