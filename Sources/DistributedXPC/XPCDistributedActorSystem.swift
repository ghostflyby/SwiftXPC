// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import Distributed
import SwiftXPC
import Synchronization
import XPC

/// The `DistributedActorSystem` implementation that carries distributed
/// actor calls over XPC.
///
/// Every inbound XPC channel serves exactly one bound actor: the initial
/// mach service channel serves a root actor (ID `.root`), and each exported
/// actor reference mints its own channel. Named C connections may transparently
/// re-establish after a service restart; Session channels never re-dial.
///
/// Standalone local registries use process/static lifetime. Service-owned
/// registries are cleaned up by `XPCActorService` when the service ends.
/// Proxy systems retain their outbound channel and are invalidated when it ends.
public final class XPCDistributedActorSystem: DistributedActorSystem, Sendable {
  public typealias ActorID = XPCActorID
  public typealias ResultHandler = XPCInvocationResultHandler
  public typealias InvocationEncoder = XPCInvocationEncoder
  public typealias InvocationDecoder = XPCInvocationDecoder
  public typealias SerializationRequirement = XPCMarshal

  let activeActorsLock: Mutex<[ActorID: any DistributedActor]> = Mutex([:])

  private let ids = Atomic<UInt64>(0)
  private let assignedIDsLock: Mutex<Set<ActorID>> = Mutex([])

  private let reservedIDLock: Mutex<ActorID?> = Mutex(nil)

  let exportSessionsLock = Mutex<[UUID: XPCActorExportSession]>([:])
  let importedReferencesLock = Mutex<[XPCActorID: StoredActorReference]>([:])
  let invalidated = Mutex(false)
  private struct DispatchState {
    var gate: XPCServiceReadiness?
    var stopped = false
  }
  private let dispatchState = Mutex(DispatchState())

  func suspendServiceDispatch() {
    dispatchState.withLock { $0.gate = XPCServiceReadiness() }
  }

  func resumeServiceDispatch() {
    let gate = dispatchState.withLock { $0.stopped ? nil : $0.gate }
    gate?.finish(.success(()))
  }

  func stopServiceDispatch() {
    let gate = dispatchState.withLock { state in
      state.stopped = true
      return state.gate
    }
    gate?.finish(.failure(CancellationError()))
    let sessions = exportSessionsLock.withLock { Array($0.values) }
    for session in sessions { session.cancel() }
  }

  func registerExportSession(_ session: XPCActorExportSession) -> Bool {
    dispatchState.withLock { state in
      guard !state.stopped else { return false }
      return invalidated.withLock { invalidated in
        guard !invalidated else { return false }
        exportSessionsLock.withLock { $0[session.id] = session }
        return true
      }
    }
  }

  private func awaitDispatch() async -> Bool {
    let (gate, stopped) = dispatchState.withLock { ($0.gate, $0.stopped) }
    guard !stopped else { return false }
    do { try await gate?.wait() } catch { return false }
    return dispatchState.withLock { !$0.stopped }
  }

  private let serviceShutdownHandler = Mutex<(@Sendable () -> Void)?>(nil)
  /// Immutable export and import policy for this actor system.
  public let transport: XPCChannelTransport
  /// Outbound routing exists only on proxy systems; local registries need no channel.
  public let connection: XPCChannel?

  /// Creates a local registry for process/static lifetime.
  /// Registered actors keep the registry alive; dropping external references
  /// does not tear it down. Use `XPCActorService` for a service-owned registry.
  public convenience init(transport: XPCChannelTransport = .cConnection) {
    self.init(connection: nil, transport: transport)
  }

  /// Creates a proxy system that retains the outbound channel.
  /// Terminal channel invalidation releases its registry and exported references.
  public convenience init(connection: XPCChannel) {
    self.init(connection: connection, transport: connection.transport)
  }

