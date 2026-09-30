// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
@testable import DistributedXPC
import Foundation
import SwiftXPC
import SwiftXPCMacros
import Testing

/// Actor-level integration over the session backend: the same `xpcTest`
/// coordinator, parameterized to `.session`, serves root calls and mints
/// session listeners for exported child actors (the M4 fix).
@Suite(.serialized) struct XPCSessionBackendTests {

  @XPCService
  distributed actor SessionWorker {
    typealias ActorSystem = XPCDistributedActorSystem

    distributed func work(_ input: String) -> String {
      "worked: \(input)"
    }
  }

  @XPCService
  distributed actor SessionRoot: XPCRootActor {
    typealias ActorSystem = XPCDistributedActorSystem

    distributed func makeWorker() -> SessionWorker {
      SessionWorker(actorSystem: actorSystem)
    }
  }

  @Test func SessionBackendXpcTestServesRootCalls() async throws {
    let service = try xpcTest(
      SessionRoot.self, transport: .session, watchdog: .seconds(10))
    defer { service.close() }

    let worker = try await service.client.root.makeWorker()
    #expect(try await worker.work("session") == "worked: session")
  }

  @Test func SessionBackendExportsChildActorsOverSessionListeners() async throws {
    let service = try xpcTest(
      SessionRoot.self, transport: .session, watchdog: .seconds(10))
    defer { service.close() }

    // makeWorker() exports the child through the coordinator's system,
    // whose export listeners ride the session backend; the client-side
    // import dials with the process default (C), exercising cross-backend
    // interop over the backend-agnostic endpoint.
    let worker = try await service.client.root.makeWorker()
    #expect(try await worker.work("export") == "worked: export")
    #expect(service.transport == .session)
  }

  @Test func SessionBackendPeerDropIsTerminalForTheClientChannel() async throws {
    let service = try xpcTest(
      SessionRoot.self, transport: .session, watchdog: .seconds(10))
    defer { service.close() }
    _ = try await service.client.root.makeWorker()

    // Probed: a dropped session channel never re-dials — the next call
    // fails terminally instead of transparently recovering like the C
    // backend does.
    service.dropServerPeer()
    await #expect(throws: XPCChannelError.self) {
      _ = try await service.client.root.makeWorker()
    }
  }
}
