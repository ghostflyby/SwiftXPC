// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Distributed
import Foundation
import Synchronization
import SwiftXPC

/// The session-backend service host: a slim mirror of `XPCServiceHost` for
/// **non-privileged** LaunchDaemon-style services served over
/// `XPCSession`/`XPCListener` channels.
///
/// Deliberately smaller than `XPCServiceHost`: the session model has no peer
/// identity accessors and no pre-26 peer validation, so there are no
/// code-signing or audit hooks here. Services that need caller validation
/// must use the C backend. Peer hooks: `shouldAcceptPeer` may decline a
/// channel (it is cancelled), `didAcceptPeer`/`peerDidEnd` observe its
/// lifetime, and `serviceWillShutdown` runs before the shutdown completion.
public protocol XPCSessionServiceDelegate: Sendable {
  func serviceWillStart(host: XPCSessionServiceHost)
  func shouldAcceptPeer(_ channel: any XPCMessageChannel) -> Bool
  func didAcceptPeer(_ channel: any XPCMessageChannel)
  func peerDidEnd(_ channel: any XPCMessageChannel)
  func serviceWillShutdown()
}

public struct XPCSessionServiceConfiguration: XPCSessionServiceDelegate, Sendable {
  public init() {}
  public func serviceWillStart(host: XPCSessionServiceHost) {}
  public func shouldAcceptPeer(_ channel: any XPCMessageChannel) -> Bool { true }
  public func didAcceptPeer(_ channel: any XPCMessageChannel) {}
  public func peerDidEnd(_ channel: any XPCMessageChannel) {}
  public func serviceWillShutdown() {}
}

/// Hosts a root actor over session channels. See `xpcSessionMain` for the
/// process entry point.
public final class XPCSessionServiceHost: Sendable {
  private let peerHandler = Mutex<(@Sendable (any XPCMessageChannel) throws -> Void)?>(nil)
  private let shutdownCompletion = Mutex<(@Sendable () -> Void)?>(nil)
  private let channels = Mutex<[UUID: any XPCMessageChannel]>([:])
  private let shutdownRequested = Mutex(false)

  public init() {}

  /// Installs the peer binding; a throw declines (and cancels) the channel.
  public func setPeerHandler(
    _ handler: @escaping @Sendable (any XPCMessageChannel) throws -> Void
  ) {
    peerHandler.withLock { $0 = handler }
  }

  /// Runs once after a cooperative shutdown finishes.
  public func setShutdownCompletion(_ handler: @escaping @Sendable () -> Void) {
    shutdownCompletion.withLock { $0 = handler }
  }

  /// Admits an accepted channel: runs the peer handler, registers the
  /// channel, and activates it. Throw from the peer handler to decline.
  public func accept(_ channel: any XPCMessageChannel) {
    do {
      try peerHandler.withLock({ $0 })?(channel)
    } catch {
      channel.cancel()
      return
    }
    let id = UUID()
    channels.withLock { channels in
      channels[id] = channel
      channel.addInvalidationHandler { [weak self] in
        guard let self else { return }
        _ = self.channels.withLock { $0.removeValue(forKey: id) }
        self.didEnd(channel)
      }
    }
    didEnd(channel)
    channel.activate()
  }

  private func didEnd(_ channel: any XPCMessageChannel) {
    peerDidEndHook.withLock { $0 }?(channel)
  }

  private let peerDidEndHook = Mutex<(@Sendable (any XPCMessageChannel) -> Void)?>(nil)

  /// Registers the `peerDidEnd` notification hook.
  public func onPeerDidEnd(_ handler: @escaping @Sendable (any XPCMessageChannel) -> Void) {
    peerDidEndHook.withLock { $0 = handler }
  }

  /// Cooperatively shuts down: cancels every accepted channel and runs the
  /// shutdown completion. Idempotent.
  public func requestShutdown() {
    let first = shutdownRequested.withLock { current -> Bool in
      if current { return false }
      current = true
      return true
    }
    guard first else { return }
    let channels = self.channels.withLock { channels -> [any XPCMessageChannel] in
      let values = Array(channels.values)
      channels.removeAll()
      return values
    }
    for channel in channels { channel.cancel() }
    shutdownCompletion.withLock { $0 }?()
  }
}

@MainActor
extension XPCSessionServiceHost {
  /// The actor-flavored bootstrap: binds every accepted channel to
  /// `Root.shared` under `XPCActorID.root`, mirroring the C host's
  /// `XPCServiceHost(rootType, delegate)` integration. Actor-initiated
  /// `requestServiceShutdown()` routes to `requestShutdown()`.
  public func serve<Root: XPCRootActor>(_ rootType: Root.Type) {
    setPeerHandler { [weak self] channel in
      let serviceHost = XPCDistributedActorSystem.serviceHost
      // Reserve before the first `shared` access so lazy creation assigns
      // the reserved identity (one root actor type per process).
      serviceHost.reserveRootID()
      serviceHost.setServiceShutdownHandler { [weak self] in
        self?.requestShutdown()
      }
      let root = Root.shared
      guard root.id == .root else {
        serviceHost.clearRootReservation()
        throw XPCDispatchError.unknownActor(.root)
      }
      serviceHost.bind(channel, to: root)
    }
  }
}

/// The session-backend process entry point: serves `Root.shared` over an
/// `XPCListener` bound to the launchd mach service name `service`, and never
/// returns. Requires the job's launchd configuration to advertise the mach
/// service; bundled-`.xpc` services are C-backend-only.
@MainActor
public func xpcSessionMain<Root: XPCRootActor>(
  service: String,
  _ rootType: Root.Type = Root.self,
  delegate: some XPCSessionServiceDelegate = XPCSessionServiceConfiguration()
) -> Never {
  let host = XPCSessionServiceHost()
  host.serve(rootType)
  host.setShutdownCompletion { exit(0) }
  delegate.serviceWillStart(host: host)
  do {
    let acceptor = try XPCListenerAcceptor(service: service)
    acceptor.setAcceptHandler { channel in
      if delegate.shouldAcceptPeer(channel) {
        host.accept(channel)
        delegate.didAcceptPeer(channel)
      } else {
        channel.cancel()
      }
    }
    acceptor.activate()
  } catch {
    FileHandle.standardError.write(
      Data("xpcSessionMain: cannot activate listener for \(service): \(error)\n".utf8))
    exit(1)
  }
  dispatchMain()
}
