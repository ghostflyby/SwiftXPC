# DistributedXPC Demo

This example builds three SwiftPM executables, then assembles them into a minimal
macOS app bundle with an embedded XPC service:

```text
DistributedXPCDemo.app/
  Contents/MacOS/DemoApp
  Contents/MacOS/DemoSessionService
  Contents/XPCServices/DemoService.xpc/Contents/MacOS/DemoService
```

Build the bundle:

```sh
bash Examples/DistributedXPCDemo/Scripts/build-demo-bundle.sh
```

The script ad-hoc signs the app and XPC service by default. Set
`SKIP_CODESIGN=1` to skip signing, or set `CODESIGN_IDENTITY` to use a specific
identity.

Run the demo app executable from the assembled bundle:

```sh
Examples/DistributedXPCDemo/.build/demo/DistributedXPCDemo.app/Contents/MacOS/DemoApp
```

Pass `--session` to run the same embedded XPC service calls over the Session backend.

The shared actors use `@XPCService` to generate distributed-target metadata and
actor-reference marshaling. No experimental SPI or hand-written metadata table
is required.

`DemoRoot` is the service root actor hosted by the `DemoServiceMain` typed delegate using its protocol-provided `@main` entry point.
`DemoApp` connects with `XPCRootConnection<DemoRoot>.connect(toService:)`, obtains the remote root proxy,
and calls `makeGreeter()`; the returned `DemoGreeter` lives on its own independent
XPC channel created by actor-reference export. The greet/ping/error calls all run
across process boundaries.

`DemoSessionServiceMain` uses the Session protocol's default main and declares
its launchd service name. `Scripts/check-actor-service-lifecycle.py` registers
its temporary MachServices jobs and checks startup, cleanup, and process exit.
Neither server defines its own main; their initializers supply the root dependency.
