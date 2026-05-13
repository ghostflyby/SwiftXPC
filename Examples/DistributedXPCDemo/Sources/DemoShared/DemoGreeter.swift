// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import DistributedXPC
import SwiftXPC

public let demoServiceIdentifier = "dev.ghostflyby.SwiftXPC.DistributedXPCDemo.Service"

@available(macOS 15, *)
public enum DemoTargets {
  public static let greet = "$s10DemoShared0A7GreeterC5greet4nameS2S_tYaKFTE"
  public static let ping = "$s10DemoShared0A7GreeterC4pingyyYaKFTE"
}

@available(macOS 15, *)
public enum DemoGreeterError: Error, Equatable, CustomStringConvertible {
  case rejected

  public var description: String {
    switch self {
    case .rejected:
      "DemoGreeter rejected the request"
    }
  }
}

@available(macOS 15, *)
extension DemoGreeterError: XPCMarshal {
  public func marshal() throws(XPCMarshalError) -> XPCObject {
    try "rejected".marshal()
  }

  public static func unmarshal(from object: XPCObject) throws(XPCMarshalError) -> DemoGreeterError {
    switch try String.unmarshal(from: object) {
    case "rejected":
      .rejected
    case let value:
      throw XPCMarshalError.unknownEnumCase(value, enumName: "DemoGreeterError")
    }
  }
}

@available(macOS 15, *)
public distributed actor DemoGreeter {
  public typealias ActorSystem = XPCDistributedActorSystem

  public distributed func greet(name: String) throws(DemoGreeterError) -> String {
    guard name != "error" else {
      throw DemoGreeterError.rejected
    }
    return "Hello, \(name)!"
  }

  public distributed func ping() {}
}

@available(macOS 15, *)
@_spi(Experimental)
extension DemoGreeter: XPCDistributedTargetMetadataProviding {
  public static var xpcDistributedTargetMetadata: [String: XPCDistributedTargetMetadata] {
    [
      DemoTargets.greet: .init(
        argumentCount: 1,
        returnKind: .value,
        returnType: String.self,
        thrownErrorType: DemoGreeterError.self
      ),
      DemoTargets.ping: .init(
        argumentCount: 0,
        returnKind: .void
      ),
    ]
  }
}

@available(macOS 15, *)
extension DemoGreeter: XPCDefaultActorInitializable {}
