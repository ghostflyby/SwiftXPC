// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import SwiftXPC

@available(macOS 15, *)
@XPCMarshal
public enum XPCDispatchError: Error, Sendable, Equatable {
  case unknownActor(XPCActorID)
  case unknownTarget(String)
  case missingTargetMetadata(String)
  case argumentCountMismatch(expected: Int, actual: Int)
  case targetExecutionFailed(String)
  case missingInvocationResult
}

@available(macOS 15, *)
enum XPCDistributedTargetReturnKind {
  case value
  case void
}

@available(macOS 15, *)
struct XPCDistributedTargetMetadata {
  let argumentCount: Int
  let returnKind: XPCDistributedTargetReturnKind
  let returnType: Any.Type?
  let thrownErrorType: (any ErrorXPCMarshal.Type)?

  init(
    argumentCount: Int,
    returnKind: XPCDistributedTargetReturnKind,
    returnType: Any.Type? = nil,
    thrownErrorType: (any ErrorXPCMarshal.Type)? = nil
  ) {
    self.argumentCount = argumentCount
    self.returnKind = returnKind
    self.returnType = returnType
    self.thrownErrorType = thrownErrorType
  }

  func validate(arguments: XPCArray) throws {
    guard arguments.count == argumentCount else {
      throw XPCDispatchError.argumentCountMismatch(expected: argumentCount, actual: arguments.count)
    }
  }
}

@available(macOS 15, *)
protocol XPCDistributedTargetMetadataProviding: DistributedActor
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {
  static var xpcDistributedTargetMetadata: [String: XPCDistributedTargetMetadata] { get }
}

@available(macOS 15, *)
extension XPCDistributedTargetMetadataProviding {
  static func xpcDistributedTargetMetadata(for target: RemoteCallTarget)
    throws -> XPCDistributedTargetMetadata
  {
    guard let metadata = xpcDistributedTargetMetadata[target.identifier] else {
      throw XPCDispatchError.unknownTarget(target.identifier)
    }
    return metadata
  }
}
