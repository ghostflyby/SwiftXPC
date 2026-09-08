// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

@available(macOS 13.0, *)
/// Decodes the arguments of an inbound invocation for the target accessor.
/// Internal plumbing for `executeDistributedTarget`.
public struct XPCInvocationDecoder: DistributedTargetInvocationDecoder {

  public typealias SerializationRequirement = XPCMarshal

  let array: XPCArray
  var currentIndex: Int = 0

  public func decodeGenericSubstitutions() throws -> [Any.Type] {
    []
  }

  public mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
    guard currentIndex < array.endIndex else {
      throw XPCMarshalError.outOfBounds(index: currentIndex, count: array.count)
    }
    defer { currentIndex += 1 }
    return try Argument.unmarshal(from: array[currentIndex])
  }

  public func decodeErrorType() throws -> Any.Type? {
    Error.self
  }

  public func decodeReturnType() throws -> Any.Type? {
    nil
  }
}
