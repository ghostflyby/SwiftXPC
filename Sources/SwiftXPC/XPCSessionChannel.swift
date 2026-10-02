// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

/// Session adapter. Logical activation gates incoming traffic even for native
/// accepted sessions, which are live after the listener callback returns.
final class XPCSessionChannel: @unchecked Sendable {
  private final class IncomingBox: Sendable {
    struct State {
      var handler: (@Sendable (XPCIncomingMessage) -> Void)?
      var pending: [XPCIncomingMessage] = []
      var draining = false
      var cancelled = false
      var active = false
    }
    let state = Mutex(State())
    let queue = DispatchQueue(label: "SwiftXPC.session.incoming")

    func setHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
      state.withLock { $0.handler = handler }
      scheduleDrain()
    }

    func receive(_ message: XPCIncomingMessage) {
      state.withLock { if !$0.cancelled { $0.pending.append(message) } }
      scheduleDrain()
    }

    func activate() {
      state.withLock { $0.active = true }
      scheduleDrain()
    }

    func cancel() {
      let pending = state.withLock { state in
        state.cancelled = true
        state.handler = nil
        let pending = state.pending
        state.pending = []
        return pending
      }
      withExtendedLifetime(pending) {}
    }

    private func scheduleDrain() {
      let start = state.withLock { state in
        guard state.active, !state.cancelled, !state.draining, state.handler != nil,
          !state.pending.isEmpty
        else { return false }
        state.draining = true
        return true
      }
      guard start else { return }
      queue.async { [self] in
        while true {
          let next = state.withLock {
            state -> (XPCIncomingMessage, @Sendable (XPCIncomingMessage) -> Void)? in
            guard !state.cancelled, let handler = state.handler, !state.pending.isEmpty else {
              state.draining = false
              return nil
            }
            return (state.pending.removeFirst(), handler)
          }
          guard let (message, handler) = next else { return }
          handler(message)
        }
      }
    }
  }

  private enum Source {
    case accepted(XPCSession)
    case dialed(@Sendable () throws -> XPCSession)
  }

  private enum Phase { case inactive, active, invalid }
  private struct Control {
    var phase = Phase.inactive
    var session: XPCSession?
    var pending: [PendingSend] = []
    var inFlight: [ObjectIdentifier: XPCSendSink] = [:]
  }

  private enum PendingSend: Sendable {
    case forget(SendableXPCObject)
    case reply(SendableXPCObject, XPCSendSink)
  }

  private let control = Mutex(Control())
  private let source: Source
  private let incoming = IncomingBox()
  private let invalidation = XPCInvalidationChain()
  private let sends = DispatchQueue(label: "SwiftXPC.session.sends")

  init(dialing endpoint: XPCEndpoint) {
    source = .dialed { try XPCSession(endpoint: endpoint, options: [.inactive]) }
  }

  init(machServiceName: String) {
    source = .dialed { try XPCSession(machService: machServiceName, options: [.inactive]) }
  }

  /// Session handlers must be configured inside the listener's accept callback.
  init(accepted session: XPCSession) {
    source = .accepted(session)
    control.withLock { $0.session = session }
    installSessionHandler(session)
  }

  deinit { cancel() }

  func setIncomingHandler(_ handler: @escaping @Sendable (XPCIncomingMessage) -> Void) {
    incoming.setHandler(handler)
  }

  func addInvalidationHandler(_ handler: @escaping @Sendable () -> Void) {
    if invalidation.add(handler) { handler() }
  }

  // Sessions do not reconnect; all losses are terminal invalidations.
  func addInterruptionHandler(_ handler: @escaping @Sendable () -> Void) {}

  func waitForDisconnection() async {
    await withCheckedContinuation { invalidation.waitForDisconnection(continuation: $0) }
  }

  func activate() {
    var failed: [PendingSend] = []
    var didFail = false
    control.withLock { state in
      guard state.phase == .inactive else { return }
      do {
        switch source {
        case .accepted(let session): state.session = session
        case .dialed(let make):
          let session = try make()
          installSessionHandler(session)
          try session.activate()
          state.session = session
        }
        state.phase = .active
        // Enqueue under the same lock as subsequent sends to preserve FIFO.
        for send in state.pending { enqueue(send, on: state.session!) }
        state.pending = []
      } catch {
        state.phase = .invalid
        state.session = nil
        failed = state.pending
        state.pending = []
        state.inFlight = [:]
        didFail = true
      }
    }
    if didFail {
      finishPending(failed)
      incoming.cancel()
      invalidation.take()()
    } else {
      incoming.activate()
    }
  }

  func cancel() {
    let (session, pending, inFlight) = control.withLock {
      state -> (XPCSession?, [PendingSend], [XPCSendSink]) in
      guard state.phase != .invalid else { return (nil, [], []) }
      state.phase = .invalid
      let pending = state.pending
      state.pending = []
      let session = state.session
      state.session = nil
      let inFlight = Array(state.inFlight.values)
      state.inFlight = [:]
      return (session, pending, inFlight)
    }
    session?.cancel(reason: "channel canceled")
    incoming.cancel()
    finishPending(pending)
    for sink in inFlight { sink.finish(.failure(XPCChannelError.invalid)) }
    invalidation.take()()
  }

  private func finishPending(_ pending: [PendingSend]) {
    for send in pending {
      if case .reply(_, let sink) = send { sink.finish(.failure(XPCChannelError.invalid)) }
    }
  }

  private func submit(_ send: PendingSend) {
    let rejected = control.withLock { state in
      if case .reply(_, let sink) = send {
        guard !sink.isDelivered else { return false }
        if state.phase != .invalid { state.inFlight[ObjectIdentifier(sink)] = sink }
      }
      switch state.phase {
      case .invalid: return true
      case .inactive: state.pending.append(send)
      case .active: enqueue(send, on: state.session!)
      }
      return false
    }
    if rejected { finishPending([send]) }
  }

  private func enqueue(_ send: PendingSend, on session: XPCSession) {
    sends.async { [weak self] in
      guard let self, self.control.withLock({ $0.phase == .active }) else {
        if case .reply(_, let sink) = send { sink.finish(.failure(XPCChannelError.invalid)) }
        return
      }
      switch send {
      case .forget(let payload):
        do { try session.send(message: XPCDictionary(payload.raw)) } catch { self.cancel() }
      case .reply(let payload, let sink):
        guard !sink.isDelivered else { return }
        session.send(message: XPCDictionary(payload.raw)) { [weak self] result in
          switch result {
          case .success(let reply): sink.finish(.reply(SendableXPCObject(reply.xpcObject)))
          case .failure:
            sink.finish(.failure(XPCChannelError.invalid))
            self?.cancel()
          }
          self?.removeSend(sink)
        }
      }
    }
  }

  private func removeSend(_ sink: XPCSendSink) {
    let removed = control.withLock { state -> [PendingSend] in
      state.inFlight.removeValue(forKey: ObjectIdentifier(sink))
      let removed = state.pending.filter {
        if case .reply(_, let pendingSink) = $0 { return pendingSink === sink }
        return false
      }
      state.pending.removeAll {
        if case .reply(_, let pendingSink) = $0 { return pendingSink === sink }
        return false
      }
      return removed
    }
    withExtendedLifetime(removed) {}
  }

  func applyPeerCodeSigningRequirement(_ requirement: String?) throws(XPCPeerRequirementError) {
    if requirement != nil { throw XPCPeerRequirementError(status: ENOTSUP) }
  }

  func sendAndForget(_ message: xpc_object_t) {
    submit(.forget(SendableXPCObject(message)))
  }

  func send(_ message: xpc_object_t) async throws -> xpc_object_t {
    let sink = XPCSendSink()
    let reply = try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        sink.install(continuation)
        if !sink.isDelivered { submit(.reply(SendableXPCObject(message), sink)) }
      }
    } onCancel: {
      sink.finish(.failure(CancellationError()))
      self.removeSend(sink)
    }
    return reply.raw
  }

  private func installSessionHandler(_ session: XPCSession) {
    session.setCancellationHandler { [weak self] _ in self?.cancel() }
    session.setIncomingMessageHandler { [incoming] payload in
      incoming.receive(
        XPCIncomingMessage(
          payload: payload.xpcObject,
          replyer: { payload.reply(XPCDictionary($0)) }))
      return nil
    }
  }
}
