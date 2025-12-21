// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Testing
import XPC

@testable import SwiftXPC

@Test func EnumLayoutNoPayload() async throws {
  let encoded = try JobState.idle.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  assert(type == XPC_TYPE_ARRAY)
  assert(xpc_array_get_count(object) == 1)

  let casePtr = xpc_array_get_value(object, 0)
  let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))
  assert(caseName == "idle")
}

@Test func EnumLayoutWithPayload() async throws {
  let encoded = try JobState.compound(title: "retry", retries: 3).marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  assert(type == XPC_TYPE_ARRAY)
  assert(xpc_array_get_count(object) == 2)

  let casePtr = xpc_array_get_value(object, 0)
  let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))
  assert(caseName == "compound")

  let payloadPtr = xpc_array_get_value(object, 1)
  let payloadType = xpc_get_type(payloadPtr)
  assert(payloadType == XPC_TYPE_ARRAY)
  assert(xpc_array_get_count(payloadPtr) == 2)

  let titlePtr = xpc_array_get_value(payloadPtr, 0)
  let title = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: titlePtr))
  assert(title == "retry")

  let retriesPtr = xpc_array_get_value(payloadPtr, 1)
  let retries = try Int.unmarshal(from: SwiftXPC.XPCObject(xpc_object: retriesPtr))
  assert(retries == 3)
}

@Test func RawEnumLayout() async throws {
  let encoded = try RawMode.on.marshal()
  let object = encoded.xpc_object
  let type = xpc_get_type(object)
  assert(type == XPC_TYPE_STRING)

  let value = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: object))
  assert(value == "on")
}
