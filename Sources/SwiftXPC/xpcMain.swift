// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Synchronization
import XPC

private let mainHandler = Mutex<@Sendable (XPCChannel) -> Void>({ _ in })

private func handleIncomingConnection(_ connection: xpc_connection_t) {
  let wrapped = XPCConnection(xpc_object: connection)
  // xpc_main forwards listener-level error objects too; only real peer
  // connections carry accept semantics.
  guard wrapped.isConnectionObject else { return }
  mainHandler.withLock { $0 }(XPCChannel(wrapped))
}

/// Runs the XPC service event loop, invoking `handler` for every accepted
/// peer connection. Never returns. Must run on the main thread.
///
/// For distributed actor services prefer the `xpcMain` overloads in
/// `DistributedXPC`, which layer root-actor bootstrapping on top of this
/// entry point.
@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCChannel) -> Void) -> Never {
  mainHandler.withLock { $0 = handler }
  xpc_main(handleIncomingConnection)
}
