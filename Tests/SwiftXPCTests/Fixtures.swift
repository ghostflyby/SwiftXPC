// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
@testable import SwiftXPC

@XPCMarshal
struct Greeting: Equatable {
  let id: Int
  let message: String
  let note: String?
}

@propertyWrapper
struct Uppercased: Equatable {
  private var storage: String
  var wrappedValue: String {
    get { storage }
    set { storage = newValue.uppercased() }
  }

  init(wrappedValue: String) { storage = wrappedValue.uppercased() }
}

@propertyWrapper
struct Clamped<Value: Comparable & Equatable>: Equatable {
  private var storage: Value
  private let range: ClosedRange<Value>

  var wrappedValue: Value {
    get { storage }
    set { storage = min(max(newValue, range.lowerBound), range.upperBound) }
  }

  init(wrappedValue: Value, _ range: ClosedRange<Value>) {
    self.range = range
    storage = min(max(wrappedValue, range.lowerBound), range.upperBound)
  }
}

@XPCMarshal
struct AccessControlledAggregate: Equatable {
  public let publicValue: Int
  let internalValue: String
  fileprivate let filePrivateValue: Double
  private let privateValue: Bool

  init(publicValue: Int, internalValue: String, filePrivateValue: Double, privateValue: Bool) {
    self.publicValue = publicValue
    self.internalValue = internalValue
    self.filePrivateValue = filePrivateValue
    self.privateValue = privateValue
  }

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.publicValue == rhs.publicValue && lhs.internalValue == rhs.internalValue
      && lhs.filePrivateValue == rhs.filePrivateValue && lhs.privateValue == rhs.privateValue
  }
}

@XPCMarshal
struct WrappedAggregate: Equatable {
  @Uppercased var title: String = ""
  @Clamped(0...100) var percentage: Int = 0

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.title == rhs.title && lhs.percentage == rhs.percentage
  }
}

@XPCMarshal
struct ComputedAggregate: Equatable {
  var first: String
  var last: String
  var fullName: String { "\(first) \(last)" }  // computed property should be ignored by macro
}

@XPCMarshal
struct NestedAggregate: Equatable {
  var payload: Greeting
  var notes: [Greeting?]
  var metadata: [String: Greeting]
}

@XPCMarshal
@frozen
public struct FrozenGreeting: Equatable {
  let id: Int
  let message: String
  let note: String?
}

@XPCMarshal
enum JobState: Equatable {
  case idle
  case progress(percent: Int)
  case message(String)
  case compound(title: String, retries: Int)
  case tuple(String, Int)
}

@XPCMarshal
enum RawMode: String, Equatable {
  case off = "off"
  case on = "on"
}
