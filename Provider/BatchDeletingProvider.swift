import ContactProvider
import ExtensionFoundation
import Foundation

/// Deletes the contacts an earlier provider left behind through change batches,
/// because one domain-wide `disable()` or `reset()` exceeds the 30-second call limit.
@main
final class BatchDeletingProvider: ContactProviderExtension {
  required init() { SharedLog.write("extension: init") }
  func configure(for domain: any ContactProviderDomain) {
    SharedLog.write("extension: configure \(domain.identifier)")
  }
  func enumerator(for collection: ContactItem.Identifier) -> any ContactItemEnumerator {
    SharedLog.write("extension: enumerator \(collection.value)")
    return BatchDeleter()
  }
  func invalidate() async throws { SharedLog.write("extension: invalidate") }
}

private let cleanupMarker = Data("contact-provider-cleanup".utf8)

/// Maps `identifiers.txt`, one earlier item identifier per line, so the extension never holds them all.
private enum EarlierIdentifiers {
  static let data: Result<Data, any Error> = Result {
    guard let url = Bundle.main.url(forResource: "identifiers", withExtension: "txt") else {
      throw CocoaError(.fileNoSuchFile)
    }
    return try Data(contentsOf: url, options: .alwaysMapped)
  }

  static func batch(_ data: Data, from offset: Int, limit: Int)
    -> (ids: [ContactItem.Identifier], next: Int)
  {
    var ids: [ContactItem.Identifier] = []
    ids.reserveCapacity(limit)
    var cursor = offset
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      while ids.count < limit, cursor < bytes.count {
        var end = cursor
        while end < bytes.count, bytes[end] != 0x0A { end += 1 }
        if end > cursor {
          let line = UnsafeBufferPointer(rebasing: bytes[cursor..<end])
          ids.append(ContactItem.Identifier(String(decoding: line, as: UTF8.self)))
        }
        cursor = end + 1
      }
    }
    return (ids, min(cursor, data.count))
  }
}

private final class BatchDeleter: ContactItemEnumerator {
  /// The system suggests 5, but each deletion costs far more than a round trip,
  /// and 3,000 measured no faster than 1,000 on an iPhone running iOS 27.2.
  static let batchSize = 1000

  /// An empty content enumeration would ask the system for one domain-wide deletion again.
  func enumerateContent(in page: ContactItemPage, for observer: any ContactItemContentObserver)
    async
  {
    SharedLog.write("extension: enumerateContent offset=\(page.offset) refused")
    observer.didFinishEnumeratingContentWithError(ContactProviderError.cannotEnumerate)
  }

  func enumerateChanges(
    startingAt anchor: ContactItemSyncAnchor, for observer: any ContactItemChangeObserver
  ) async {
    let ours = anchor.generationMarker == cleanupMarker
    if !ours {
      SharedLog.write("extension: earlier anchor offset=\(anchor.offset)")
    }
    let data: Data
    do {
      data = try EarlierIdentifiers.data.get()
    } catch {
      SharedLog.write("extension: identifiers.txt unreadable \(error)")
      observer.didFinishEnumeratingChangesWithError(ContactProviderError.cannotEnumerate)
      return
    }
    let start = ours ? min(max(anchor.offset, 0), data.count) : 0
    let (ids, next) = EarlierIdentifiers.batch(data, from: start, limit: Self.batchSize)
    observer.didDelete(ids)
    let more = next < data.count
    observer.didFinishEnumeratingChanges(
      upTo: ContactItemSyncAnchor(generationMarker: cleanupMarker, offset: next), moreComing: more)
    SharedLog.write(
      "extension: \(next * 100 / max(data.count, 1))% deleted through byte \(next)/\(data.count)")
  }

  func invalidate() async { SharedLog.write("extension: enumerator invalidate") }
}
