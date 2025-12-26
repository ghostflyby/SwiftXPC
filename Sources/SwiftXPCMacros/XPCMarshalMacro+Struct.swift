// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func decodeFunction(
    for properties: [Property],
    typeName _: String,
    access: String
  ) -> String {
    let bindings = properties.map { property in
      let key = property.name
      let rawPtr = "rawPtr_\(key)"
      if property.isOptional {
        return """
          let \(key): \(property.type)
          if let \(rawPtr) = dict["\(key)"] {
            if SwiftXPC.xpcGetType(\(rawPtr).xpc_object) == SwiftXPC.xpcTypeNull {
              \(key) = nil
            } else {
              \(key) = try .unmarshal(from: \(rawPtr))
            }
          } else {
            \(key) = nil
          }
          """
      } else {
        return """
          let \(key): \(property.type)
          guard let \(rawPtr) = dict["\(key)"] else {
            throw SwiftXPC.XPCMarshalError.missingKey("\(key)")
          }
          \(key) = try .unmarshal(from: \(rawPtr))
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeDictionary else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeDictionary)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let dict = SwiftXPC.XPCDictionary(xpc_object: object.xpc_object)
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  static func decodeFrozenStructFunction(
    for properties: [Property],
    typeName _: String,
    access: String
  ) -> String {
    let bindings = properties.enumerated().map { index, property in
      let rawPtr = "rawPtr_\(property.name)"
      if property.isOptional {
        return """
          let \(property.name): \(property.type)
          let \(rawPtr) = array[\(index)]
          if SwiftXPC.xpcGetType(\(rawPtr).xpc_object) == SwiftXPC.xpcTypeNull {
            \(property.name) = nil
          } else {
            \(property.name) = try .unmarshal(from: \(rawPtr))
          }
          """
      } else {
        return """
          let \(property.name): \(property.type)
          let \(rawPtr) = array[\(index)]
          \(property.name) = try .unmarshal(from: \(rawPtr))
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      \(access)static func unmarshal(from object: XPCObject) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let array = SwiftXPC.XPCArray(xpc_object: object.xpc_object)
        let count = array.count
        guard count >= \(properties.count) else {
          throw SwiftXPC.XPCMarshalError.missingKey(\"\(properties.count - 1)\")
        }
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  static func encodeFrozenStructFunction(for properties: [Property], access: String) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            array.append(try value.marshal())
          } else {
            array.append(SwiftXPC.XPCObject(xpc_object: SwiftXPC.xpcNullCreate()))
          }
          """
      } else {
        return """
          array.append(try self.\(property.name).marshal())
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
        var array = SwiftXPC.XPCArray()
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: array.xpc_object)
      }
      """
  }

  static func encodeFunction(for properties: [Property], access: String) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            dict["\(property.name)"] = try value.marshal()
          } else {
            dict["\(property.name)"] = nil
          }
          """
      } else {
        return """
          dict["\(property.name)"] = try self.\(property.name).marshal()
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> XPCObject {
        var dict = SwiftXPC.XPCDictionary()
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: dict.xpc_object)
      }
      """
  }
}
