// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func encodeEnumFunction(for cases: [EnumCase], access: String) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case .\(enumCase.name):
            array.append(SwiftXPC.xpcStringCreate(\"\(enumCase.name)\"))
          """
      }

      let bindingList = enumCase.associatedValues.map { "let \($0.binding)" }.joined(
        separator: ", ")
      let allUnlabeled = enumCase.associatedValues.allSatisfy { $0.label == nil }
      let payloadAssignments = enumCase.associatedValues.map { value in
        let target = allUnlabeled ? "array" : "payload"
        return """
          \(target).append(try \(value.binding).marshal())
          """
      }.joined(separator: "\n")
      let payloadEncoding: String
      if allUnlabeled {
        payloadEncoding = payloadAssignments
      } else {
        payloadEncoding = """
            var payload = SwiftXPC.XPCArray()
          \(payloadAssignments)
            array.append(payload.xpcObject)
          """
      }

      return """
        case .\(enumCase.name)(\(bindingList)):
          array.append(SwiftXPC.xpcStringCreate(\"\(enumCase.name)\"))
          \(payloadEncoding)
        """
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws(SwiftXPC.XPCMarshalError) -> xpc_object_t {
        var array = SwiftXPC.XPCArray()
        switch self {
        \(caseBranches)
        }
        return array.xpcObject
      }
      """
  }

  static func decodeEnumFunction(
    for cases: [EnumCase],
    typeName: String,
    access: String
  ) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case \"\(enumCase.name)\":
            return .\(enumCase.name)
          """
      }

      let allUnlabeled = enumCase.associatedValues.allSatisfy { $0.label == nil }
      let valuesDecoding = enumCase.associatedValues.enumerated().map { index, value in
        let binding = value.binding
        let source = allUnlabeled ? "array" : "payloadArray"
        let offset = allUnlabeled ? 1 : 0
        return """
            guard let raw_\(binding) = \(source)[\(index + offset), as: xpc_object_t.self] else {
              throw SwiftXPC.XPCMarshalError.outOfBounds(
                index: \(index + offset), count: \(source).count)
            }
            let \(binding) = try \(value.type).unmarshal(from: raw_\(binding))
          """
      }.joined(separator: "\n")
      let argumentList = enumCase.associatedValues.map { value in
        if let label = value.label {
          return "\(label): \(value.binding)"
        } else {
          return value.binding
        }
      }.joined(separator: ", ")
      return """
        case \"\(enumCase.name)\":
          \(allUnlabeled ? "" : "  guard let payloadPtr = array[1, as: xpc_object_t.self] else {\n    throw SwiftXPC.XPCMarshalError.outOfBounds(index: 1, count: array.count)\n  }\n  let payloadType = SwiftXPC.xpcGetType(payloadPtr)\n  guard payloadType == SwiftXPC.xpcTypeArray else {\n    throw SwiftXPC.XPCMarshalError.typeMismatch(\n      expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),\n      actual: String(cString: SwiftXPC.xpcTypeGetName(payloadType))\n    )\n  }\n  let payloadArray = SwiftXPC.XPCArray(payloadPtr)\n")
          \(valuesDecoding)
          return .\(enumCase.name)(\(argumentList))
        """
    }.joined(separator: "\n")

    return """
      \(access)static func unmarshal(from object: xpc_object_t) throws(SwiftXPC.XPCMarshalError) -> Self {
        let type = SwiftXPC.xpcGetType(object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.typeMismatch(
            expected: String(cString: SwiftXPC.xpcTypeGetName(SwiftXPC.xpcTypeArray)),
            actual: String(cString: SwiftXPC.xpcTypeGetName(type))
          )
        }
        let array = SwiftXPC.XPCArray(object)
        guard let casePtr = array[0, as: xpc_object_t.self] else {
          throw SwiftXPC.XPCMarshalError.outOfBounds(index: 0, count: array.count)
        }
        let caseName = try String.unmarshal(from: casePtr)

        switch caseName {
        \(caseBranches)
        default:
          throw SwiftXPC.XPCMarshalError.unknownEnumCase(caseName, enumName: \"\(typeName)\")
        }
      }
      """
  }
}
