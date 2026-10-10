// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import SwiftXPC

/// Hosts a Session actor service for a name advertised by launchd MachServices.
/// Call on the OS main thread. Asynchronous startup finishes before dispatch
/// opens. Shutdown awaits all hooks before exit (0 on completed cooperative
/// shutdown, 1 on startup/cleanup failure or bare cancellation). Bundled `.xpc`
/// servers use the C-native `xpcMain` entry.
/// The Session actor delegate's default main uses its declared `serviceName`;
/// this function also hosts an explicitly configured delegate instance.
@MainActor
public func xpcSessionMain<Root: XPCRootActor>(
  service: String, delegate: some XPCSessionActorServiceDelegate<Root>
) -> Never {
  precondition(Thread.isMainThread, "xpcSessionMain must run on the OS main thread")
  Task.detached {
    do {
      let owner = try await XPCActorService(sessionDelegate: delegate)
      try await owner.listen(service: service)
      let completed = await owner.host.waitForShutdown()
      exit(completed && !owner.shutdownFailed ? 0 : 1)
    } catch { reportActorServiceStartupFailure(error) }
  }
  dispatchMain()
}
