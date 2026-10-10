// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftXPC
import Synchronization

/// Retains the hosted owner and buffers native C peers during asynchronous
/// construction/preparation. The native event queue never waits on Swift tasks.
private final class HostedActorService<Root: XPCRootActor>: Sendable {
  private struct State {
    var service: XPCActorService<Root>?
    var pending: [XPCConnection] = []
  }
  private let state = Mutex(State())

  func receive(_ connection: XPCConnection) {
    let service = state.withLock { state in
      guard let service = state.service else {
        state.pending.append(connection)
        return nil as XPCActorService<Root>?
      }
      return service
    }
    service?.admitHosted(connection)
  }

  func publish(_ service: XPCActorService<Root>) {
    let pending = state.withLock { state in
      state.service = service
      let pending = state.pending
      state.pending = []
      return pending
    }
    for connection in pending { service.admitHosted(connection) }
  }
}

func reportActorServiceStartupFailure(_ error: any Error) -> Never {
  FileHandle.standardError.write(Data("XPC actor service startup failed: \(error)\n".utf8))
  exit(1)
}

/// Hosts a bundled XPC service. Call on the OS main thread in a launchd-managed
/// XPC process; the native entry point aborts in an ordinary process.
/// Asynchronous factory/startup hooks buffer native peers without blocking their
/// queue. Cooperative shutdown awaits all lifecycle hooks before process exit
/// (0 on success, 1 on startup/cleanup failure). In-process owners never exit.
/// A concrete delegate can implement `static main()` and carry `@main` directly;
/// neither a separate app protocol nor a no-argument initializer is required.
@MainActor
public func xpcMain<Root: XPCRootActor>(
  delegate: some XPCConnectionActorServiceDelegate<Root>
) -> Never {
  let hosted = HostedActorService<Root>()
  SwiftXPC.xpcMain(
    { [hosted] in hosted.receive($0) },
    onReady: {
      Task.detached {
        do {
          let service = try await XPCActorService(delegate)
          try await service.startHosted()
          hosted.publish(service)
          _ = await service.host.waitForShutdown()
          exit(service.shutdownFailed ? 1 : 0)
        } catch { reportActorServiceStartupFailure(error) }
      }
    })
}
