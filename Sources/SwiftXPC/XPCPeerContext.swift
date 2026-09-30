// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import XPC

/// Identity and audit surface of an accepted channel: everything a host's
/// peer hooks may inspect.
///
/// Peer identity (pid/euid/egid/asid) exists only on the C backend — the
/// session model has no counterpart accessors — so every identity property
/// is nil on session-backed peers. `connection` is the C escape hatch for
/// APIs that only exist there (for example
/// `addTerminationImminentHandler`).
public struct XPCPeerContext: Sendable {
  /// The accepted channel.
  public let channel: any XPCMessageChannel

  /// The transport backend that carried the accepted channel.
  public let transport: XPCChannelTransport

  /// Process identifier of the peer, or nil on the session backend.
  public let pid: pid_t?

  /// Effective user ID of the peer, or nil on the session backend.
  public let euid: uid_t?

  /// Effective group ID of the peer, or nil on the session backend.
  public let egid: gid_t?

  /// Audit session ID of the peer, or nil on the session backend.
  public let asid: au_asid_t?

  /// The C-backed connection, when the peer arrived over the C transport —
  /// the escape hatch for C-only surface (`pid` family already mirrors the
  /// identity accessors). Nil on the session backend.
  public var connection: XPCConnection? {
    channel as? XPCConnection
  }

  init(
    channel: any XPCMessageChannel,
    transport: XPCChannelTransport,
    pid: pid_t?,
    euid: uid_t?,
    egid: gid_t?,
    asid: au_asid_t?
  ) {
    self.channel = channel
    self.transport = transport
    self.pid = pid
    self.euid = euid
    self.egid = egid
    self.asid = asid
  }

  static func make(_ channel: any XPCMessageChannel) -> XPCPeerContext {
    if let connection = channel as? XPCConnection {
      return XPCPeerContext(
        channel: channel, transport: .cConnection,
        pid: connection.pid, euid: connection.euid, egid: connection.egid,
        asid: connection.asid)
    }
    return XPCPeerContext(
      channel: channel, transport: .session,
      pid: nil, euid: nil, egid: nil, asid: nil)
  }
}
