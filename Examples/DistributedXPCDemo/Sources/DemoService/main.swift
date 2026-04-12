// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DistributedXPC
import DemoShared
import SwiftXPC
import Synchronization

@available(macOS 15, *)
private final class DemoServiceSession {
  let system: XPCDistributedActorSystem
  let greeter: DemoGreeter

  init(connection: XPCConnection) {
    self.system = XPCDistributedActorSystem(connection: connection)
    self.greeter = DemoGreeter(actorSystem: system)
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
