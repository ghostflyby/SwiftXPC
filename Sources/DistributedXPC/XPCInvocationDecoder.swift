// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

/// Decodes the arguments of an inbound invocation for the target accessor.
/// Public as required by `DistributedActorSystem`; not intended for direct use.
public struct XPCInvocationDecoder: DistributedTargetInvocationDecoder {

  public typealias SerializationRequirement = XPCMarshal

  let array: XPCArray
  private let transport: XPCChannelTransport

  init(array: XPCArray, transport: XPCChannelTransport) {
    self.array = array
    self.transport = transport
  }
  var currentIndex: Int = 0

  public func decodeGenericSubstitutions() throws -> [Any.Type] {
    []
  }

  public mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
    guard currentIndex < array.count else {
      throw XPCMarshalError.outOfBounds(index: currentIndex, count: array.count)
    }
    defer { currentIndex += 1 }
    guard let raw = array[currentIndex, as: xpc_object_t.self] else {
      throw XPCMarshalError.outOfBounds(index: currentIndex, count: array.count)
    }
    return try XPCActorDecodingContext.$transport.withValue(transport) {
      try Argument.unmarshal(from: raw)
    }
  }

  public func decodeErrorType() throws -> Any.Type? {
    Error.self
  }

  public func decodeReturnType() throws -> Any.Type? {
    nil
  }
}
