// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import Foundation
@testable import DistributedXPC
import Synchronization
import Testing

private enum LifecycleFailure: Error { case expected }

private final class CallCounter: Sendable { let value = Mutex(0) }

/// A deterministic suspension point with a bounded emergency release.
private final class HookGate: Sendable {
  let entered = DispatchSemaphore(value: 0)
  private struct State {
    var released = false
    var waiters: [CheckedContinuation<Void, Never>] = []
  }
  private let state = Mutex(State())
  func wait() async {
    await withCheckedContinuation { continuation in
      let released = state.withLock { state in
        if state.released { return true }
        state.waiters.append(continuation)
        return false
      }
      entered.signal()
      if released { continuation.resume() }
    }
  }
  func release() {
    let waiters = state.withLock { state in
      state.released = true
      let waiters = state.waiters
      state.waiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
  func watchdog() -> DispatchWorkItem {
    let item = DispatchWorkItem { self.release() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: item)
    return item
  }
}

/// Has only a dependency-bearing initializer, exercising the removed protocol constraint.
@XPCService
private distributed actor LifecycleRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem
  private var value: String
  let calls: CallCounter
  init(value: String, calls: CallCounter, actorSystem: ActorSystem) {
    self.value = value
    self.calls = calls
    self.actorSystem = actorSystem
  }
  func configure(_ value: String) { self.value = value }
  distributed func read() -> String {
    calls.value.withLock { $0 += 1 }
    return value
  }
  distributed func makeChild() -> LifecycleChild {
    LifecycleChild(actorSystem: actorSystem)
  }
  distributed func retire() { actorSystem.requestServiceShutdown() }
}

@XPCService
distributed actor LifecycleChild {
  typealias ActorSystem = XPCDistributedActorSystem
  distributed func read() -> String { "child" }
}

private final class LifecycleDelegate: @unchecked Sendable, XPCConnectionActorServiceDelegate,
  XPCSessionActorServiceDelegate
{
  init() {}
  static var serviceName: String { "org.swiftxpc.lifecycle" }
  @MainActor static func main() { xpcMain(delegate: Self()) }
  let events = Mutex<[String]>([])
  let calls = CallCounter()
  var factoryGate: HookGate?
  var willStartGate: HookGate?
  var didStartGate: HookGate?
  var willBindGate: HookGate?
  var didBindGate: HookGate?
  var shutdownGate: HookGate?
  var failFactory = false
  var failStartup = false
  var failBinding = false
  var failShutdown = false
  var denyNative = false
  var activateWhileBinding = false
  var activateBeforeBinding = false
  let ended = DispatchSemaphore(value: 0)
  let rejected = DispatchSemaphore(value: 0)
  let factoryFinished = DispatchSemaphore(value: 0)
  private struct Created {
    weak var root: LifecycleRoot?; weak var system: XPCDistributedActorSystem?
    weak var service: XPCActorService<LifecycleRoot>?
  }
  private let created = Mutex(Created())
  var factoryObjectsReleased: Bool { created.withLock { $0.root == nil && $0.system == nil } }
  var preparingService: XPCActorService<LifecycleRoot>? { created.withLock { $0.service } }

  // Configuration is immutable once the fixture is passed to a service.
  func record(_ event: String) { events.withLock { $0.append(event) } }
  func makeRoot(actorSystem: XPCDistributedActorSystem) async throws -> LifecycleRoot {
    record("factory")
    await Task.yield()
    let root = LifecycleRoot(value: "injected", calls: calls, actorSystem: actorSystem)
    created.withLock { $0 = Created(root: root, system: actorSystem) }
    await factoryGate?.wait()
    defer { factoryFinished.signal() }
    if failFactory { throw LifecycleFailure.expected }
    return root
  }
  func serviceWillStart(_ service: XPCActorService<LifecycleRoot>) async throws {
    created.withLock { $0.service = service }
    record("willStart")
    _ = await service.root.whenLocal { root in root.configure("prepared") }
    await willStartGate?.wait()
    if failStartup { throw LifecycleFailure.expected }
  }
  func serviceDidStart(_ service: XPCActorService<LifecycleRoot>) async {
    record("didStart")
    await didStartGate?.wait()
  }
  func shouldAcceptConnection(
    _ connection: XPCConnection, in service: XPCActorService<LifecycleRoot>
  ) throws -> Bool {
    #expect(service.root.id == .root)
    record("native")
    return !denyNative
  }
  func shouldAcceptSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<LifecycleRoot>
  ) throws -> Bool {
    #expect(service.root.id == .root)
    record("native")
    return !denyNative
  }
  func didRejectConnection(
    _ connection: XPCConnection, in service: XPCActorService<LifecycleRoot>, error: (any Error)?
  ) { record("nativeReject"); rejected.signal() }
  func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, in service: XPCActorService<LifecycleRoot>,
    error: (any Error)?
  ) { record("nativeReject"); rejected.signal() }
  func peerWillBind(_ peer: XPCChannel, to service: XPCActorService<LifecycleRoot>) async throws {
    record("willBind")
    if activateBeforeBinding { peer.activate() }
    await willBindGate?.wait()
    if failBinding { throw LifecycleFailure.expected }
  }
  func peerDidBind(_ peer: XPCChannel, to service: XPCActorService<LifecycleRoot>) async {
    record("didBind")
    if activateWhileBinding { peer.activate() }
    await didBindGate?.wait()
  }
  func peerDidFailToBind(
    _ peer: XPCChannel, to service: XPCActorService<LifecycleRoot>, error: any Error
  ) async { record("bindingFail"); rejected.signal() }
  func peerDidEnd(_ peer: XPCChannel, in service: XPCActorService<LifecycleRoot>) async {
    record("end")
    ended.signal()
  }
  func serviceWillShutdown(_ service: XPCActorService<LifecycleRoot>) async throws {
    #expect(
      try service.root.actorSystem.resolve(id: .root, as: LifecycleRoot.self) === service.root)
    record("willShutdown")
    await shutdownGate?.wait()
    if failShutdown { throw LifecycleFailure.expected }
  }
  func serviceDidShutdown(_ service: XPCActorService<LifecycleRoot>, error: (any Error)?) async {
    #expect((try? service.root.actorSystem.resolve(id: .root, as: LifecycleRoot.self)) == nil)
    record(error == nil ? "didShutdown" : "shutdownError")
  }
}

