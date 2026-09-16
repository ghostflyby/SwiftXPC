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

/// Polls `condition` until it holds or the deadline passes, returning the
/// final value. For events that race with async XPC teardown.
func pollUntil(
  seconds: Double = 2,
  intervalMilliseconds: Int = 20,
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
  }
  return await condition()
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
@available(macOS 15, *)
final class RootChannel<Root: XPCRootActor>: @unchecked Sendable {
  let harness: XPCRootTestHarness<Root>
  var server: XPCRootActorServer<Root> { harness.server }
  var client: XPCConnection { harness.channel.connection }
  private let watchdog: DispatchWorkItem

  init(
    _ rootType: Root.Type,
    _ delegate: any XPCServiceDelegate<Root> = XPCServiceConfiguration<Root>()
  ) throws {
    let harness = try xpcTest(rootType, delegate)
    self.harness = harness
    watchdog = DispatchWorkItem { harness.close() }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: watchdog)
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
    watchdog.cancel()
    harness.close()
  }

  deinit { close() }
}
