// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Distributed
import DistributedXPC
import SwiftXPC

public let demoServiceIdentifier = "dev.ghostflyby.SwiftXPC.DistributedXPCDemo.Service"

@available(macOS 15, *)
@XPCService
public distributed actor DemoRoot: XPCRootActor {
  public typealias ActorSystem = XPCDistributedActorSystem

  public distributed func makeGreeter() -> DemoGreeter {
    DemoGreeter(actorSystem: actorSystem)
  }
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
@XPCService
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