private func lifecycleService(_ delegate: LifecycleDelegate, _ transport: XPCChannelTransport)
  async throws -> XPCActorService<LifecycleRoot>
{
  switch transport {
  case .cConnection: return try await XPCActorService(delegate)
  case .session: return try await XPCActorService(sessionDelegate: delegate)
  }
}

@Suite(.serialized, .timeLimit(.minutes(1)))
struct XPCActorServiceLifecycleTests {
  @Test(arguments: XPCChannelTransport.allCases, XPCChannelTransport.allCases)
  func BindingHooksGateRPCs(server: XPCChannelTransport, client: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let will = HookGate(), did = HookGate()
    delegate.willBindGate = will
    delegate.didBindGate = did
    delegate.activateWhileBinding = true
    delegate.activateBeforeBinding = true
    let emergency = [will.watchdog(), did.watchdog()]
    let service = try await lifecycleService(delegate, server)
    let enqueued = DispatchSemaphore(value: 0)
    service.system.invocationEnqueued.withLock { $0 = { enqueued.signal() } }
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: client.channel(dialing: listener.wireEndpoint))
    defer {
      emergency.forEach { $0.cancel() }; will.release(); did.release(); owner.close();
      service.cancel()
    }
    let rpc = Task { try await owner.root.read() }
    try #require(await waitForTestSignal(will.entered))
    try #require(await waitForTestSignal(enqueued))
    #expect(delegate.calls.value.withLock { $0 } == 0)
    #expect(!delegate.events.withLock { $0.contains("didBind") })
    will.release()
    try #require(await waitForTestSignal(did.entered))
    #expect(delegate.calls.value.withLock { $0 } == 0)
    did.release()
    #expect(try await rpc.value == "prepared")
    owner.close()
    try #require(await waitForTestSignal(delegate.ended))
    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(
      delegate.events.withLock { $0 } == [
        "factory", "willStart", "didStart", "native", "willBind", "didBind", "end", "willShutdown",
        "didShutdown",
      ])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func PublicHostBindingAlsoWaitsForServiceStartup(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let gate = HookGate()
    delegate.didStartGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    let delivered = DispatchSemaphore(value: 0)
    let extra = try transport.acceptor { channel in
      service.host.bind(channel); delivered.signal()
    }
    try extra.activate()
    let start = Task { try await service.listen() }
    try #require(await waitForTestSignal(gate.entered))
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: extra.wireEndpoint))
    defer { emergency.cancel(); gate.release(); extra.cancel(); owner.close(); service.cancel() }
    let rpc = Task { try await owner.root.read() }
    try #require(await waitForTestSignal(delivered))
    #expect(!delegate.events.withLock { $0.contains("willBind") })
    #expect(delegate.calls.value.withLock { $0 } == 0)
    gate.release()
    _ = try await start.value
    #expect(try await rpc.value == "prepared")
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ConcurrentListenersRunStartupOnce(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    defer { emergency.cancel(); gate.release(); service.cancel() }
    let first = Task { try await service.listen() }
    try #require(await waitForTestSignal(gate.entered))
    let second = Task { try await service.listen() }
    gate.release()
    let a = try await first.value, b = try await second.value
    #expect(a !== b)
    #expect(delegate.events.withLock { $0 } == ["factory", "willStart", "didStart"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func StartupFailureRollsBackThroughShutdown(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    delegate.failStartup = true
    let service = try await lifecycleService(delegate, transport)
    await #expect(throws: LifecycleFailure.self) { try await service.listen() }
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(
      delegate.events.withLock { $0 } == ["factory", "willStart", "willShutdown", "didShutdown"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func FactoryFailureReleasesPartiallyConstructedRegistry(transport: XPCChannelTransport) async {
    let delegate = LifecycleDelegate()
    delegate.failFactory = true
    await #expect(throws: LifecycleFailure.self) { try await lifecycleService(delegate, transport) }
    #expect(delegate.factoryObjectsReleased)
    #expect(delegate.events.withLock { $0 } == ["factory"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func NativeRejectionDoesNotRunBindingHooks(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    delegate.denyNative = true
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close(); service.cancel() }
    await #expect(throws: XPCChannelError.self) { try await owner.root.read() }
    try #require(await waitForTestSignal(delegate.rejected))
    #expect(
      delegate.events.withLock { $0 } == [
        "factory", "willStart", "didStart", "native", "nativeReject",
      ])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func BindingFailureDoesNotEmitBoundOrEnd(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    delegate.failBinding = true
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close(); service.cancel() }
    await #expect(throws: XPCChannelError.self) { try await owner.root.read() }
    try #require(await waitForTestSignal(delegate.rejected))
    #expect(
      delegate.events.withLock { $0 } == [
        "factory", "willStart", "didStart", "native", "willBind", "bindingFail",
      ])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownWaitsForHooksAndReportsCleanupFailure(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.shutdownGate = gate
    delegate.failShutdown = true
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    defer { emergency.cancel(); gate.release(); owner.close(); service.cancel() }
    #expect(try await owner.root.read() == "prepared")
    service.root.actorSystem.requestServiceShutdown()
    try #require(await waitForTestSignal(gate.entered))
    service.host.requestShutdown()
    service.cancel()
    #expect(await !service.host.waitForShutdown(timeout: .milliseconds(50)))
    #expect(delegate.events.withLock { $0.suffix(2) } == ["end", "willShutdown"])
    gate.release()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(service.shutdownFailed)
    #expect(delegate.events.withLock { $0.last } == "shutdownError")
    #expect(delegate.events.withLock { $0.filter { $0 == "willShutdown" }.count } == 1)
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownDuringBindingWaitsForRejection(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willBindGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    defer { emergency.cancel(); gate.release(); owner.close(); service.cancel() }
    let rpc = Task { try await owner.root.read() }
    try #require(await waitForTestSignal(gate.entered))
    service.host.requestShutdown()
    #expect(await !service.host.waitForShutdown(timeout: .milliseconds(50)))
    gate.release()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    await #expect(throws: XPCChannelError.self) { try await rpc.value }
    #expect(
      delegate.events.withLock { $0.suffix(3) } == ["bindingFail", "willShutdown", "didShutdown"])
    #expect(!delegate.events.withLock { $0.contains("end") || $0.contains("didBind") })
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func CancelIsTerminalAndDoesNotStartAsyncHooks(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    service.host.cancel()
    service.host.requestShutdown()
    #expect(await !service.host.waitForShutdown(timeout: .seconds(1)))
    #expect(delegate.events.withLock { $0 } == ["factory"])
    await #expect(throws: XPCChannelError.invalid) { try await service.listen() }
    #expect((try? service.root.actorSystem.resolve(id: .root, as: LifecycleRoot.self)) == nil)
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func RootAndHostDoNotRetainServingOwner(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    var service: XPCActorService<LifecycleRoot>? = try await lifecycleService(delegate, transport)
    weak var weakService = service
    let listener = try await #require(service).listen()
    let host = try #require(service).host, root = try #require(service).root
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close() }
    #expect(try await owner.root.read() == "prepared")
    service = nil
    #expect(weakService == nil)
    #expect(await !host.waitForShutdown(timeout: .seconds(1)))
    #expect(try root.actorSystem.resolve(id: .root, as: LifecycleRoot.self) == nil)
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func AdditionalListenerFailureKeepsServiceRunning(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close(); service.cancel() }
    await #expect(throws: (any Error).self) {
      try await service.listen(testingActivation: { _ in throw LifecycleFailure.expected })
    }
    #expect(try await owner.root.read() == "prepared")
    #expect(delegate.events.withLock { $0.filter { $0 == "willStart" }.count } == 1)
    #expect(!delegate.events.withLock { $0.contains("willShutdown") })
  }
  @Test(arguments: XPCChannelTransport.allCases)
  func NativeStartupFailureUsesRollbackPipeline(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    await #expect(throws: LifecycleFailure.self) {
      try await service.listen(testingActivation: { _ in throw LifecycleFailure.expected })
    }
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(
      delegate.events.withLock { $0 } == ["factory", "willStart", "willShutdown", "didShutdown"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownDuringStartupWaitsForItsHook(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    defer { emergency.cancel(); gate.release(); service.cancel() }
    let startup = Task { try await service.listen() }
    try #require(await waitForTestSignal(gate.entered))
    service.host.requestShutdown()
    #expect(await !service.host.waitForShutdown(timeout: .milliseconds(50)))
    #expect(!delegate.events.withLock { $0.contains("willShutdown") })
    gate.release()
    await #expect(throws: (any Error).self) { try await startup.value }
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(
      delegate.events.withLock { $0 } == ["factory", "willStart", "willShutdown", "didShutdown"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownClosesChildChannelsBeforeRegistryCleanup(transport: XPCChannelTransport) async throws
  {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.shutdownGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    let listener = try await service.listen()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: listener.wireEndpoint))
    let child = try await owner.root.makeChild()
    let watchdog = DispatchWorkItem { child.actorSystem.connection?.cancel() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); emergency.cancel(); gate.release(); owner.close(); service.cancel() }
    #expect(try await child.read() == "child")
    service.host.requestShutdown()
    try #require(await waitForTestSignal(gate.entered))
    #expect(try service.root.actorSystem.resolve(id: child.id, as: LifecycleChild.self) != nil)
    await child.actorSystem.connection?.waitForDisconnection()
    await #expect(throws: XPCChannelError.self) { try await child.read() }
    gate.release()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(try service.root.actorSystem.resolve(id: child.id, as: LifecycleChild.self) == nil)
    #expect(delegate.events.withLock { $0.filter { $0 == "didBind" }.count } == 1)
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func DuplicateHostBindingRunsHooksOnce(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    _ = try await service.listen()
    let extra = try transport.acceptor { channel in
      service.host.bind(channel)
      service.host.bind(channel)
    }
    try extra.activate()
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: extra.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close(); extra.cancel(); service.cancel() }
    #expect(try await owner.root.read() == "prepared")
    #expect(delegate.events.withLock { $0.filter { $0 == "didBind" }.count } == 1)
    owner.close()
    try #require(await waitForTestSignal(delegate.ended))
    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    #expect(delegate.events.withLock { $0.filter { $0 == "end" }.count } == 1)
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func ShutdownRejectsLaterExplicitBindings(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    _ = try await service.listen()
    let extra = try transport.acceptor { service.host.bind($0) }
    try extra.activate()
    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(5)))
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: extra.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); owner.close(); extra.cancel(); service.cancel() }
    await #expect(throws: XPCChannelError.self) { try await owner.root.read() }
    #expect(delegate.events.withLock { $0.last } == "didShutdown")
    #expect(
      !delegate.events.withLock {
        $0.contains("willBind") || $0.contains("didBind") || $0.contains("end")
      })
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func TestWatchdogCoversSuspendedFactory(transport: XPCChannelTransport) async {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.factoryGate = gate
    let emergency = gate.watchdog()
    defer { emergency.cancel(); gate.release() }
    await #expect(throws: CancellationError.self) {
      switch transport {
      case .cConnection: _ = try await xpcTest(delegate, watchdog: .seconds(1))
      case .session: _ = try await xpcTest(sessionDelegate: delegate, watchdog: .seconds(1))
      }
    }
    #expect(delegate.events.withLock { $0 } == ["factory"])
    gate.release()
    #expect(await waitForTestSignal(delegate.factoryFinished))
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func TestWatchdogCoversSuspendedStartup(transport: XPCChannelTransport) async {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    defer { emergency.cancel(); gate.release() }
    await #expect(throws: CancellationError.self) {
      switch transport {
      case .cConnection: _ = try await xpcTest(delegate, watchdog: .seconds(1))
      case .session: _ = try await xpcTest(sessionDelegate: delegate, watchdog: .seconds(1))
      }
    }
    #expect(delegate.events.withLock { $0 } == ["factory", "willStart"])
    gate.release()
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func TestStartupHonorsCallerCancellation(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    defer { emergency.cancel(); gate.release() }
    let creation = Task {
      switch transport {
      case .cConnection: return try await xpcTest(delegate)
      case .session: return try await xpcTest(sessionDelegate: delegate)
      }
    }
    try #require(await waitForTestSignal(gate.entered))
    let service = try #require(delegate.preparingService)
    let startup = try #require(service.startupTask)
    creation.cancel()
    await #expect(throws: CancellationError.self) { try await creation.value }
    #expect(delegate.events.withLock { $0 } == ["factory", "willStart"])
    gate.release()
    await #expect(throws: CancellationError.self) { try await startup.value }
    #expect(try service.root.actorSystem.resolve(id: .root, as: LifecycleRoot.self) == nil)
    #expect(await !service.host.waitForShutdown())
    #expect(delegate.events.withLock { $0 } == ["factory", "willStart"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func FailedCoordinatorConnectionAwaitsCooperativeCleanup(transport: XPCChannelTransport)
    async throws
  {
    let delegate = LifecycleDelegate()
    let service = try await lifecycleService(delegate, transport)
    await #expect(throws: LifecycleFailure.self) {
      try await makeTestCoordinator(
        watchdog: .seconds(10),
        connect: { _ in
          throw LifecycleFailure.expected
        }, factory: { service })
    }
    #expect(await service.host.waitForShutdown(timeout: .seconds(2)))
    #expect(
      delegate.events.withLock { $0 } == [
        "factory", "willStart", "didStart", "willShutdown", "didShutdown",
      ])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func LateBindingCannotNotifyDuringServiceCleanup(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.shutdownGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    _ = try await service.listen()
    let extra = try transport.acceptor { service.host.bind($0) }
    try extra.activate()
    service.host.requestShutdown()
    try #require(await waitForTestSignal(gate.entered))
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: transport.channel(dialing: extra.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer { watchdog.cancel(); emergency.cancel(); gate.release(); owner.close(); extra.cancel() }
    await #expect(throws: XPCChannelError.self) { try await owner.root.read() }
    #expect(
      delegate.events.withLock { $0 } == ["factory", "willStart", "didStart", "willShutdown"])
    gate.release()
    #expect(await service.host.waitForShutdown(timeout: .seconds(2)))
    #expect(delegate.events.withLock { $0.last } == "didShutdown")
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func CancellingListenStopsSuspendedStartup(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, transport)
    defer { emergency.cancel(); gate.release(); service.cancel() }
    let startup = Task { try await service.listen() }
    try #require(await waitForTestSignal(gate.entered))
    startup.cancel()
    #expect(await !service.host.waitForShutdown(timeout: .seconds(2)))
    gate.release()
    await #expect(throws: CancellationError.self) { try await startup.value }
    #expect(try service.root.actorSystem.resolve(id: .root, as: LifecycleRoot.self) == nil)
    #expect(delegate.events.withLock { $0 } == ["factory", "willStart"])
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func HostedCConnectionsBufferUntilPreparationCompletes(client: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate(), gate = HookGate()
    delegate.willStartGate = gate
    let emergency = gate.watchdog()
    let service = try await lifecycleService(delegate, .cConnection)
    let hosted = HostedActorService<LifecycleRoot>()
    let received = DispatchSemaphore(value: 0)
    let peers = Mutex<[XPCChannel]>([])
    let listener = try XPCChannelTransport.cConnection.acceptor { channel in
      peers.withLock { $0.append(channel) }
      if let native = channel.connection { hosted.receive(native) }
      received.signal()
    }
    try listener.activate()
    let startup = Task {
      try await service.startHosted()
      hosted.publish(service)
    }
    try #require(await waitForTestSignal(gate.entered))
    let owner = try XPCRootConnection<LifecycleRoot>.connect(
      using: client.channel(dialing: listener.wireEndpoint))
    let watchdog = DispatchWorkItem { owner.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
    defer {
      watchdog.cancel(); emergency.cancel(); gate.release(); owner.close(); listener.cancel();
      service.cancel()
    }
    let rpc = Task { try await owner.root.read() }
    try #require(await waitForTestSignal(received))
    #expect(hosted.pendingConnectionCount == 1)
    #expect(delegate.calls.value.withLock { $0 } == 0)
    #expect(!delegate.events.withLock { $0.contains("native") })
    gate.release()
    try await startup.value
    #expect(try await rpc.value == "prepared")
    #expect(hosted.pendingConnectionCount == 0)
    service.host.requestShutdown()
    #expect(await service.host.waitForShutdown(timeout: .seconds(2)))
    withExtendedLifetime(peers) {}
  }

  @Test(arguments: XPCChannelTransport.allCases)
  func CompletedTestStartupDoesNotRetainCoordinator(transport: XPCChannelTransport) async throws {
    let delegate = LifecycleDelegate()
    var coordinator: XPCRootTestCoordinator<LifecycleRoot>?
    switch transport {
    case .cConnection: coordinator = try await xpcTest(delegate, watchdog: .seconds(10))
    case .session:
      coordinator = try await xpcTest(sessionDelegate: delegate, watchdog: .seconds(10))
    }
    weak var weakCoordinator = coordinator
    weak var weakService = coordinator?.service
    let host = try #require(coordinator).service.host
    let localRoot = try #require(coordinator).service.root
    #expect(try await #require(coordinator).client.root.read() == "prepared")
    coordinator = nil
    #expect(weakCoordinator == nil)
    #expect(weakService == nil)
    #expect(await !host.waitForShutdown())
    withExtendedLifetime(localRoot) {}
  }

}

@XPCService
private distributed actor QueuedLifecycleRoot: XPCRootActor {
  typealias ActorSystem = XPCDistributedActorSystem
  let gate: HookGate
  let calls = Mutex(0)
  init(gate: HookGate, actorSystem: ActorSystem) {
    self.gate = gate
    self.actorSystem = actorSystem
  }
  distributed func hold() async -> Int { await gate.wait(); return 1 }
  distributed func queued() -> Int {
    calls.withLock {
      $0 += 1; return $0
    }
  }
  func count() -> Int { calls.withLock { $0 } }
}

@Test(arguments: XPCChannelTransport.allCases)
func ShutdownSkipsEnqueuedInvocationsWithoutDrainingRunningOne(transport: XPCChannelTransport)
  async throws
{
  let system = XPCDistributedActorSystem(transport: transport)
  system.reserveRootID()
  let gate = HookGate(), emergency = gate.watchdog()
  let root = QueuedLifecycleRoot(gate: gate, actorSystem: system)
  let queued = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
  let enqueuedCount = Mutex(0), finishedCount = Mutex(0)
  let host = XPCServiceHost(peerHandler: { channel in
    system.bind(
      channel, to: root,
      onEnqueued: {
        if enqueuedCount.withLock({
          $0 += 1; return $0
        }) == 2 {
          queued.signal()
        }
      },
      onFinished: {
        if finishedCount.withLock({
          $0 += 1; return $0
        }) == 2 {
          finished.signal()
        }
      })
  })
  let listener = try transport.acceptor { host.bind($0) }
  try listener.activate()
  let owner = try XPCRootConnection<QueuedLifecycleRoot>.connect(
    using: transport.channel(dialing: listener.wireEndpoint))
  let watchdog = DispatchWorkItem { owner.close() }
  DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  defer {
    watchdog.cancel(); emergency.cancel(); gate.release(); owner.close(); listener.cancel();
    host.cancel(); system.invalidate()
  }
  let first = Task { try await owner.root.hold() }
  try #require(await waitForTestSignal(gate.entered))
  let second = Task { try await owner.root.queued() }
  try #require(await waitForTestSignal(queued))
  system.stopServiceDispatch()
  host.requestShutdown()
  #expect(await host.waitForShutdown(timeout: .seconds(2)))
  gate.release()
  try #require(await waitForTestSignal(finished))
  #expect(await root.whenLocal { $0.count() } == 0)
  await #expect(throws: XPCChannelError.self) { try await first.value }
  await #expect(throws: XPCChannelError.self) { try await second.value }
}
