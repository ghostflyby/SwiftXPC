// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import DemoShared
import DistributedXPC

@main
struct DemoServiceMain: DemoServiceLifecycle, XPCConnectionActorServiceDelegate {
  let dependency: String
  init() { dependency = "injected" }
}
