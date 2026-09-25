// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

enum XPCWireProtocol {
  public static let currentVersion: UInt64 = 1
}

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

@XPCMarshal
public enum XPCReplyKind: Sendable, Hashable, Equatable {
  /// The reply carries a return value.
  case returnValue
  case returnVoid
  case throwError
}

struct XPCReplyEnvelope: @unchecked Sendable {
  public let version: UInt64
  public let kind: XPCReplyKind
  public let payload: xpc_object_t?

  init(
    version: UInt64 = XPCWireProtocol.currentVersion,
    kind: XPCReplyKind,
    payload: xpc_object_t? = nil
  ) {
    self.version = version
    self.kind = kind
    self.payload = payload
  }
}

// 手写线缆编解码而非 `@XPCMarshal`:`payload: xpc_object_t?` 必须区分三态——
// 无载荷(`.returnVoid`)、载荷为 null(返回值为 `Optional.none`)与普通载荷;
// 宏生成的可选属性解码把"present-but-null"折叠成 nil,使任何 nil Optional
// 返回值在客户端表现为 `missingPayload(.returnValue)`。

extension XPCReplyEnvelope: XPCMarshal {
  func write(to dictionary: inout XPCDictionary) throws(XPCMarshalError) {
    dictionary["version"] = try version.marshal()
    dictionary["kind"] = try kind.marshal()
    dictionary["hasPayload"] = try (payload != nil).marshal()
    if let payload {
      dictionary["payload"] = payload
    } else {
      dictionary.removeValue(forKey: "payload")
    }
  }

  func marshal() throws(XPCMarshalError) -> xpc_object_t {
    var dictionary = XPCDictionary()
    try write(to: &dictionary)
    return dictionary.xpcObject
  }

  static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> XPCReplyEnvelope {
    let kindType = SwiftXPC.xpcGetType(object)
    guard kindType == SwiftXPC.xpcTypeDictionary else {
      throw XPCMarshalError.typeMismatch(
        expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeDictionary)),
        actual: String(cString: SwiftXPC.xpcTypeGetName(kindType))
      )
    }
    let dictionary = XPCDictionary(object)
    guard let versionObject = dictionary["version", as: xpc_object_t.self] else {
      throw XPCMarshalError.missingKey("version")
    }
    let version = try UInt64.unmarshal(from: versionObject)
    guard version == XPCWireProtocol.currentVersion else {
      throw .unsupportedProtocolVersion(expected: XPCWireProtocol.currentVersion, actual: version)
    }
    guard let kindObject = dictionary["kind", as: xpc_object_t.self] else {
      throw XPCMarshalError.missingKey("kind")
    }
    let kind = try XPCReplyKind.unmarshal(from: kindObject)

    let hasPayload: Bool
    if let hasPayloadObject = dictionary["hasPayload", as: xpc_object_t.self] {
      hasPayload = try Bool.unmarshal(from: hasPayloadObject)
    } else {
      // 旧格式(无 hasPayload 标记):payload 键存在与否即载荷有无。
      hasPayload = dictionary["payload", as: xpc_object_t.self] != nil
    }
    let payload = hasPayload ? dictionary["payload", as: xpc_object_t.self] : nil
    return XPCReplyEnvelope(version: version, kind: kind, payload: payload)
  }
}

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
    _ object: xpc_object_t,
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

extension RemoteCallTarget: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> xpc_object_t { try identifier.marshal() }
  public static func unmarshal(from object: xpc_object_t) throws(XPCMarshalError) -> RemoteCallTarget {
    .init(try .unmarshal(from: object))
  }
}
