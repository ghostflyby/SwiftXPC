// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftCompilerPlugin
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import XPC

@main
struct SwiftXPCPlugin: CompilerPlugin {
  let providingMacros: [Macro.Type] = [XPCMarshalMacro.self]
}

public struct XPCMarshalMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    let marshalImpl: String
    let unmarshalImpl: String

    let access = accessLevelPrefix(for: declaration)
    if let structDecl = declaration.as(StructDeclSyntax.self) {
      let properties = storedProperties(in: structDecl)
      if isFrozenStruct(structDecl) {
        marshalImpl = encodeFrozenStructFunction(for: properties, access: access)
        unmarshalImpl = decodeFrozenStructFunction(
          for: properties, typeName: type.trimmed.description, access: access)
      } else {
        marshalImpl = encodeFunction(for: properties, access: access)
        unmarshalImpl = decodeFunction(
          for: properties, typeName: type.trimmed.description, access: access)
      }
    } else if let classDecl = declaration.as(ClassDeclSyntax.self) {
      guard isFinalClass(classDecl) else {
        context.diagnose(.init(node: Syntax(classDecl), message: OnlyFinalClassesAllowed()))
        return []
      }
      let properties = storedProperties(in: classDecl)
      marshalImpl = encodeFunction(for: properties, access: access)
      unmarshalImpl = decodeFunction(
        for: properties, typeName: type.trimmed.description, access: access)
    } else if let enumDecl = declaration.as(EnumDeclSyntax.self) {
      if let rawType = rawEnumCandidateType(in: enumDecl) {
        guard isSupportedRawEnumType(rawType) else {
          context.diagnose(
            .init(
              node: Syntax(enumDecl), message: InvalidRawEnumType(type: rawType.trimmed.description)
            )
          )
          return []
        }
        marshalImpl = encodeRawEnumFunction(for: rawType, access: access)
        unmarshalImpl = decodeRawEnumFunction(
          for: rawType, typeName: type.trimmed.description, access: access)
      } else {
        let cases = enumCases(in: enumDecl)
        marshalImpl = encodeEnumFunction(for: cases, access: access)
        unmarshalImpl = decodeEnumFunction(
          for: cases, typeName: type.trimmed.description, access: access)
      }
    } else {
      context.diagnose(.init(node: Syntax(declaration), message: OnlyStructsOrEnumsAllowed()))
      return []
    }

    let needsConformance = alreadyConformsToXPCMarshal(declaration: declaration) == false
    let conformanceClause = needsConformance ? ": XPCMarshal" : ""

    let members = [marshalImpl, unmarshalImpl].joined(separator: "\n\n")

    let extDecl: DeclSyntax = """
      extension \(type.trimmed)\(raw: conformanceClause) {
      \(raw: members)
      }
      """

    if let ext = extDecl.as(ExtensionDeclSyntax.self) {
      return [ext]
    }
    return []
  }

  private static func storedProperties(in declaration: StructDeclSyntax) -> [Property] {
    storedProperties(in: declaration.memberBlock.members)
  }

  private static func storedProperties(in declaration: ClassDeclSyntax) -> [Property] {
    storedProperties(in: declaration.memberBlock.members)
  }

  private static func storedProperties(in members: MemberBlockItemListSyntax) -> [Property] {
    members.compactMap { member in
      guard let varDecl = member.decl.as(VariableDeclSyntax.self) else { return nil }
      if varDecl.modifiers.contains(where: { $0.name.text == "static" }) {
        return nil
      }
      guard let binding = varDecl.bindings.first,
        let pattern = binding.pattern.as(IdentifierPatternSyntax.self),
        binding.accessorBlock == nil,
        let type = binding.typeAnnotation?.type
      else {
        return nil
      }
      return Property(name: pattern.identifier.trimmed.text, type: type)
    }
  }

  private static func accessLevelPrefix(for declaration: some DeclGroupSyntax) -> String {
    let modifiers = declaration.modifiers
    if modifiers.isEmpty { return "" }
    for modifier in modifiers {
      switch modifier.name.text {
      case "open": return "open "
      case "public": return "public "
      case "package": return "package "
      case "internal": return "internal "
      case "fileprivate": return "fileprivate "
      case "private": return "fileprivate "
      default: continue
      }
    }
    return "internal "
  }

  private static func isFinalClass(_ declaration: ClassDeclSyntax) -> Bool {
    let modifiers = declaration.modifiers
    return modifiers.contains { $0.name.text == "final" }
  }

  private static func isFrozenStruct(_ declaration: StructDeclSyntax) -> Bool {
    let attributes = declaration.attributes
    return attributes.contains { element in
      guard let attribute = element.as(AttributeSyntax.self) else { return false }
      return attribute.attributeName.trimmed.description == "frozen"
    }
  }

  private static func enumCases(in declaration: EnumDeclSyntax) -> [EnumCase] {
    declaration.memberBlock.members.flatMap { member -> [EnumCase] in
      guard let enumCaseDecl = member.decl.as(EnumCaseDeclSyntax.self) else {
        return [] as [EnumCase]
      }
      return enumCaseDecl.elements.map { element in
        let associatedValues: [AssociatedValue]
        if let parameters = element.parameterClause?.parameters {
          associatedValues = parameters.enumerated().map { index, parameter in
            let firstName = parameter.firstName?.text
            let externalName = firstName == "_" ? nil : firstName
            let binding = parameter.secondName?.text ?? externalName ?? "value\(index)"
            return AssociatedValue(
              label: externalName,
              binding: binding,
              type: parameter.type
            )
          }
        } else {
          associatedValues = []
        }

        return EnumCase(name: element.name.text, associatedValues: associatedValues)
      }
    }
  }

  private static func rawEnumCandidateType(in declaration: EnumDeclSyntax) -> TypeSyntax? {
    let cases = enumCases(in: declaration)
    if cases.contains(where: { $0.associatedValues.isEmpty == false }) {
      return nil
    }
    guard let inheritance = declaration.inheritanceClause,
      let rawType = inheritance.inheritedTypes.first?.type
    else {
      return nil
    }
    let rawTypeName = rawType.trimmed.description
    let protocolLikeNames: Set<String> = [
      "XPCMarshal",
      "Codable",
      "Decodable",
      "Encodable",
      "Equatable",
      "Hashable",
      "Comparable",
      "Sendable",
      "CaseIterable",
      "Identifiable",
      "Error",
    ]
    if protocolLikeNames.contains(rawTypeName) {
      return nil
    }
    return rawType
  }

  private static func isSupportedRawEnumType(_ type: TypeSyntax) -> Bool {
    let rawTypeName = type.trimmed.description
    let supported: Set<String> = [
      "String",
      "Character",
      "Int",
      "Int8",
      "Int16",
      "Int32",
      "Int64",
      "UInt",
      "UInt8",
      "UInt16",
      "UInt32",
      "UInt64",
      "Float",
      "Float16",
      "Double",
      "Float80",
    ]
    return supported.contains(rawTypeName)
  }

  private static func decodeFunction(
    for properties: [Property],
    typeName: String,
    access: String
  ) -> String {
    let bindings = properties.map { property in
      let key = property.name
      if property.isOptional {
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = SwiftXPC.xpcDictionaryGetValue(dict, "\(key)") else { return nil }
            if SwiftXPC.xpcGetType(rawPtr) == SwiftXPC.xpcTypeNull { return nil }
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      } else {
        return """
          let \(key): \(property.type) = try {
            guard let rawPtr = SwiftXPC.xpcDictionaryGetValue(dict, "\(key)") else { throw SwiftXPC.XPCMarshalError.missingKey("\(key)") }
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
        \(access)static func unmarshal(from object: XPCObject) throws -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeDictionary else { throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: type)) }
        let dict = object.xpc_object
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  private static func decodeFrozenStructFunction(
    for properties: [Property],
    typeName: String,
    access: String
  ) -> String {
    let bindings = properties.enumerated().map { index, property in
      if property.isOptional {
        return """
          let \(property.name): \(property.type) = try {
            let rawPtr = SwiftXPC.xpcArrayGetValue(array, \(index))
            if SwiftXPC.xpcGetType(rawPtr) == SwiftXPC.xpcTypeNull { return nil }
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      } else {
        return """
          let \(property.name): \(property.type) = try {
            let rawPtr = SwiftXPC.xpcArrayGetValue(array, \(index))
            let raw = SwiftXPC.XPCObject(xpc_object: rawPtr)
            return try .unmarshal(from: raw)
          }()
          """
      }
    }.joined(separator: "\n")

    let arguments = properties.map { "\($0.name): \($0.name)" }.joined(separator: ", ")

    return
      """
      \(access)static func unmarshal(from object: XPCObject) throws -> Self {
        let type = SwiftXPC.xpcGetType(object.xpc_object)
        guard type == SwiftXPC.xpcTypeArray else {
          throw SwiftXPC.XPCMarshalError.expectedDictionary(actual: String(describing: type))
        }
        let array = object.xpc_object
        let count = SwiftXPC.xpcArrayGetCount(array)
        guard count >= \(properties.count) else {
          throw SwiftXPC.XPCMarshalError.missingKey(\"\(properties.count - 1)\")
        }
        \(bindings)
        return Self.init(\(arguments))
      }
      """
  }

  private static func encodeFrozenStructFunction(for properties: [Property], access: String)
    -> String
  {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            SwiftXPC.xpcArrayAppendValue(array, try value.marshal().xpc_object)
          } else {
            SwiftXPC.xpcArrayAppendValue(array, SwiftXPC.xpcNullCreate())
          }
          """
      } else {
        return """
          SwiftXPC.xpcArrayAppendValue(array, try self.\(property.name).marshal().xpc_object)
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws -> XPCObject {
        let array = SwiftXPC.xpcArrayCreate(nil, 0)
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: array)
      }
      """
  }

  private static func encodeRawEnumFunction(for _: TypeSyntax, access: String) -> String {
    """
    \(access)func marshal() throws -> XPCObject {
      try self.rawValue.marshal()
    }
    """
  }

  private static func decodeRawEnumFunction(
    for rawType: TypeSyntax,
    typeName: String,
    access: String
  ) -> String {
    """
    \(access)static func unmarshal(from object: XPCObject) throws -> Self {
      let rawValue = try \(rawType).unmarshal(from: object)
      guard let value = Self(rawValue: rawValue) else {
        throw SwiftXPC.XPCMarshalError.unknownEnumCase(
          String(describing: rawValue),
          enumName: \"\(typeName)\"
        )
      }
      return value
    }
    """
  }

  private static func encodeFunction(for properties: [Property], access: String) -> String {
    let assignments = properties.map { property in
      if property.isOptional {
        return """
          if let value = self.\(property.name) {
            SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", try value.marshal().xpc_object)
          } else {
            SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", SwiftXPC.xpcNullCreate())
          }
          """
      } else {
        return """
          SwiftXPC.xpcDictionarySetValue(dict, \"\(property.name)\", try self.\(property.name).marshal().xpc_object)
          """
      }
    }.joined(separator: "\n")

    return """
      \(access)func marshal() throws -> XPCObject {
        let dict = SwiftXPC.xpcDictionaryCreate(nil, nil, 0)
      \(assignments)
        return SwiftXPC.XPCObject(xpc_object: dict)
      }
      """
  }

  private static func encodeEnumFunction(for cases: [EnumCase], access: String) -> String {
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

  private static func decodeEnumFunction(
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

private struct Property {
  let name: String
  let type: TypeSyntax

  var isOptional: Bool {
    let trimmed = type.trimmed.description
    if trimmed.hasSuffix("?") { return true }
    if let identifier = type.as(IdentifierTypeSyntax.self) {
      return identifier.name.text == "Optional"
    }
    return false
  }

  var wrappedTypeText: String {
    if let optional = type.as(OptionalTypeSyntax.self) {
      return optional.wrappedType.trimmed.description
    }
    if let identifier = type.as(IdentifierTypeSyntax.self),
      let generic = identifier.genericArgumentClause?.arguments.first?.argument
    {
      return generic.trimmed.description
    }
    let trimmed = type.trimmed.description
    if trimmed.hasSuffix("?") {
      return String(trimmed.dropLast())
    }
    return trimmed
  }
}

private func alreadyConformsToXPCMarshal(declaration: some DeclGroupSyntax) -> Bool {
  guard let inheritance = declaration.inheritanceClause else { return false }
  return inheritance.inheritedTypes.contains { inherited in
    inherited.type.trimmed.description == "XPCMarshal"
  }
}

private struct OnlyStructsOrEnumsAllowed: DiagnosticMessage {
  var message: String { "@XPCMarshal only supports struct, enum, or final class declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyStructEnumFinalClass") }
  var severity: DiagnosticSeverity { .error }
}

private struct InvalidRawEnumType: DiagnosticMessage {
  let type: String
  var message: String {
    "@XPCMarshal raw enums only support String, Character, or integer/floating-point raw types (found \(type))"
  }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "invalidRawEnumType") }
  var severity: DiagnosticSeverity { .error }
}

private struct OnlyFinalClassesAllowed: DiagnosticMessage {
  var message: String { "@XPCMarshal only supports final class declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "onlyFinalClass") }
  var severity: DiagnosticSeverity { .error }
}

private struct EnumCase {
  let name: String
  let associatedValues: [AssociatedValue]
}

private struct AssociatedValue {
  let label: String?
  let binding: String
  let type: TypeSyntax
}
