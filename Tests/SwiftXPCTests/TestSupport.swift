// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Dispatch
import DistributedXPC
import Foundation
import Synchronization
import Testing
import XPC

@testable import SwiftXPC

typealias XPCEquatable = XPCMarshal & Equatable

func roundTrip<T: XPCEquatable>(_ value: T) throws {
  let encoded = try value.marshal()
  let decoded = try T.unmarshal(from: encoded)
  assert(value == decoded)
}

/// Creates an activated, idle connection for in-process systems that never
/// carry XPC traffic. A never-activated connection traps in libxpc when its
/// last reference is released, so test-only systems must activate their dummies.
func makeIdleConnection() -> XPCConnection {
  let connection = XPCConnection(name: nil)
  connection.setEventHandler { _ in }
  connection.activate()
  return connection
}

/// An in-process XPC channel carrying real mach traffic between a server side
/// hosted on an anonymous listener and a client side dialed from its endpoint,
/// so root-actor tests need no launchd-managed service. It cannot exercise
/// launchd-relaunch reconnection, which only named-service connections have.
///
/// The client connection starts inactive: activate it via
/// `XPCRootActor.connect(using:)`, `XPCRootConnection.connect(using:)`, or
/// manually before sending on it. `close()` cancels every connection; it also
/// runs from `deinit` and a 10 s watchdog, so a lost reply fails the pending
/// call instead of hanging the suite.
@available(macOS 15, *)
final class RootChannel<Root: XPCRootActor>: @unchecked Sendable {
  let listener: XPCConnection
  let client: XPCConnection
  let server: XPCRootActorServer<Root>

  /// Retains the wrapper of the latest server-side peer so tests can simulate
  /// the service dropping the client.
  private final class ServerPeerBox: @unchecked Sendable {
    let peer = Mutex<XPCConnection?>(nil)
  }
  private let serverPeer: ServerPeerBox
  private let watchdog: DispatchWorkItem

  init(
    _ rootType: Root.Type,
    shouldAccept: (@Sendable (XPCConnection) -> Bool)? = nil,
    onPeerAccept: (@Sendable (XPCConnection) -> Void)? = nil,
    onPeerEnd: (@Sendable (XPCConnection) -> Void)? = nil
  ) throws {
    let listener = XPCConnection(name: nil)
    let server = XPCRootActorServer<Root>(
      shouldAccept: shouldAccept ?? { _ in true },
      onPeerAccept: onPeerAccept,
      onPeerEnd: onPeerEnd
    )
    let serverPeer = ServerPeerBox()
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      let peer = XPCConnection(xpc_object: object.xpc_object)
      serverPeer.peer.withLock { $0 = peer }
      server.accept(peer)
    }
    listener.activate()

    let client = try XPCConnection.unmarshal(from: listener.marshal())
    self.listener = listener
    self.client = client
    self.server = server
    self.serverPeer = serverPeer
    watchdog = DispatchWorkItem {
      client.cancel()
      listener.cancel()
      server.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  }

  /// Cancels the server-side peer connection as if the service dropped this
  /// client; the client observes its channel going down.
  func killServerPeer() {
    serverPeer.peer.withLock { $0 }?.cancel()
  }

  func close() {
    watchdog.cancel()
    client.cancel()
    listener.cancel()
    server.cancel()
  }

  deinit { close() }
}
