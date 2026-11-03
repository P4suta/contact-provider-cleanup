import Foundation

/// Appends lines to a log in the App Group, so the app, the extension, and devicectl see one record.
enum SharedLog {
  static let group = Bundle.main.object(forInfoDictionaryKey: "CleanupAppGroup") as? String

  /// devicectl reads App Group files only under Library.
  static var url: URL? {
    group.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }?
      .appendingPathComponent("Library/Caches/cleanup.log")
  }

  static func write(_ line: String) {
    guard let url else { return }
    let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
    let data = Data("\(stamp) \(line)\n".utf8)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? data.write(to: url)
    }
  }

  static func tail(_ count: Int) -> [String] {
    guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return Array(text.split(separator: "\n").suffix(count).map(String.init))
  }
}
