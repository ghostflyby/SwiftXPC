// SPDX-FileCopyrightText: 2026 ghostflyby
// SPDX-License-Identifier: Apache-2.0
import Foundation
import Testing

private final class RequirementTestBundle: NSObject {}

/// Real named listener: both clients are signed, but only one has the required entitlement.
@available(macOS 26.0, *)
@Test func NamedSessionTypedRequirementEnforcesSignedPeerEntitlement() async throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("SwiftXPC-requirement-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = Bundle(for: RequirementTestBundle.self).bundleURL
    .deletingLastPathComponent().appendingPathComponent("XPCPeerRequirementProbe")
  try #require(FileManager.default.isExecutableFile(atPath: executable.path))
  let server = directory.appendingPathComponent("server")
  let matching = directory.appendingPathComponent("matching")
  let mismatching = directory.appendingPathComponent("mismatching")
  for path in [server, matching, mismatching] {
    try FileManager.default.copyItem(at: executable, to: path)
  }

  let service = "org.swiftxpc.tests.requirement.\(UUID().uuidString)"
  // This debug entitlement is valid with ad-hoc signatures; no developer identity is needed.
  let entitlement = "com.apple.security.get-task-allow"
  let entitlements = directory.appendingPathComponent("entitlements.plist")
  try writeRequirementPlist([entitlement: true], to: entitlements)
  for path in [server, matching, mismatching] {
    var arguments = [
      "--force", "--sign", "-", "--identifier", service + "." + path.lastPathComponent,
    ]
    if path == matching { arguments += ["--entitlements", entitlements.path] }
    arguments.append(path.path)
    try await runRequirementTool("/usr/bin/codesign", arguments)
    try await runRequirementTool("/usr/bin/codesign", ["--verify", "--strict", path.path])
  }
  let job = directory.appendingPathComponent("job.plist")
  try writeRequirementPlist(
    [
      "Label": service,
      "ProgramArguments": [server.path, "serve", service, entitlement],
      "MachServices": [service: true],
      "RunAtLoad": true,
      "StandardOutPath": directory.appendingPathComponent("server.log").path,
      "StandardErrorPath": directory.appendingPathComponent("server-errors.log").path,
    ], to: job)
  let domain = "gui/\(getuid())"
  do {
    try await runRequirementTool("/bin/launchctl", ["bootstrap", domain, job.path])
    #expect(try await runRequirementTool(matching.path, ["allow", service]) == "1,1,0")
    #expect(try await runRequirementTool(mismatching.path, ["deny", service]) == "denied")
    // The listener is still alive; kernel rejection did not reach either delegate hook.
    #expect(try await runRequirementTool(matching.path, ["allow", service]) == "2,2,0")
  } catch {
    _ = try? await runRequirementTool("/bin/launchctl", ["bootout", domain + "/" + service])
    if let data = try? Data(contentsOf: directory.appendingPathComponent("server-errors.log")) {
      Issue.record("launchd fixture: \(String(decoding: data, as: UTF8.self))")
    }
    throw error
  }
  try await runRequirementTool("/bin/launchctl", ["bootout", domain + "/" + service])
}

private func writeRequirementPlist(_ value: [String: Any], to path: URL) throws {
  try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(
    to: path)
}

private struct RequirementToolFailure: Error, CustomStringConvertible {
  let description: String
}

/// Process waits run outside the cooperative executor and have a termination watchdog.
@discardableResult
private func runRequirementTool(_ executable: String, _ arguments: [String]) async throws -> String
{
  try await withCheckedThrowingContinuation { continuation in
    DispatchQueue.global().async {
      do {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: watchdog)
        defer { watchdog.cancel() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(
          in: .whitespacesAndNewlines)
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
          throw RequirementToolFailure(
            description: "\(executable) \(arguments): exit \(process.terminationStatus)\n\(text)")
        }
        continuation.resume(returning: text)
      } catch {
        continuation.resume(throwing: error)
      }
    }
  }
}
