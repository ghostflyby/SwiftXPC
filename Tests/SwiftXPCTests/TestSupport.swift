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
/// so root-actor tests need no launchd-managed service. A thin test harness
/// over the public `xpcTest(_:_:)` API, adding a 10 s watchdog so a lost
/// reply fails the pending call instead of hanging the suite. It cannot
/// exercise launchd-relaunch reconnection, which only named-service
/// connections have.
///
/// The client connection starts inactive: activate it via
/// `XPCRootActor.connect(using:)` or manually before sending on it.
/// `close()` cancels every connection; it also runs from `deinit` and the
/// watchdog.
final class RootChannel<Root: XPCRootActor>: @unchecked Sendable {
  let harness: XPCRootTestCoordinator<Root>
  var host: XPCServiceHost { harness.host }
  var client: XPCConnection { harness.client.connection }

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate = XPCServiceConfiguration(),
    eventLog: XPCServiceEventLog? = nil
  ) throws {
    harness = try xpcTest(
      rootType,
      delegate,
      eventLog: eventLog,
      watchdog: .seconds(10))
  }

  /// Dials a fresh, inactive client connection to the same listener.
  func makeClient() throws -> XPCConnection {
    try harness.makeClient()
  }

  /// Cancels the server-side peer connection as if the service dropped this
  /// client; the client observes its channel going down.
  func killServerPeer() {
    harness.dropServerPeer()
  }

  func close() {
    harness.close()
  }

  deinit { close() }
}

/// Drives the **production** singleton path: an `XPCRootActorServer` binds
/// `Root.shared` on the process-global service host, exactly as a hosted
/// `xpcMain` service does. The service host is process-global — one root
/// type per test process — so suites using this fixture must be
/// `.serialized`.
final class SharedSingletonChannel<Root: XPCRootActor>: @unchecked Sendable {
  let server: XPCRootActorServer<Root>
  let client: XPCConnection
  private let listener: XPCConnection
  private let watchdog: DispatchWorkItem

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate = XPCServiceConfiguration(),
    eventLog: XPCServiceEventLog? = nil
  ) throws {
    let listener = XPCConnection(name: nil)
    let server = XPCRootActorServer<Root>(rootType, delegate, eventLog: eventLog)
    listener.setEventHandler { object in
      guard xpc_get_type(object.xpc_object) == XPC_TYPE_CONNECTION else { return }
      server.accept(XPCConnection(xpc_object: object.xpc_object))
    }
    listener.activate()

    let client = try XPCConnection.unmarshal(from: listener.marshal())
    self.listener = listener
    self.server = server
    self.client = client
    watchdog = DispatchWorkItem {
      client.cancel()
      listener.cancel()
      server.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  }

  /// Dials a fresh, inactive client connection to the same listener.
  func makeClient() throws -> XPCConnection {
    try XPCConnection.unmarshal(from: listener.marshal())
  }

  func close() {
    watchdog.cancel()
    client.cancel()
    listener.cancel()
    server.cancel()
  }

  deinit { close() }
}
