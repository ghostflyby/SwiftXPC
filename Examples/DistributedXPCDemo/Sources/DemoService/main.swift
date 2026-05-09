// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DistributedXPC
import DemoShared
import SwiftXPC
import Synchronization

@available(macOS 15, *)
private final class DemoServiceSession {
  let system: XPCDistributedActorSystem

  init(connection: XPCConnection) {
    self.system = XPCDistributedActorSystem(connection: connection)
    system.registerDefaultActor(DemoGreeter.self)
    // Remove session from array when connection is invalidated.
    system.connection.addInvalidationHandler { [weak self] in
      guard let self else { return }
      sessions.withLock { $0.removeAll { $0 === self } }
    }
    connection.activate()
  }
}

@available(macOS 15, *)
private let sessions = Mutex<[DemoServiceSession]>([])

@main
enum DemoService {
  @MainActor
  static func main() {
    guard #available(macOS 15, *) else {
      fatalError("DistributedXPCDemo service requires macOS 15 or newer.")
    }

    xpcMain { connection in
      sessions.withLock {
        $0.append(DemoServiceSession(connection: connection))
      }
    }
  }
}
