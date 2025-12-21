// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax

extension XPCMarshalMacro {
  static func encodeEnumFunction(for cases: [EnumCase], access: String) -> String {
    let caseBranches = cases.map { enumCase in
      if enumCase.associatedValues.isEmpty {
        return """
          case .\(enumCase.name):
            SwiftXPC.xpcArrayAppendValue(array, SwiftXPC.xpcStringCreate(\"\(enumCase.name)\"))
          """
      }

      let bindingList = enumCase.associatedValues.map { "let \($0.binding)" }.joined(
        separator: ", ")
      let allUnlabeled = enumCase.associatedValues.allSatisfy { $0.label == nil }
      let payloadAssignments = enumCase.associatedValues.map { value in
        let target = allUnlabeled ? "array" : "payload"
        return """
          SwiftXPC.xpcArrayAppendValue(\(target), try \(value.binding).marshal().xpc_object)
          """
      }.joined(separator: "\n")
      let payloadEncoding: String
      if allUnlabeled {
        payloadEncoding = payloadAssignments
      } else {
        payloadEncoding = """
            let payload = SwiftXPC.xpcArrayCreate(nil, 0)
          \(payloadAssignments)
            SwiftXPC.xpcArrayAppendValue(array, payload)
          """
      }

      return """
        case .\(enumCase.name)(\(bindingList)):
          SwiftXPC.xpcArrayAppendValue(array, SwiftXPC.xpcStringCreate(\"\(enumCase.name)\"))
          \(payloadEncoding)
        """
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws -> XPCObject {
        let array = SwiftXPC.xpcArrayCreate(nil, 0)
        switch self {
        \(caseBranches)
        }
        return SwiftXPC.XPCObject(xpc_object: array)
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
            let raw_\(binding) = SwiftXPC.xpcArrayGetValue(\(source), \(index + offset))
            let \(binding) = try \(value.type).unmarshal(from: SwiftXPC.XPCObject(xpc_object: raw_\(binding)))
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
          \(allUnlabeled ? "" : "  let payloadPtr = SwiftXPC.xpcArrayGetValue(array, 1)\n  let payloadType = SwiftXPC.xpcGetType(payloadPtr)\n  guard payloadType == SwiftXPC.xpcTypeArray else {\n    throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: payloadType))\n  }\n  let payloadArray = payloadPtr\n")
          \(valuesDecoding)
          return .\(enumCase.name)(\(argumentList))
        """
    }.joined(separator: "\n")

    return """
      \(access)static func unmarshal(from object: XPCObject) throws -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: type))
        }
        let array = object.xpc_object
        let casePtr = SwiftXPC.xpcArrayGetValue(array, 0)
        let caseName = try String.unmarshal(from: SwiftXPC.XPCObject(xpc_object: casePtr))

        switch caseName {
        \(caseBranches)
        default:
          throw SwiftXPC.XPCMarshalError.unknownEnumCase(caseName, enumName: \"\(typeName)\")
        }
      }
      """
  }
}
