#!/usr/bin/env python3
"""Verify package-external API constraints and record the owned public symbol inventory.

Run after swift build. Logs and generated probes live in .build/public-api-verification.
"""
from pathlib import Path
import json
import platform
import re
import subprocess

workspace = Path(__file__).resolve().parents[1]
out = workspace / ".build/public-api-verification"
out.mkdir(parents=True, exist_ok=True)
bin_path = Path(subprocess.check_output(
    ["swift", "build", "--show-bin-path"], cwd=workspace, text=True,
).strip())
common='''import DistributedXPC
struct C: XPCConnectionServiceDelegate {
  func shouldAcceptConnection(_ connection: XPCConnection) throws -> Bool { connection.euid == geteuid() }
}
struct S: XPCSessionServiceDelegate {
  func shouldAcceptSessionRequest(_ request: XPCListener.IncomingSessionRequest) throws -> Bool { true }
}
'''
positive=common+'''
func publicAPI<Root: XPCRootActor>(_ root: Root.Type) throws {
  _ = try Root.connect(toService: "example.bundle.service")
  _ = try Root.connect(machService: "example.mach.service")
  _ = try XPCRootConnection<Root>.connect(toService: "example.bundle.service")
  _ = try XPCRootConnection<Root>.connect(machService: "example.mach.service")
  for transport in XPCChannelTransport.allCases {
    _ = transport.channel(xpcService: "example.bundle.service")
    _ = transport.channel(machService: "example.mach.service")
    _ = try Root.connect(toService: "example.bundle.service", transport: transport)
    _ = try Root.connect(machService: "example.mach.service", transport: transport)
    _ = try XPCRootConnection<Root>.connect(toService: "example.bundle.service", transport: transport)
    _ = try XPCRootConnection<Root>.connect(machService: "example.mach.service", transport: transport)
  }
  let c = XPCActorService(root, C())
  try c.listen()
  let s = XPCActorService(root, sessionDelegate: S(), onShutdown: {},
    makeRoot: { Root(actorSystem: $0) })
  _ = XPCActorService(root, transport: .session, onShutdown: {},
    makeRoot: { Root(actorSystem: $0) })
  _ = try xpcTest(root, sessionDelegate: S(), watchdog: .seconds(10), onShutdown: {})
  _ = try xpcTest(root, transport: .session, watchdog: .seconds(10), onShutdown: {})
  try s.listen()
  let host = XPCServiceHost(peerHandler: { channel in
    channel.setIncomingHandler { $0.reply($0.payload) }
  })
  let nativeC = try XPCChannelAcceptor(C(), handler: { host.bind($0) })
  let session = try XPCChannelAcceptor(sessionDelegate: S(), handler: { host.bind($0) })
  let generic = try XPCChannelTransport.session.acceptor { host.bind($0) }
  try nativeC.activate(); try session.activate(); try generic.activate()
}
@available(macOS 26.0, *)
func secureSession() throws -> XPCChannelAcceptor {
  try XPCChannelAcceptor(sessionDelegate: S(), service: "example.service",
    requirement: .isPlatformCode(), handler: { $0.activate() })
}
'''
checks={
 'positive':positive,
 'session_with_c_delegate':common+'func invalid<R: XPCRootActor>(_ r: R.Type) { _ = XPCActorService(r, sessionDelegate: C()) }',
 'c_with_session_delegate':common+'func invalid<R: XPCRootActor>(_ r: R.Type) { _ = XPCActorService(r, S()) }',
 'delegate_with_runtime_transport':common+'func invalid<R: XPCRootActor>(_ r: R.Type) { _ = XPCActorService(r, C(), transport: .session) }',
 'session_listener_with_c_delegate':common+'func invalid() throws { _ = try XPCChannelAcceptor(sessionDelegate: C(), handler: { _ in }) }',
 'secure_listener_without_service':common+'@available(macOS 26.0, *) func invalid() throws { _ = try XPCChannelAcceptor(sessionDelegate: S(), requirement: .isPlatformCode(), handler: { _ in }) }',
 'secure_listener_with_nil_service':common+'@available(macOS 26.0, *) func invalid() throws { _ = try XPCChannelAcceptor(sessionDelegate: S(), service: nil, requirement: .isPlatformCode(), handler: { _ in }) }',
 'handlerless_listener':common+'func invalid() throws { _ = try XPCChannelTransport.session.acceptor() }',
 'channel_c_identity':common+'func invalid(_ channel: XPCChannel) { _ = channel.pid }',
 'channel_interruption':common+'func invalid(_ channel: XPCChannel) { channel.addInterruptionHandler {} }',
 'channel_requirement':common+'func invalid(_ channel: XPCChannel) throws { try channel.applyPeerCodeSigningRequirement("x") }',
 'mutable_host_routing':common+'func invalid(_ host: XPCServiceHost) { host.setPeerHandler { _ in } }',
 'mutable_listener_routing':common+'func invalid(_ listener: XPCChannelAcceptor) { listener.setAcceptHandler { _ in } }',
}
expected_symbols = {
 'session_with_c_delegate': ('XPCSessionServiceDelegate',),
 'c_with_session_delegate': ('XPCConnectionServiceDelegate',),
 'delegate_with_runtime_transport': ('transport',),
 'session_listener_with_c_delegate': ('XPCSessionServiceDelegate',),
 'secure_listener_without_service': ('service',),
 'secure_listener_with_nil_service': ('String',),
 'handlerless_listener': ('handler',),
 'channel_c_identity': ('pid',),
 'channel_interruption': ('addInterruptionHandler',),
 'channel_requirement': ('applyPeerCodeSigningRequirement',),
 'mutable_host_routing': ('setPeerHandler',),
 'mutable_listener_routing': ('setAcceptHandler',),
}
cmd = [
    "swiftc", "-typecheck", "-swift-version", "6", "-warnings-as-errors",
    "-target", f"{platform.machine()}-apple-macos15.0",
]
# SwiftBuild places modules beside products; native SwiftPM uses Modules/.
for module_path in (bin_path, bin_path / "Modules"):
    if module_path.is_dir():
        cmd.extend(["-I", str(module_path)])
