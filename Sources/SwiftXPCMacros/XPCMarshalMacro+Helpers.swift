// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import SwiftSyntax
import SwiftSyntaxMacros

extension XPCMarshalMacro {
  static func storedProperties(in declaration: StructDeclSyntax) -> [Property] {
    storedProperties(in: declaration.memberBlock.members)
  }

  static func storedProperties(in declaration: ClassDeclSyntax) -> [Property] {
    storedProperties(in: declaration.memberBlock.members)
  }

  static func storedProperties(in members: MemberBlockItemListSyntax) -> [Property] {
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

  static func enumCases(in declaration: EnumDeclSyntax) -> [EnumCase] {
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

  static func rawEnumCandidateType(in declaration: EnumDeclSyntax) -> TypeSyntax? {
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

  static func isSupportedRawEnumType(_ type: TypeSyntax) -> Bool {
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

  static func accessLevelPrefix(for declaration: some DeclGroupSyntax) -> String {
    let modifiers = declaration.modifiers
    for modifier in modifiers {
      switch modifier.name.text {
      case "open": return "open "
      case "public": return "public "
      case "package": return "package "
      case "internal": return "internal "
      default: continue
      }
    }
    return "internal "
  }

  static func isFinalClass(_ declaration: ClassDeclSyntax) -> Bool {
    let modifiers = declaration.modifiers
    return modifiers.contains { $0.name.text == "final" }
  }

  static func isFrozenStruct(_ declaration: StructDeclSyntax) -> Bool {
    let attributes = declaration.attributes
    return attributes.contains { element in
      guard let attribute = element.as(AttributeSyntax.self) else { return false }
      return attribute.attributeName.trimmed.description == "frozen"
    }
  }
}

struct Property {
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

struct EnumCase {
  let name: String
  let associatedValues: [AssociatedValue]
}

struct AssociatedValue {
  let label: String?
  let binding: String
  let type: TypeSyntax
}

func alreadyConformsToXPCMarshal(declaration: some DeclGroupSyntax) -> Bool {
  guard let inheritance = declaration.inheritanceClause else { return false }
  return inheritance.inheritedTypes.contains { inherited in
    inherited.type.trimmed.description == "XPCMarshal"
  }
}
