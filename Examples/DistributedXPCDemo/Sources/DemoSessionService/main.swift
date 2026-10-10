// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DemoShared
import DistributedXPC
import Foundation

@main
struct DemoSessionServiceMain: DemoServiceLifecycle, XPCSessionActorServiceDelegate {
  let dependency: String
  init() { dependency = "injected" }

  static var serviceName: String {
    guard let index = CommandLine.arguments.firstIndex(of: "--session-service"),
      CommandLine.arguments.indices.contains(index + 1)
    else { preconditionFailure("Pass --session-service with the launchd MachServices name") }
    return CommandLine.arguments[index + 1]
  }
}
