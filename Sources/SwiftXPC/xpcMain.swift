// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

@MainActor
private var mainHandler: @Sendable (XPCConnection) -> Void = { _ in }

@MainActor
private func m(_ c: xpc_connection_t) {
  let connection = XPCConnection(xpc_object: c)
  mainHandler(connection)
}

@MainActor
public func xpcMain(_ handler: @escaping @Sendable (_ connection: XPCConnection) -> Void) -> Never {
  mainHandler = handler
  xpc_main { c in m(c) }
}

extension XPCConnection {
  /// An asynchronous stream of incoming XPC connections to this service.
  @MainActor
  public static var incoming: AsyncStream<XPCConnection> {
    AsyncStream { continuation in
      xpcMain { connection in
        continuation.yield(connection)
      }
    }
  }
}
