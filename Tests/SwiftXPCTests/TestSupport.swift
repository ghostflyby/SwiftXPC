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

/// An in-process XPC channel carrying real mach traffic between a server side
/// hosted on an anonymous listener and a client side dialed from its endpoint,
/// so root-actor tests need no launchd-managed service. A thin test harness
/// over the public `xpcTest(_:_:)` API, adding a 10 s watchdog so a lost
/// reply fails the pending call instead of hanging the suite. It cannot
/// exercise launchd-relaunch reconnection, which only named-service
/// connections have.
///
/// The coordinator has already activated the client channel.
/// `close()` cancels every connection; it also runs from `deinit` and the
/// watchdog.
final class RootChannel<Root: XPCRootActor>: Sendable {
  let harness: XPCRootTestCoordinator<Root>
  var host: XPCServiceHost { harness.host }
  /// The coordinator's client channel is C-backed, so the C-specific test
  /// surface (setEventHandler, the sync send) stays reachable.
  var client: XPCChannel { harness.client.connection }

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

  /// Dials a fresh, inactive client channel to the same listener.
  func makeClient() throws -> XPCChannel {
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

/// Directly drives the production actor-service assembly with multiple peers.
final class ActorServiceChannel<Root: XPCRootActor>: @unchecked Sendable {
  let service: XPCActorService<Root>
  var server: XPCServiceHost { service.host }
  let client: XPCChannel
  private let listener: XPCConnection
  private let watchdog: DispatchWorkItem

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate = XPCServiceConfiguration(),
    eventLog: XPCServiceEventLog? = nil
  ) throws {
    let listener = XPCConnection(name: nil)
    let service = XPCActorService(rootType, delegate, eventLog: eventLog)
    let server = service.host
    listener.setEventHandler { object in
      guard xpc_get_type(object) == XPC_TYPE_CONNECTION else { return }
      server.accept(XPCChannel(XPCConnection(xpc_object: object)))
    }
    listener.activate()

    let client = XPCChannel(try XPCConnection.unmarshal(from: listener.marshal()))
    self.listener = listener
    self.service = service
    self.client = client
    watchdog = DispatchWorkItem {
      client.cancel()
      listener.cancel()
      server.cancel()
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
  }

  /// Dials a fresh, inactive client connection to the same listener.
  func makeClient() throws -> XPCChannel {
    XPCChannel(try XPCConnection.unmarshal(from: listener.marshal()))
  }

  func close() {
    watchdog.cancel()
    client.cancel()
    listener.cancel()
    service.cancel()
  }

  deinit { close() }
}
