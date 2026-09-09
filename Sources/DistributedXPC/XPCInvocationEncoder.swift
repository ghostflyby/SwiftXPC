// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

@available(macOS 13.0, *)
/// Collects the arguments of an outbound distributed call into the XPC
/// argument array. Internal plumbing for compiler-generated thunks.
public struct XPCInvocationEncoder: DistributedTargetInvocationEncoder {
  public typealias SerializationRequirement = XPCMarshal

  var array = XPCArray()

  public mutating func recordArgument<Value: SerializationRequirement>(
    _ argument: RemoteCallArgument<Value>
  ) throws {
    array.append(try argument.value.marshal())
  }

  public mutating func recordReturnType<Res: SerializationRequirement>(_ resultType: Res.Type)
    throws
  {

  }

  public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {

  }

  public mutating func recordErrorType<E>(_ type: E.Type) throws where E: Error {

  }

  public mutating func doneRecording() throws {

  }

}
