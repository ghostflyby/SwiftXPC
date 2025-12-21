// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing

@testable import SwiftXPC

@Test func XPCMarshalEnumRoundTrip() async throws {
  try roundTrip(JobState.idle)
  try roundTrip(JobState.progress(percent: 10))
  try roundTrip(JobState.message("hello"))
  try roundTrip(JobState.compound(title: "retry", retries: 3))
  try roundTrip(JobState.tuple("pair", 2))
}
