// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

/// Service lifecycle, independent of native listener admission.
/// Hooks may run on arbitrary threads; protect shared state accordingly.
public protocol XPCServiceDelegate: Sendable {
  /// The admitted channel is bound to the service, before message dispatch.
  func didAcceptPeer(_ peer: XPCChannel)
  /// An admitted channel could not be bound, or the host was already closed.
  /// Native admission failures use the backend-specific rejection hook instead.
  func didRejectPeer(_ peer: XPCChannel, error: (any Error)?)
  /// The bound channel ended. No further traffic can be sent on it.
  func peerDidEnd(_ peer: XPCChannel)
  /// Explicit cooperative shutdown has cancelled peers. Peer-end callbacks
  /// may follow asynchronously; this does not imply process termination.
  func serviceWillShutdown()
}

extension XPCServiceDelegate {
  public func didAcceptPeer(_ peer: XPCChannel) {}
  public func didRejectPeer(_ peer: XPCChannel, error: (any Error)?) {}
  public func peerDidEnd(_ peer: XPCChannel) {}
  public func serviceWillShutdown() {}
}

/// Native C admission. The connection is inactive during audit; identity
/// and `setPeer*Requirement` operations belong here rather than on a channel.
public protocol XPCConnectionServiceDelegate: XPCServiceDelegate {
  /// Installed before audit, once per incoming connection. When non-nil,
  /// the audit hook must not install another native requirement.
  var peerCodeSigningRequirement: String? { get }
  func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool
  /// Called after cancellation for an explicit rejection or audit failure.
  /// A kernel rejection after activation is reported as `peerDidEnd` instead.
  func didRejectConnection(_ connection: XPCConnection, error: (any Error)?)
}

extension XPCConnectionServiceDelegate {
  public var peerCodeSigningRequirement: String? { nil }
  public func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool { true }
  public func didRejectConnection(_ connection: XPCConnection, error: (any Error)?) {}
}

/// Native Listener admission, before the library accepts the request.
/// The request is borrowed for this synchronous decision: do not call its
/// `accept`/`reject` methods or retain it. The acceptor owns the native decision
/// and handler installation; returning false causes a native rejection.
public protocol XPCSessionServiceDelegate: XPCServiceDelegate {
  func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws -> Bool
  func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, error: (any Error)?)
}

extension XPCSessionServiceDelegate {
  public func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws
    -> Bool
  {
    true
  }
  public func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, error: (any Error)?
  ) {}
}

/// Closure-based C delegate. Custom types can conform directly instead.
public struct XPCConnectionServiceConfiguration: XPCConnectionServiceDelegate {
  public let peerCodeSigningRequirement: String?
  private let shouldAccept: @Sendable (XPCConnection) throws -> Bool
  private let onReject: @Sendable (XPCConnection, (any Error)?) -> Void
  private let onAccept: @Sendable (XPCChannel) -> Void
  private let onEnd: @Sendable (XPCChannel) -> Void
  private let onBindingFailure: @Sendable (XPCChannel, (any Error)?) -> Void
  private let onShutdown: @Sendable () -> Void

  public init(
    peerCodeSigningRequirement: String? = nil,
    shouldAccept: @escaping @Sendable (XPCConnection) throws -> Bool = { _ in true },
    onConnectionReject: @escaping @Sendable (XPCConnection, (any Error)?) -> Void = { _, _ in },
    onPeerAccept: @escaping @Sendable (XPCChannel) -> Void = { _ in },
    onPeerEnd: @escaping @Sendable (XPCChannel) -> Void = { _ in },
    onPeerReject: @escaping @Sendable (XPCChannel, (any Error)?) -> Void = { _, _ in },
    onShutdown: @escaping @Sendable () -> Void = {}
  ) {
    self.peerCodeSigningRequirement = peerCodeSigningRequirement
    self.shouldAccept = shouldAccept
    self.onReject = onConnectionReject
    self.onAccept = onPeerAccept
    self.onEnd = onPeerEnd
    self.onBindingFailure = onPeerReject
    self.onShutdown = onShutdown
  }

