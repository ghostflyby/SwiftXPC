// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DemoShared
import DistributedXPC

@main
enum DemoService {
  @MainActor
  static func main() {
    guard #available(macOS 15, *) else {
      fatalError("DistributedXPCDemo service requires macOS 15 or newer.")
    }
    distributedXPCMain(DemoRoot.self)
  }
}
