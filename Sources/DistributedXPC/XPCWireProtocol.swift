// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

enum XPCWireProtocol {
  public static let currentVersion: UInt64 = 1
}

@available(macOS 13.0, *)
@XPCMarshal
struct XPCInvocationMessage {
  public let version: UInt64
  public let method: String
  public let actorID: XPCActorID
  public let target: RemoteCallTarget
  public let arguments: XPCArray

  init(
    version: UInt64 = XPCWireProtocol.currentVersion,
    method: String,
    actorID: XPCActorID,
    target: RemoteCallTarget,
    arguments: XPCArray
  ) {
    self.version = version
    self.method = method
    self.actorID = actorID
    self.target = target
    self.arguments = arguments
  }
}

@available(macOS 13.0, *)
@XPCMarshal
enum XPCReplyKind: Sendable, Hashable, Equatable {
  case returnValue
  case returnVoid
  case throwError
}

@available(macOS 13.0, *)
@XPCMarshal
struct XPCReplyEnvelope: Sendable {
  public let version: UInt64
  public let kind: XPCReplyKind
  public let payload: XPCObject?

  init(
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
    returning returnType: Res.Type,
    fallbackErrorType: (any ErrorXPCMarshal.Type)? = nil
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
      throw try decodeThrownError(payload, as: errorType, fallback: fallbackErrorType)
    }
  }

  func decodeReturnVoid<Err>(
    throwing errorType: Err.Type,
    fallbackErrorType: (any ErrorXPCMarshal.Type)? = nil
  ) throws
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
      throw try decodeThrownError(payload, as: errorType, fallback: fallbackErrorType)
    }
  }

  private func decodeThrownError<Err: Error>(
    _ object: XPCObject,
    as errorType: Err.Type,
    fallback fallbackErrorType: (any ErrorXPCMarshal.Type)?
  ) throws -> Error {
    if let marshalableErrorType = errorType as? any ErrorXPCMarshal.Type {
      return try marshalableErrorType.unmarshal(from: object)
    }

    if let fallbackErrorType {
      return try fallbackErrorType.unmarshal(from: object)
    }

    throw XPCRemoteCallError.unsupportedThrownErrorType(String(describing: errorType))
  }
}
