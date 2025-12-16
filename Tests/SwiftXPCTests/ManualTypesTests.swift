// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing
import XPC

@testable import SwiftXPC

@Test func Int() async throws {
  try roundTrip(1)
}

@Test func UInt() async throws {
  try roundTrip(UInt(1))
}

@Test func Double() async throws {
  try roundTrip(1.0)
}

@Test func array() async throws {
  try roundTrip([1, 2, 3])
}

@Test func Date() async throws {
  try roundTrip(Date.now)
}

@Test func UUID() async throws {
  try roundTrip(UUID())
}

@Test func String() async throws {
  try roundTrip("Hello, XPC!")
}

@Test func Dictionary() async throws {
  try roundTrip(["key": 1, "number": 42])
}

@Test func Data() async throws {
  try roundTrip("Hello, XPC!".data(using: .utf8))
}

@Test func OptionalString() async throws {
  try roundTrip(Optional<String>.some("Hello, XPC!"))
  try roundTrip(Optional<String>.none)
}

@Test func ArrayArray() async throws {
  try roundTrip([[1, 2, 3], [4, 5, 6]])
}

@Test func DictionaryArray() async throws {
  try roundTrip([["key1": 1], ["key2": 2]])
}

@Test func NestedDictionary() async throws {
  try roundTrip(["outerKey": ["innerKey": 1]])
}

@Test func FileHandle() async throws {
  let original = FileHandle.standardOutput
  let v = try original.marshal()
  let decoded = try FileHandle.unmarshal(from: v)
  _ = decoded.fileDescriptor
}
