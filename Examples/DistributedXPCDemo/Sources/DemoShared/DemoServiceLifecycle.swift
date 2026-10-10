// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DistributedXPC
import Foundation

private enum PreparationFailure: Error { case timedOut, cleanup }

/// Common demo lifecycle, shared by two independently hosted entry types.
public protocol DemoServiceLifecycle: XPCActorServiceDelegate where Root == DemoRoot {
  var dependency: String { get }
}

extension DemoServiceLifecycle {
  // Bundled services receive no caller argv. Integration fixtures put their
  // arguments in the copied bundle instead of changing launchd's environment.
  private var arguments: [String] {
    guard let path = Bundle.main.url(forResource: "lifecycle-arguments", withExtension: "plist"),
      let data = try? Data(contentsOf: path),
      let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String]
    else { return CommandLine.arguments }
    return CommandLine.arguments + values
  }

  private func argument(_ flag: String) -> String? {
    let arguments = self.arguments
    guard let index = arguments.firstIndex(of: flag),
      arguments.indices.contains(index + 1)
    else { return nil }
    return arguments[index + 1]
  }

  private func record(_ event: String) {
    // Lifecycle probe jobs capture stdout; production hosting needs no log file API.
    let data = Data("\(event)\n".utf8)
    if let path = argument("--event-log"), let file = FileHandle(forWritingAtPath: path) {
      file.seekToEndOfFile()
      file.write(data)
      file.closeFile()
    } else {
      FileHandle.standardOutput.write(data)
    }
  }

  private func awaitGate(_ flag: String) async throws {
    guard let path = argument(flag) else { return }
    let deadline = ContinuousClock.now + .seconds(15)
    while !FileManager.default.fileExists(atPath: path) {
      guard ContinuousClock.now < deadline else { throw PreparationFailure.timedOut }
      try await Task.sleep(for: .milliseconds(10))
    }
  }

  public func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> DemoRoot {
    record("factory")
    record("pid:\(getpid())")
    await Task.yield()
    try await awaitGate("--startup-gate")
    return DemoRoot(dependency: dependency, actorSystem: actorSystem)
  }

  public func serviceWillStart(_ service: XPCActorService<DemoRoot>) async throws {
    record("will-start")
    _ = await service.root.whenLocal { $0.prepare() }
  }

  public func serviceDidStart(_ service: XPCActorService<DemoRoot>) async {
    record("did-start")
  }
  public func peerWillBind(_ peer: XPCChannel, to service: XPCActorService<DemoRoot>) async throws {
    record("will-bind")
  }
  public func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<DemoRoot>) async {
    record("did-bind")
    if arguments.contains("--cancel") { service.cancel() }
  }
  public func peerDidEnd(_ peer: XPCChannel, in service: XPCActorService<DemoRoot>) async {
    record("peer-end")
  }
  public func serviceWillShutdown(_ service: XPCActorService<DemoRoot>) async throws {
    record("will-shutdown")
    try await awaitGate("--shutdown-gate")
    if arguments.contains("--fail-shutdown") { throw PreparationFailure.cleanup }
  }
  public func serviceDidShutdown(_ service: XPCActorService<DemoRoot>, error: (any Error)?) async {
    record(error == nil ? "did-shutdown" : "shutdown-error")
  }

}
