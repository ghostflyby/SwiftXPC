// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Synchronization
import XPC

private let mainHandler = Mutex<@Sendable (XPCConnection) -> Void>({ _ in })

private func handleIncomingConnection(_ connection: xpc_connection_t) {
  let wrapped = XPCConnection(xpc_object: connection)
  // xpc_main forwards listener-level error objects too; only real peer
  // connections carry accept semantics.
  guard wrapped.isConnectionObject else { return }
  let handler = mainHandler.withLock { $0 }
  handler(wrapped)
}

/// Runs the XPC service event loop, invoking `handler` for every accepted
/// peer connection. Never returns. Must run on the main thread in a
/// launchd-managed XPC service; invoking it in an ordinary process aborts.
///
/// For distributed actor services prefer the `xpcMain` overloads in
/// `DistributedXPC`, which layer root-actor bootstrapping on top of this
/// entry point.
@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCConnection) -> Void) -> Never {
  xpcMain(handler, onReady: {})
}

// Install the native reception bridge before launching asynchronous actor
// preparation. The bootstrap callback runs outside the global handler lock.
@MainActor
package func xpcMain(
  _ handler: @escaping @Sendable (XPCConnection) -> Void,
  onReady: @Sendable () -> Void
) -> Never {
  precondition(Thread.isMainThread, "xpcMain must run on the OS main thread")
  mainHandler.withLock { $0 = handler }
  onReady()
  xpc_main(handleIncomingConnection)
}