  private init(connection: XPCChannel?, transport: XPCChannelTransport) {
    self.connection = connection
    self.transport = transport
    connection?.addInvalidationHandler { [weak self] in self?.invalidate() }
    connection?.setIncomingHandler { _ in }
  }

  deinit {
    // Drain sessions and actors before stored properties (and their locks)
    // are destroyed: releasing registered actors later would re-enter
    // resignID on half-destroyed Mutexes.
    invalidate()
  }

  func invalidate() {
    stopServiceDispatch()
    let sessions = invalidated.withLock { invalidated in
      invalidated = true
      let sessions = exportSessionsLock.withLock {
        let sessions = Array($0.values)
        $0.removeAll()
        return sessions
      }
      importedReferencesLock.withLock { $0.removeAll() }
      return sessions
    }
    for session in sessions { session.cancel() }
    // Actor destruction calls resignID, so release registry contents outside its lock.
    let actors = activeActorsLock.withLock { actors in
      let retained = actors
      actors.removeAll()
      return retained
    }
    withExtendedLifetime(actors) {}
    // Sessions are gone: no export session has live peers anymore, so any
    // drain waiter must be released here too — the drain notification only
    // fires from `exportSessionDrained`, which this path bypasses.
    notifyDrainIfQuiescent()
  }

  func rememberImported(_ reference: StoredActorReference) {
    invalidated.withLock { invalidated in
      guard !invalidated else { return }
      importedReferencesLock.withLock { $0[reference.actorID] = reference }
    }
  }

  /// Returns the local actor registered under `id`, or nil so the runtime
  /// creates a remote proxy. This is the standard distributed resolution
  /// entry point; see `XPCRootActor.connect` for bootstrap.
  public func resolve<Act>(id: ActorID, as actorType: Act.Type)
    throws -> Act? where Act: DistributedActor
  {
    activeActorsLock.withLock { $0[id] as? Act }
  }

  /// Assigns the next local actor ID (starting at 1), unless a framework
  /// reservation (root bootstrap) is pending.
  public func assignID<Act>(_ actorType: Act.Type) -> ActorID
  where Act: DistributedActor {
    // Consume the reservation and record the assignment inside the
    // reservation critical section, so a concurrent `reserveRootID` cannot
    // re-reserve an identity that is about to be assigned.
    let reserved = reservedIDLock.withLock { reserved -> ActorID? in
      guard let pending = reserved else { return nil }
      reserved = nil
      assignedIDsLock.withLock { _ = $0.insert(pending) }
      return pending
    }
    if let reserved { return reserved }
    let id = XPCActorID(id: ids.wrappingAdd(1, ordering: .relaxed).newValue)
    _ = assignedIDsLock.withLock { $0.insert(id) }
    return id
  }

  /// Reserves the root identity before the service constructs its first actor.
  func reserveRootID() {
    _ = reservedIDLock.withLock { reserved -> Bool in
      let taken = assignedIDsLock.withLock { $0.contains(.root) }
      guard !taken else { return false }
      reserved = .root
      return true
    }
  }

  /// Registers a freshly created local actor under its assigned ID.
  /// Called by the runtime during local actor initialization.
  public func actorReady<Act>(_ actor: Act)
  where Act: DistributedActor, Act.ID == ActorID {
    guard self.assignedIDsLock.withLock({ $0.contains(actor.id) }) else {
      fatalError("Attempted to mark an unknown actor '\(actor.id)' ready")
    }
    let previous = invalidated.withLock { invalidated -> (any DistributedActor)? in
      guard !invalidated else { return nil }
      return self.activeActorsLock.withLock { $0.updateValue(actor, forKey: actor.id) }
    }
    withExtendedLifetime(previous) {}
  }

