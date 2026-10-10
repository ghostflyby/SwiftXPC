// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftXPC
import Synchronization
import XPC

/// Retains the hosted owner and buffers native C peers during asynchronous
/// construction/preparation. The native event queue never waits on Swift tasks.
final class HostedActorService<Root: XPCRootActor>: Sendable {
  private struct State {
    var service: XPCActorService<Root>?
    var pending: [XPCConnection] = []
  }
  private let state = Mutex(State())
  var pendingConnectionCount: Int { state.withLock { $0.pending.count } }

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
/// (0 on completed cooperative shutdown, 1 on startup/cleanup failure or bare
/// cancellation). A process-lifetime native transaction prevents idle exit from
/// cutting off asynchronous preparation/cleanup. In-process owners never exit.
/// The C actor delegate protocol provides main for a concrete `@main` type.
/// Call this function directly when hosting an explicitly configured instance.
@MainActor
public func xpcMain<Root: XPCRootActor>(
  delegate: some XPCConnectionActorServiceDelegate<Root>
) -> Never {
  let hosted = HostedActorService<Root>()
  SwiftXPC.xpcMain(
    { [hosted] in hosted.receive($0) },
    onReady: {
      // This owner has process lifetime. Keep asynchronous preparation and
      // cleanup alive even after the last message/peer releases its transaction.
      // exit() ends the process; ending this transaction first would race idle exit.
      xpc_transaction_begin()
      Task.detached {
        do {
          let service = try await XPCActorService(delegate)
          try await service.startHosted()
          hosted.publish(service)
          let completed = await service.host.waitForShutdown()
          exit(completed && !service.shutdownFailed ? 0 : 1)
        } catch { reportActorServiceStartupFailure(error) }
      }
    })
}
