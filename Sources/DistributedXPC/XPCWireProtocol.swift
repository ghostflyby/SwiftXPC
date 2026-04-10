// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

public enum XPCWireProtocol {
  public static let currentVersion: UInt64 = 1
}

@available(macOS 13.0, *)
@XPCMarshal
public struct XPCInvocationMessage {
  public let version: UInt64
  public let actorID: XPCActorID
  public let target: RemoteCallTarget
  public let arguments: XPCArray

  public init(
    version: UInt64 = XPCWireProtocol.currentVersion,
    actorID: XPCActorID,
    target: RemoteCallTarget,
    arguments: XPCArray
  ) {
    self.version = version
    self.actorID = actorID
    self.target = target
    self.arguments = arguments
  }
}

@available(macOS 13.0, *)
@XPCMarshal
public enum XPCReplyKind: Sendable, Hashable, Equatable {
  case returnValue
  case returnVoid
  case throwError
}

@available(macOS 13.0, *)
@XPCMarshal
public struct XPCReplyEnvelope {
  public let version: UInt64
  public let kind: XPCReplyKind
  public let payload: XPCObject?

  public init(
    version: UInt64 = XPCWireProtocol.currentVersion,
    kind: XPCReplyKind,
    payload: XPCObject? = nil
  ) {
    self.version = version
    self.kind = kind
    self.payload = payload
  }
}
