import Foundation

@main
enum RawPhotoResourceSelectorTests {
  static func resource(_ key: String, _ type: Int, _ uti: String, assetId: String = "combined", current: Bool = false) -> RawPhotoResourceDescriptor {
    RawPhotoResourceDescriptor(assetId: assetId, key: key, type: type, filename: key, uniformTypeIdentifier: uti, isCurrent: current)
  }

  static func main() {
    do {
      let jpeg = resource("original.JPG", 1, "public.jpeg")
      let raf = resource("original.RAF", 4, "com.fuji.raw-image")
      let pair = try selectRawJpegPair(assetId: "combined", revision: "1", resources: [jpeg, raf])
      try check("JPEG and RAF originals", pair?.jpegOriginal == jpeg && pair?.rawOriginal == raf && pair?.processed == jpeg)

      let dng = resource("original.DNG", 1, "com.adobe.raw-image")
      let alternate = resource("original.JPG", 4, "public.jpeg")
      let rawFirst = try selectRawJpegPair(assetId: "combined", revision: "1", resources: [dng, alternate])
      let reordered = try selectRawJpegPair(assetId: "combined", revision: "1", resources: [alternate, dng])
      try check("RAW first and JPEG alternate", rawFirst?.jpegOriginal == alternate && rawFirst?.rawOriginal == dng)
      try check("Stable resource ordering", rawFirst?.pairKey == reordered?.pairKey)

      let rendered = resource("rendered.JPG", 5, "public.jpeg", current: true)
      try check("Standalone RAW with JPEG rendition", try selectRawJpegPair(assetId: "combined", revision: "1", resources: [dng, rendered]) == nil)
      let otherRaw = resource("original.RAF", 4, "com.fuji.raw-image", assetId: "another-item")
      try check("Separate Photos parents", try selectRawJpegPair(assetId: "combined", revision: "1", resources: [jpeg, otherRaw]) == nil)
      try check("Embedded preview is not an original", try selectRawJpegPair(assetId: "combined", revision: "1", resources: [dng]) == nil)
      let video = resource("motion.MOV", 9, "com.apple.quicktime-movie")
      try check("Live Photo remains unchanged", try selectRawJpegPair(assetId: "combined", revision: "1", resources: [jpeg, video]) == nil)
      let heif = resource("original.HEIC", 1, "public.heic")
      try check("HEIF and RAW remains unchanged", try selectRawJpegPair(assetId: "combined", revision: "1", resources: [heif, raf]) == nil)

      let editedPair = try selectRawJpegPair(assetId: "combined", revision: "2", resources: [jpeg, raf, rendered])
      try check("Edited output needs original proof", editedPair?.jpegOriginal == jpeg && editedPair?.rawOriginal == raf && editedPair?.processed == rendered)
      try check("Revision invalidates pair evidence", editedPair?.pairKey != pair?.pairKey)

      do {
        _ = try selectRawJpegPair(assetId: "combined", revision: "1", resources: [jpeg, raf, resource("second.RAF", 4, "com.fuji.raw-image")])
        throw Failure(message: "Ambiguous originals were accepted")
      } catch is RawPhotoResourceSelectionError { }
      do {
        _ = try selectRawJpegPair(assetId: "combined", revision: "1", resources: [jpeg, raf, raf])
        throw Failure(message: "Duplicate resource keys were accepted")
      } catch is RawPhotoResourceSelectionError { }
      print("12 RAW/JPEG resource selection checks passed")
    } catch {
      FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
      exit(1)
    }
  }

  struct Failure: Error { let message: String }
  static func check(_ name: String, _ condition: Bool) throws {
    if !condition { throw Failure(message: name) }
  }
}
