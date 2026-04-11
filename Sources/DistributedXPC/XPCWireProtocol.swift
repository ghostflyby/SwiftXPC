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
public struct XPCReplyEnvelope: Sendable {
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

@available(macOS 13.0, *)
extension XPCReplyEnvelope {
  func write(to dictionary: inout XPCDictionary) throws(XPCMarshalError) {
    dictionary["version"] = try version.marshal()
    dictionary["kind"] = try kind.marshal()
    dictionary["payload"] = payload
  }
}

@available(macOS 15, *)
extension XPCReplyEnvelope {
  func decodeReturnValue<Res, Err>(
    throwing errorType: Err.Type,
    returning returnType: Res.Type
  ) throws -> Res
  where Res: XPCMarshal, Err: Error {
    switch kind {
    case .returnValue:
      guard let payload else {
        throw XPCRemoteCallError.missingPayload(.returnValue)
      }
      return try Res.unmarshal(from: payload)
    case .returnVoid:
      throw XPCRemoteCallError.invalidReplyKind(expected: .returnValue, actual: .returnVoid)
    case .throwError:
      guard let payload else {
        throw XPCRemoteCallError.missingPayload(.throwError)
      }
      throw try decodeThrownError(payload, as: errorType)
    }
  }

  func decodeReturnVoid<Err>(throwing errorType: Err.Type) throws
  where Err: Error {
    switch kind {
    case .returnVoid:
      return
    case .returnValue:
      throw XPCRemoteCallError.invalidReplyKind(expected: .returnVoid, actual: .returnValue)
    case .throwError:
      guard let payload else {
        throw XPCRemoteCallError.missingPayload(.throwError)
      }
      throw try decodeThrownError(payload, as: errorType)
    }
  }

  private func decodeThrownError<Err: Error>(_ object: XPCObject, as errorType: Err.Type) throws -> Error {
    guard let marshalableErrorType = errorType as? any (XPCMarshal & Error).Type else {
      throw XPCRemoteCallError.unsupportedThrownErrorType(String(describing: errorType))
    }
    return try marshalableErrorType.unmarshal(from: object)
  }
}