failures = []
for name, source in checks.items():
    probe = out / (name + ".swift")
    probe.write_text(source)
    result = subprocess.run(cmd + [str(probe)], capture_output=True, text=True)
    (out / (name + ".log")).write_text(result.stdout + result.stderr)
    valid = result.returncode == 0 if name == "positive" else (
        result.returncode > 0
        and 'error:' in result.stderr
        and all(symbol in result.stderr for symbol in expected_symbols[name])
    )
    print(name + ": " + ("PASS" if valid else "FAIL"))
    if not valid:
        failures.append(name)
        print(result.stderr[:3000])
if failures:
    raise SystemExit(1)

# Record the inventory and check selected names. This is not a baseline diff:
# arbitrary new public declarations still require manual artifact review.
result = subprocess.run(
    ["swift", "package", "dump-symbol-graph", "--minimum-access-level", "public",
     "--skip-synthesized-members"],
    cwd=workspace, capture_output=True, text=True,
)
(out / "symbol-graph.log").write_text(result.stdout + result.stderr)
result.check_returncode()
match = re.search(r"(?:Files written to|Symbol graph files written to)\s+(.+)", result.stdout)
if match:
    graphs = Path(match.group(1).strip().rstrip("."))
else:
    graphs = workspace / ".build/out/symbolgraph"
    if not graphs.is_dir():
        candidates = list((workspace / ".build").glob("**/symbolgraph"))
        if len(candidates) != 1:
            raise SystemExit("Cannot identify generated symbol graph directory")
        graphs = candidates[0]
inventory = []
for path in sorted(graphs.glob("*.json")):
    graph = json.loads(path.read_text())
    if graph["module"]["name"] not in ("SwiftXPC", "DistributedXPC"):
        continue
    for symbol in graph["symbols"]:
        uri = symbol.get("location", {}).get("uri", "")
        if "/Sources/SwiftXPC/" not in uri and "/Sources/DistributedXPC/" not in uri:
            continue
        inventory.append({
            "module": graph["module"]["name"], "path": symbol["pathComponents"],
            "kind": symbol["kind"]["identifier"], "source": uri,
        })
if not inventory:
    raise SystemExit("Owned API symbol inventory is empty")
top = {entry["path"][0] for entry in inventory}
required = {
    "XPCChannel", "XPCServiceDelegate", "XPCConnectionServiceDelegate",
    "XPCSessionServiceDelegate", "XPCActorService", "XPCMarshalRuntime",
}
removed = {"XPCMessageChannel", "XPCPeerContext", "XPCServiceConfiguration"}
if not required <= top or removed & top:
    raise SystemExit("Unexpected public API symbol inventory")
revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=workspace, text=True).strip()
dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], cwd=workspace, text=True).strip())
(out / "public-symbols.json").write_text(json.dumps({
    "revision": revision, "working_tree_dirty": dirty, "symbols": inventory,
}, indent=2) + "\n")
print(f"symbol graph: PASS (selected-name guards; {len(inventory)} owned declarations recorded)")
print("symbol graph: no baseline diff; new public declarations require manual review")
print(f"verification evidence: {out}")
