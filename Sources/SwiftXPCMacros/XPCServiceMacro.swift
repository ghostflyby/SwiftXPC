// SPDX-FileCopyrightText: 2025 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

public struct XPCServiceMacro: ExtensionMacro {
  public static func expansion(
    of node: AttributeSyntax,
    attachedTo declaration: some DeclGroupSyntax,
    providingExtensionsOf type: some TypeSyntaxProtocol,
    conformingTo protocols: [TypeSyntax],
    in context: some MacroExpansionContext
  ) throws -> [ExtensionDeclSyntax] {
    guard let actorDecl = declaration.as(ActorDeclSyntax.self) else {
      context.diagnose(.init(node: Syntax(declaration), message: XPCServiceNotActor()))
      return []
    }

    let distributedFuncs = actorDecl.memberBlock.members
      .compactMap { $0.decl.as(FunctionDeclSyntax.self) }
      .filter { funcDecl in
        funcDecl.modifiers.contains { $0.name.text == "distributed" }
      }

    let access = XPCMarshalMacro.accessLevelPrefix(for: declaration)

    // Overloads share a metadata key (base name + labels only). Merge them:
    // identical records collapse; records with different typed-throws error
    // types are ambiguous, so the key degrades to no error metadata (the
    // caller's own typed error is still used when it conforms to XPCMarshal).
    var merged: [String: String] = [:]
    var orderedKeys: [String] = []
    var ambiguousKeys: Set<String> = []

    for funcDecl in distributedFuncs {
      let baseName = funcDecl.name.text
      let params = funcDecl.signature.parameterClause.parameters
      let labels = params.compactMap { parameter in
        let label = parameter.firstName.text
        return label == "_" ? nil : "\(label):"
      }.joined()
      let methodKey = labels.isEmpty ? "\(baseName)()" : "\(baseName)(\(labels))"

      var thrownErrorEntry = ""

      // SwiftSyntax 603 parses typed throws as a structured `ThrowsClause`;
      // its `type` is the error type of `throws(Type)`.
      if let errorType = funcDecl.signature.effectSpecifiers?
        .throwsClause?.type
      {
        thrownErrorEntry = "thrownErrorType: \(errorType.trimmed).self"
      }

      if let existing = merged[methodKey] {
        if existing != thrownErrorEntry {
          merged[methodKey] = ""
          if ambiguousKeys.insert(methodKey).inserted {
            context.diagnose(
              .init(
                node: Syntax(funcDecl),
                message: OverloadAmbiguousErrorType(methodKey: methodKey)))
          }
        }
      } else {
        merged[methodKey] = thrownErrorEntry
        orderedKeys.append(methodKey)
      }
    }

    var entries: [String] = []
    for methodKey in orderedKeys {
      let thrownErrorEntry = merged[methodKey] ?? ""
      if thrownErrorEntry.isEmpty {
        entries.append("      \"\(methodKey)\": .init()")
      } else {
        entries.append("      \"\(methodKey)\": .init(\(thrownErrorEntry))")
      }
    }

    let body = entries.joined(separator: ",\n")

    let extDecl: DeclSyntax = """
      extension \(type.trimmed): XPCDistributedTargetMetadataProviding, XPCExportableActor {
        \(raw: access)static var xpcDistributedTargetMetadata: [String: XPCDistributedTargetMetadata] {
          [
      \(raw: body)
          ]
        }
      }
      """

    guard let ext = extDecl.as(ExtensionDeclSyntax.self) else { return [] }
    return [ext]
  }
}

private struct OverloadAmbiguousErrorType: DiagnosticMessage {
  let methodKey: String
  var message: String {
    "Overloads of '\(methodKey)' share this metadata key; typed-throws error metadata is omitted because it would be ambiguous. Thrown errors of these overloads must conform to XPCMarshal to be decodable by callers"
  }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "xpcServiceAmbiguousOverload") }
  var severity: DiagnosticSeverity { .warning }
}

private struct XPCServiceNotActor: DiagnosticMessage {
  var message: String { "@XPCService can only be applied to distributed actor declarations" }
  var diagnosticID: MessageID { .init(domain: "SwiftXPCMacros", id: "xpcServiceNotActor") }
  var severity: DiagnosticSeverity { .error }
}