  public func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool {
    try shouldAccept(connection)
  }
  public func didRejectConnection(_ connection: XPCConnection, error: (any Error)?) {
    onReject(connection, error)
  }
  public func didAcceptPeer(_ peer: XPCChannel) { onAccept(peer) }
  public func peerDidEnd(_ peer: XPCChannel) { onEnd(peer) }
  public func didRejectPeer(_ peer: XPCChannel, error: (any Error)?) {
    onBindingFailure(peer, error)
  }
  public func serviceWillShutdown() { onShutdown() }
}

/// Closure-based Session delegate; has no C identity or string-requirement API.
public struct XPCSessionServiceConfiguration: XPCSessionServiceDelegate {
  private let shouldAccept: @Sendable (XPCListener.IncomingSessionRequest) throws -> Bool
  private let onReject: @Sendable (XPCListener.IncomingSessionRequest, (any Error)?) -> Void
  private let onAccept: @Sendable (XPCChannel) -> Void
  private let onEnd: @Sendable (XPCChannel) -> Void
  private let onBindingFailure: @Sendable (XPCChannel, (any Error)?) -> Void
  private let onShutdown: @Sendable () -> Void

  public init(
    shouldAccept: @escaping @Sendable (XPCListener.IncomingSessionRequest) throws -> Bool = { _ in
      true
    },
    onSessionReject:
      @escaping @Sendable (XPCListener.IncomingSessionRequest, (any Error)?) -> Void = { _, _ in },
    onPeerAccept: @escaping @Sendable (XPCChannel) -> Void = { _ in },
    onPeerEnd: @escaping @Sendable (XPCChannel) -> Void = { _ in },
    onPeerReject: @escaping @Sendable (XPCChannel, (any Error)?) -> Void = { _, _ in },
    onShutdown: @escaping @Sendable () -> Void = {}
  ) {
    self.shouldAccept = shouldAccept
    self.onReject = onSessionReject
    self.onAccept = onPeerAccept
    self.onEnd = onPeerEnd
    self.onBindingFailure = onPeerReject
    self.onShutdown = onShutdown
  }

  public func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws
    -> Bool
  {
    try shouldAccept(request)
  }
  public func didRejectSessionRequest(
    _ request: XPCListener.IncomingSessionRequest, error: (any Error)?
  ) {
    onReject(request, error)
  }
  public func didAcceptPeer(_ peer: XPCChannel) { onAccept(peer) }
  public func peerDidEnd(_ peer: XPCChannel) { onEnd(peer) }
  public func didRejectPeer(_ peer: XPCChannel, error: (any Error)?) {
    onBindingFailure(peer, error)
  }
  public func serviceWillShutdown() { onShutdown() }
}

package func rejectXPCConnection(
  _ connection: XPCConnection, delegate: any XPCConnectionServiceDelegate,
  eventLog: XPCServiceEventLog?, error: (any Error)?
) {
  connection.activate()
  connection.cancel()
  eventLog?.append(.didRejectConnection, error: error)
  delegate.didRejectConnection(connection, error: error)
}

package func admitXPCConnection(
  _ connection: XPCConnection, delegate: any XPCConnectionServiceDelegate,
  eventLog: XPCServiceEventLog? = nil
) -> Bool {
  do {
    try connection.applyPeerCodeSigningRequirement(delegate.peerCodeSigningRequirement)
    eventLog?.append(.shouldAcceptPeer)
    if try delegate.shouldAcceptConnection(connection) {
      connection.addPeerCodeSigningErrorHandler { connection.cancel() }
      return true
    }
    rejectXPCConnection(connection, delegate: delegate, eventLog: eventLog, error: nil)
  } catch {
    rejectXPCConnection(connection, delegate: delegate, eventLog: eventLog, error: error)
  }
  return false
}
