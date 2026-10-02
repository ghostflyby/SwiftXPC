// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import XPC

/// Explicit backend selection for channel and listener construction.
/// Endpoints are interoperable across backends.
public enum XPCChannelTransport: CaseIterable, Sendable {
  case cConnection
  case session

  /// Dials `endpoint` (a `wireEndpoint` token, `XPC_TYPE_ENDPOINT`) over this
  /// transport. Endpoints are backend-agnostic: either transport can dial an
  /// endpoint minted by the other.
  public func channel(dialing endpoint: xpc_object_t) throws(XPCMarshalError) -> XPCChannel {
    guard xpc_get_type(endpoint) == XPC_TYPE_ENDPOINT else {
      throw typeMismatch(expected: XPC_TYPE_ENDPOINT, actual: xpc_get_type(endpoint))
    }
    switch self {
    case .cConnection: return XPCChannel(try XPCConnection.unmarshal(from: endpoint))
    case .session: return XPCChannel(session: XPCSessionChannel(dialing: XPCEndpoint(endpoint)))
    }
  }

  /// Dials the launchd-advertised mach service `service` over this
  /// transport (a named re-dialable connection on the C backend; a mach
  /// session on the session backend).
  public func channel(machService service: String) -> XPCChannel {
    switch self {
    case .cConnection: return XPCChannel(XPCConnection(machServiceName: service))
    case .session: return XPCChannel(session: XPCSessionChannel(machServiceName: service))
    }
  }

  /// Creates an acceptor over this transport: anonymous when `service` is
  /// nil, or serving the launchd-advertised mach service name (a
  /// `MachServices` entry in the job's launchd configuration) otherwise.
  public func acceptor(service: String? = nil) throws -> XPCChannelAcceptor {
    try XPCChannelAcceptor(transport: self, service: service)
  }
}
