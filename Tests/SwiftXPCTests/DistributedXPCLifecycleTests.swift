// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
import Synchronization
import DistributedXPC
import Testing

private final class InvocationGate: Sendable {
  let started = DispatchSemaphore(value: 0)
  private let continuation = Mutex<CheckedContinuation<Void, Never>?>(nil)

  func wait() async {
    await withCheckedContinuation { waiter in
      continuation.withLock { $0 = waiter }
      started.signal()
    }
  }

  func waitUntilStarted() -> Bool { started.wait(timeout: .now() + 3) == .success }

  func release() {
    let waiter = continuation.withLock { value in
      let waiter = value
      value = nil
      return waiter
    }
    waiter?.resume()
  }
}

@XPCService
private distributed actor SuspendedRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem
  let gate: InvocationGate

  init(actorSystem: ActorSystem) {
    self.actorSystem = actorSystem
    gate = InvocationGate()
  }

  init(gate: InvocationGate, actorSystem: ActorSystem) {
    self.actorSystem = actorSystem
    self.gate = gate
  }

  distributed func hold() async -> Int {
    await gate.wait()
    return 42
  }
}

@Test(arguments: XPCChannelTransport.allCases)
func SuspendedInvocationDoesNotBlockPeerInvalidation(transport: XPCChannelTransport) async throws {
  let gate = InvocationGate()
  let log = XPCServiceEventLog()
  let service = XPCActorService(SuspendedRoot.self, transport: transport, eventLog: log) {
    SuspendedRoot(gate: gate, actorSystem: $0)
  }
  let acceptor = try transport.acceptor()
  acceptor.setAcceptHandler { service.host.accept($0) }
  try acceptor.activate()
  let client = try XPCRootConnection<SuspendedRoot>.connect(
    using: transport.channel(dialing: acceptor.wireEndpoint))
  defer { gate.release(); client.close(); acceptor.cancel(); service.cancel() }
  let call = Task { try await client.root.hold() }
  #expect(gate.waitUntilStarted())
  client.close()
  service.host.cancel()
  #expect(await log.expectEvent(.peerDidEnd, timeout: .seconds(2)) != nil)
  gate.release()
  await #expect(throws: XPCChannelError.self) { _ = try await call.value }
}
