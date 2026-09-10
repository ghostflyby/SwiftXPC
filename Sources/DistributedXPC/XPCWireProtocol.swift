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
public enum XPCReplyKind: Sendable, Hashable, Equatable {
  /// The reply carries a return value.
  case returnValue
  case returnVoid
  case throwError
}

@available(macOS 13.0, *)
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

// 手写线缆编解码而非 `@XPCMarshal`:`payload: XPCObject?` 必须区分三态——
// 无载荷(`.returnVoid`)、载荷为 null(返回值为 `Optional.none`)与普通载荷;
// 宏生成的可选属性解码把"present-but-null"折叠成 nil,使任何 nil Optional
// 返回值在客户端表现为 `missingPayload(.returnValue)`。
@available(macOS 13.0, *)
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

  func marshal() throws(XPCMarshalError) -> XPCObject {
    var dictionary = XPCDictionary()
    try write(to: &dictionary)
    return XPCObject(xpc_object: dictionary.xpc_object)
  }

  static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> XPCReplyEnvelope {
    let kindType = SwiftXPC.xpcGetType(object.xpc_object)
    guard kindType == SwiftXPC.xpcTypeDictionary else {
      throw XPCMarshalError.typeMismatch(
        expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeDictionary)),
        actual: String(cString: SwiftXPC.xpcTypeGetName(kindType))
      )
    }
    let dictionary = XPCDictionary(xpc_object: object.xpc_object)
    guard let versionObject = dictionary["version"] else {
      throw XPCMarshalError.missingKey("version")
    }
    let version = try UInt64.unmarshal(from: versionObject)
    guard let kindObject = dictionary["kind"] else {
      throw XPCMarshalError.missingKey("kind")
    }
    let kind = try XPCReplyKind.unmarshal(from: kindObject)

    let hasPayload: Bool
    if let hasPayloadObject = dictionary["hasPayload"] {
      hasPayload = try Bool.unmarshal(from: hasPayloadObject)
    } else {
      // 旧格式(无 hasPayload 标记):payload 键存在与否即载荷有无。
      hasPayload = dictionary["payload"] != nil
    }
    let payload = hasPayload ? dictionary["payload"] : nil
    return XPCReplyEnvelope(version: version, kind: kind, payload: payload)
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

@available(macOS 13.0, *)
extension RemoteCallTarget: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject { try identifier.marshal() }
  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> RemoteCallTarget {
    .init(try .unmarshal(from: object))
  }
}
