// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

@Test func RoundTripInt() async throws {
  try roundTrip(1)
}

@Test func RoundTripUInt() async throws {
  try roundTrip(UInt(1))
}

@Test func RoundTripDouble() async throws {
  try roundTrip(1.0)
}

@Test func RoundTripFloat() async throws {
  try roundTrip(Float(3.14))
}

@Test func RoundTripArray() async throws {
  try roundTrip([1, 2, 3])
}

@Test func RoundTripDate() async throws {
  try roundTrip(Date(timeIntervalSince1970: 0))
}

@Test func RoundTripUUID() async throws {
  try roundTrip(UUID())
}

@Test func RoundTripString() async throws {
  try roundTrip("Hello, XPC!")
}

@Test func RoundTripDictionary() async throws {
  try roundTrip(["key": 1, "number": 42])
}

@Test func RoundTripData() async throws {
  try roundTrip("Hello, XPC!".data(using: .utf8))
}

@Test func RoundTripOptionalString() async throws {
  try roundTrip(Optional<String>.some("Hello, XPC!"))
  try roundTrip(Optional<String>.none)
}

@Test func RoundTripArrayArray() async throws {
  try roundTrip([[1, 2, 3], [4, 5, 6]])
}

@Test func RoundTripDictionaryArray() async throws {

  try roundTrip([["key1": 1], ["key2": 2]])
}

@Test func RoundTripNestedDictionary() async throws {
  try roundTrip(["outerKey": ["innerKey": 1]])
}

@Test func RoundTripFileHandle() async throws {
  let original = FileHandle.standardOutput
  let v = try original.marshal()
  let decoded = try FileHandle.unmarshal(from: v)
  _ = decoded.fileDescriptor
}
