import ContactProvider
import Contacts
import SwiftUI
import UIKit

@main
struct CleanupApp: App {
  var body: some Scene {
    WindowGroup { CleanupScreen() }
  }
}

@MainActor
@Observable
final class CleanupModel {
  private(set) var log: [String] = []
  private(set) var busy = false

  func run(_ title: String, _ work: @escaping @Sendable () async throws -> String) {
    guard !busy else { return }
    busy = true
    append("▶︎ \(title)")
    Task {
      let started = Date()
      do {
        let result = try await work()
        append("✓ \(title): \(result)（\(Self.seconds(since: started))）")
      } catch {
        append("✗ \(title): \(Self.describe(error))（\(Self.seconds(since: started))）")
      }
      busy = false
    }
  }

  private func append(_ line: String) {
    log.append("\(Date().formatted(date: .omitted, time: .standard)) \(line)")
    SharedLog.write("app: \(line)")
  }

  private static func seconds(since start: Date) -> String {
    String(format: "%.1f秒", Date().timeIntervalSince(start))
  }

  private static func describe(_ error: any Error, depth: Int = 0) -> String {
    if let error = error as? ContactProviderError { return "ContactProviderError.\(error)" }
    let ns = error as NSError
    var text = "\(ns.domain) \(ns.code) \(ns.localizedDescription)"
    let details = ns.userInfo.filter {
      $0.key != NSUnderlyingErrorKey && $0.key != NSMultipleUnderlyingErrorsKey
        && $0.key != NSLocalizedDescriptionKey
    }
    for (key, value) in details.sorted(by: { $0.key < $1.key }) { text += "\n  \(key) = \(value)" }
    guard depth < 4 else { return text }
    var underlying: [any Error] = []
    if let one = ns.userInfo[NSUnderlyingErrorKey] as? any Error { underlying.append(one) }
    if let many = ns.userInfo[NSMultipleUnderlyingErrorsKey] as? [any Error] {
      underlying += many
    }
    for inner in underlying { text += "\n← " + describe(inner, depth: depth + 1) }
    return text
  }
}

enum ProviderDomain {
  static func state() throws -> String {
    let manager = try ContactProviderManager()
    return "isEnabled = \(manager.isEnabled)"
  }

  static func disable() async throws -> String {
    let manager = try ContactProviderManager()
    try await manager.disable()
    return "完了、\(try state())"
  }

  static func signal() async throws -> String {
    let manager = try ContactProviderManager()
    try await manager.signalEnumerator()
    SharedLog.write("app: 分割削除が終わったので提供を無効にします")
    try await manager.disable()
    return "分割削除と無効化が終わりました、\(try state())"
  }
}

enum ContactCount {
  static func containers() async throws -> String {
    let store = CNContactStore()
    guard try await store.requestAccess(for: .contacts) else { return "連絡先へのアクセスが拒否されました" }
    return try await Task.detached(priority: .userInitiated) { try count(store) }.value
  }

  private nonisolated static func count(_ store: CNContactStore) throws -> String {
    let containers = try store.containers(matching: nil)
    var lines: [String] = []
    for container in containers {
      let request = CNContactFetchRequest(keysToFetch: [CNContactGivenNameKey as CNKeyDescriptor])
      request.predicate = CNContact.predicateForContactsInContainer(
        withIdentifier: container.identifier)
      request.unifyResults = false
      var total = 0
      try store.enumerateContacts(with: request) { _, _ in total += 1 }
      let name = container.name.isEmpty ? "(名前なし)" : container.name
      lines.append("\(name) [type \(container.type.rawValue)]: \(total)件")
    }
    return lines.isEmpty ? "コンテナなし" : "\n" + lines.joined(separator: "\n")
  }
}

struct CleanupScreen: View {
  @State private var model = CleanupModel()
  @State private var shared: [String] = []

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("削除したアプリのContact Provider拡張が連絡先アプリに残した連絡先を、1,000件ずつ削除します。")
            .font(.subheadline)
        }
        Section("操作") {
          action("分割削除を始める") { try await ProviderDomain.signal() }
          action("状態を確認する") { try ProviderDomain.state() }
          action("最後に提供を無効にする") { try await ProviderDomain.disable() }
          action("連絡先の件数を数える") { try await ContactCount.containers() }
        }
        Section("拡張の進み具合") {
          ForEach(Array(shared.enumerated().reversed()), id: \.offset) { _, line in
            Text(line).font(.footnote.monospaced()).textSelection(.enabled)
          }
        }
        .task {
          UIApplication.shared.isIdleTimerDisabled = true
          if ProcessInfo.processInfo.arguments.contains("--signal") {
            model.run("分割削除を始める（起動引数）") { try await ProviderDomain.signal() }
          }
          while !Task.isCancelled {
            shared = SharedLog.tail(12)
            try? await Task.sleep(for: .seconds(2))
          }
        }
        Section("記録") {
          if model.busy { ProgressView().frame(maxWidth: .infinity) }
          ForEach(Array(model.log.enumerated().reversed()), id: \.offset) { _, line in
            Text(line).font(.footnote.monospaced()).textSelection(.enabled)
          }
        }
      }
      .navigationTitle("連絡先の掃除")
    }
    .tint(.primary)
  }

  private func action(_ title: String, _ work: @escaping @Sendable () async throws -> String)
    -> some View
  {
    Button(title) { model.run(title, work) }
      .disabled(model.busy)
  }
}
