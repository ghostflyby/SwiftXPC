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
  case targetExecutionFailed(String)
  case missingInvocationResult
}

@available(macOS 15, *)
public struct XPCDistributedTargetMetadata {
  public let thrownErrorType: (any (XPCMarshal & Error).Type)?

  public init(
    thrownErrorType: (any (XPCMarshal & Error).Type)? = nil
  ) {
    self.thrownErrorType = thrownErrorType
  }
}

@available(macOS 15, *)
public func parseTargetIdentifier(_ identifier: String) -> String? {
  guard let lastC = identifier.lastIndex(of: "C") else { return nil }
  var pos = identifier.index(after: lastC)
  guard pos < identifier.endIndex, identifier[pos].isNumber else { return nil }
  var digits = ""
  while pos < identifier.endIndex, identifier[pos].isNumber {
    digits.append(identifier[pos])
    pos = identifier.index(after: pos)
  }
  guard let baseLen = Int(digits),
    identifier.distance(from: pos, to: identifier.endIndex) >= baseLen
  else { return nil }
  let baseEnd = identifier.index(pos, offsetBy: baseLen)
  let baseName = String(identifier[pos..<baseEnd])
  pos = baseEnd
  var labels: [String] = []
  while pos < identifier.endIndex, identifier[pos].isNumber {
    digits = ""
    while pos < identifier.endIndex, identifier[pos].isNumber {
      digits.append(identifier[pos])
      pos = identifier.index(after: pos)
    }
    guard let labelLen = Int(digits),
      identifier.distance(from: pos, to: identifier.endIndex) >= labelLen
    else { return nil }
    let labelEnd = identifier.index(pos, offsetBy: labelLen)
    labels.append(String(identifier[pos..<labelEnd]))
    pos = labelEnd
  }
  if labels.isEmpty { return "\(baseName)()" }
  return "\(baseName)(\(labels.map { "\($0):" }.joined()))"
}

@available(macOS 15, *)
public protocol XPCDistributedTargetMetadataProviding: DistributedActor
where ActorSystem == XPCDistributedActorSystem, ID == XPCActorID {
  static var xpcDistributedTargetMetadata: [String: XPCDistributedTargetMetadata] { get }
}

@attached(
  extension, conformances: XPCDistributedTargetMetadataProviding,
  names: named(xpcDistributedTargetMetadata))
public macro XPCService() = #externalMacro(module: "SwiftXPCMacros", type: "XPCServiceMacro")