  /// Removes a local actor and tears down any channels exporting it.
  /// Called by the runtime when a local actor is destroyed.
  public func resignID(_ id: ActorID) {
    _ = self.activeActorsLock.withLock { $0.removeValue(forKey: id) }
    let sessions = self.exportSessionsLock.withLock { exports in
      let matching = exports.filter { $0.value.actorID == id }
      for key in matching.keys { exports.removeValue(forKey: key) }
      return matching.map(\.value)
    }
    for session in sessions { session.cancel() }
    // This removal path bypasses `exportSessionDrained`; release drain
    // waiters whose condition may now hold.
    notifyDrainIfQuiescent()
  }

  public func makeInvocationEncoder() -> InvocationEncoder { .init() }

  /// Routes `requestServiceShutdown()` to the `XPCServiceHost` accepting
  /// this session's channel. Installed by the root-binding peer handler;
  /// never set on client-side systems.
  func setServiceShutdownHandler(_ handler: @escaping @Sendable () -> Void) {
    serviceShutdownHandler.withLock { $0 = handler }
  }

  private let drainWaiters = Mutex<[CheckedContinuation<Void, Never>]>([])

  /// Waits until no export session of this system has live peers — every
  /// export session fully drained (child reclamation attempted). Returns
  /// immediately when already drained. Never polls.
  func waitForExportDrain(onRegistered: @Sendable () -> Void = {}) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      insertDrainWaiter(continuation: cont)
      onRegistered()
    }
  }

  private func insertDrainWaiter(continuation: CheckedContinuation<Void, Never>) {
    let drained = drainWaiters.withLock { waiters -> Bool in
      // Atomic check-and-append: a drain observed between a segmented
      // check and this append would fire on an empty list and this waiter
      // would never be resumed.
      if !hasLiveExportPeers {
        return true
      }
      waiters.append(continuation)
      return false
    }
    if drained {
      continuation.resume()
    }
  }

  func notifyDrainIfQuiescent() {
    let toResume: [CheckedContinuation<Void, Never>] = drainWaiters.withLock { waiters in
      guard !hasLiveExportPeers else { return [] }
      let drained = waiters
      waiters.removeAll()
      return drained
    }
    toResume.forEach { $0.resume() }
  }

  var hasLiveExportPeers: Bool {
    // Same criterion as child reclamation: a session that was handed out but
    // never dialed is an in-flight wire, not an idle one.
    exportSessionsLock.withLock { sessions in
      sessions.values.contains { !$0.fullyDrained }
    }
  }

  /// Called when an export session for `id` drains to zero live peers.
  /// Local registries release the pin of `id` when
  /// every session minted for it is fully drained (zero live peers, none of
  /// them an un-dialed in-flight wire) — an actor nobody references anymore,
  /// locally or remotely.
  func exportSessionDrained(_ id: ActorID) {
    // The service root is permanent: never evict its registry entry.
    if connection == nil && id != .root {
      let removed = activeActorsLock.withLock { actors -> (any DistributedActor)? in
        guard actors[id] != nil else { return nil }
        let reclaimable = exportSessionsLock.withLock { sessions in
          let mine = sessions.values.filter { $0.actorID == id }
          return !mine.isEmpty && mine.allSatisfy(\.fullyDrained)
        }
        return reclaimable ? actors.removeValue(forKey: id) : nil
      }
      withExtendedLifetime(removed) {}
    }
    notifyDrainIfQuiescent()
  }

  /// Requests a cooperative shutdown of the `XPCServiceHost` hosting the
  /// session this system belongs to; see
  /// `XPCServiceHost.requestShutdown()`. This is the entry point for
  /// service-initiated retirement: under hosted `xpcMain`, one call from a
  /// root actor's `distributed func shutdown()` ends the process
  /// cooperatively — peers observe clean disconnects, `serviceWillShutdown`
  /// runs, then the process exits.
  ///
  /// A no-op on systems that host no server session — client-side systems
  /// (root connections, imported actor references) can never shut their
  /// service down through this path.
  public func requestServiceShutdown() {
    serviceShutdownHandler.withLock { $0 }?()
  }

  /// Serializes invocations without blocking native queues. A binding barrier
  /// protects even channels activated by user code inside a did-bind hook.
  /// Queue observers are internal deterministic regression-test instrumentation.
  func bind<Act>(
    _ connection: XPCChannel, to actor: Act,
    readiness: XPCServiceReadiness? = nil,
    onEnqueued: @escaping @Sendable () -> Void = {},
    onFinished: @escaping @Sendable () -> Void = {}
  ) where Act: DistributedActor, Act.ID == ActorID {
    let tail = Mutex<Task<Void, Never>?>(nil)
    let ended = Mutex(false)
    connection.addInvalidationHandler { ended.withLock { $0 = true } }
    connection.setIncomingHandler { [weak self, weak actor] message in
      tail.withLock { previous in
        let predecessor = previous
        previous = Task { @Sendable [weak self, weak actor] in
          defer { onFinished() }
          await predecessor?.value
          do { try await readiness?.wait() } catch { return }
          guard !ended.withLock({ $0 }), let self, let actor, await self.awaitDispatch() else {
            return
          }
          await self.handleIncomingMessage(message, on: actor)
        }
      }
      onEnqueued()
    }
  }

  func dispatchInvocation<Act>(
    _ message: XPCInvocationMessage, on actor: Act
  ) async throws -> XPCReplyEnvelope
  where Act: DistributedActor, Act.ID == ActorID {
    guard message.actorID == actor.id else {
      throw XPCDispatchError.unknownActor(message.actorID)
    }
    guard message.version == XPCWireProtocol.currentVersion else {
      throw XPCDispatchError.unsupportedProtocolVersion(
        expected: XPCWireProtocol.currentVersion, actual: message.version)
    }

    // Metadata conformance is optional. When present, a non-empty table acts
    // as a method whitelist and supplies typed-throws error decoding for the
    // caller; without it (or with an empty table) dispatch is permissive and
    // unknown targets fail in executeDistributedTarget instead.
    let metadataTable = (type(of: actor) as? any XPCDistributedTargetMetadataProviding.Type)?
      .xpcDistributedTargetMetadata
    if let metadataTable, !metadataTable.isEmpty,
      lookupMetadata(forMethod: message.method, in: metadataTable) == nil
    {
      throw XPCDispatchError.unknownTarget(message.method)
    }
    var decoder = XPCInvocationDecoder(array: message.arguments, transport: transport)
    let replyLock = Mutex<XPCReplyEnvelope?>(nil)
    let resultHandler = XPCInvocationResultHandler { envelope in
      replyLock.withLock { $0 = envelope }
    }
    do {
      try await executeDistributedTarget(
        on: actor, target: message.target,
        invocationDecoder: &decoder, handler: resultHandler)
    } catch let error as CancellationError {
      throw error
    } catch let error as any ErrorXPCMarshal {
      throw error
    } catch {
      throw XPCDispatchError.targetExecutionFailed(String(describing: error))
    }
    guard let reply = replyLock.withLock({ $0 }) else {
      throw XPCDispatchError.missingInvocationResult
    }
    return reply
  }

  private func fallbackThrownErrorType<Act, Err>(
    for actorType: Act.Type,
    method: String,
    throwing errorType: Err.Type
  ) throws -> (any ErrorXPCMarshal.Type)?
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    if errorType is any ErrorXPCMarshal.Type { return nil }
    guard let metadataProvider = actorType as? any XPCDistributedTargetMetadataProviding.Type
    else { return nil }
    return lookupMetadata(forMethod: method, in: metadataProvider.xpcDistributedTargetMetadata)?
      .thrownErrorType
  }

  func handleIncomingMessage<Act>(_ message: XPCIncomingMessage, on actor: Act) async
  where Act: DistributedActor, Act.ID == ActorID {
    let resultHandler = XPCInvocationResultHandler { envelope in
      message.reply(try envelope.marshal())
    }
    do {
      let invocation = try XPCInvocationMessage.unmarshal(from: message.payload)
      let envelope = try await dispatchInvocation(invocation, on: actor)
      try resultHandler.send(envelope)
    } catch {
      replyToFailure(error, message: message)
    }
  }

  /// Even an error whose custom encoder fails must complete the reply.
  func replyToFailure(_ error: any Error, message: XPCIncomingMessage) {
    do {
      if error is CancellationError {
        message.reply(try XPCReplyEnvelope(kind: .cancelled).marshal())
        return
      }
      let payload: xpc_object_t
      if let error = error as? any ErrorXPCMarshal {
        payload = try error.marshal()
      } else {
        payload = try XPCDispatchError.targetExecutionFailed(String(describing: error)).marshal()
      }
      message.reply(try XPCReplyEnvelope(kind: .throwError, payload: payload).marshal())
    } catch {
      message.reply(XPCReplyEnvelope.encodingFailureReply())
    }
  }

  func decodeRemoteCallReply<Act, Err, Res>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    method: String,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) throws -> Res
  where
    Act: DistributedActor, Act.ID == ActorID,
    Err: Error, Res: SerializationRequirement
  {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType, method: method, throwing: errorType)
    return try envelope.decodeReturnValue(
      throwing: errorType, returning: returnType, fallbackErrorType: fallbackErrorType)
  }

  func decodeRemoteCallVoidReply<Act, Err>(
    _ envelope: XPCReplyEnvelope,
    for actorType: Act.Type,
    target: RemoteCallTarget,
    method: String,
    throwing errorType: Err.Type
  ) throws
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    let fallbackErrorType = try fallbackThrownErrorType(
      for: actorType, method: method, throwing: errorType)
    try envelope.decodeReturnVoid(throwing: errorType, fallbackErrorType: fallbackErrorType)
  }

  /// Sends an invocation over the connection and decodes the reply.
  /// Called by compiler-generated distributed thunks.
  public func remoteCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) async throws -> Res
  where
    Act: DistributedActor, Act.ID == ActorID,
    Err: Error, Res: SerializationRequirement
  {
    let metadata = (Act.self as? any XPCDistributedTargetMetadataProviding.Type)?
      .xpcDistributedTargetMetadata
    let method = parseTargetIdentifier(target.identifier, matching: metadata) ?? target.identifier
    let message = XPCInvocationMessage(
      method: method, actorID: actor.id, target: target, arguments: invocation.array)
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(payload)
    guard let connection else { throw XPCChannelError.invalid }
    let result = try await connection.send(xpcDict.xpcObject)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    return try XPCActorDecodingContext.$transport.withValue(transport) {
      try decodeRemoteCallReply(
        envelope, for: Act.self, target: target, method: method,
        throwing: errorType, returning: returnType)
    }
  }

  /// Sends a void invocation over the connection. Called by
  /// compiler-generated distributed thunks.
  public func remoteCallVoid<Act, Err>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing errorType: Err.Type
  ) async throws
  where Act: DistributedActor, Act.ID == ActorID, Err: Error {
    let metadata = (Act.self as? any XPCDistributedTargetMetadataProviding.Type)?
      .xpcDistributedTargetMetadata
    let method = parseTargetIdentifier(target.identifier, matching: metadata) ?? target.identifier
    let message = XPCInvocationMessage(
      method: method, actorID: actor.id, target: target, arguments: invocation.array)
    let payload = try message.marshal()
    let xpcDict = XPCDictionary(payload)
    guard let connection else { throw XPCChannelError.invalid }
    let result = try await connection.send(xpcDict.xpcObject)
    let envelope = try XPCReplyEnvelope.unmarshal(from: result)
    try XPCActorDecodingContext.$transport.withValue(transport) {
      try decodeRemoteCallVoidReply(
        envelope, for: Act.self, target: target, method: method, throwing: errorType)
    }
  }
}
