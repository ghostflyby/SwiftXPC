# DistributedXPC Demo

This example builds two SwiftPM executables, then assembles them into a minimal
macOS app bundle with an embedded XPC service:

```text
DistributedXPCDemo.app/
  Contents/MacOS/DemoApp
  Contents/XPCServices/DemoService.xpc/Contents/MacOS/DemoService
```

Build the bundle:

```sh
sh Examples/DistributedXPCDemo/Scripts/build-demo-bundle.sh
```

The script ad-hoc signs the app and XPC service by default. Set
`SKIP_CODESIGN=1` to skip signing, or set `CODESIGN_IDENTITY` to use a specific
identity.

Run the demo app executable from the assembled bundle:

```sh
Examples/DistributedXPCDemo/.build/demo/DistributedXPCDemo.app/Contents/MacOS/DemoApp
```

The shared `DemoGreeter` actor uses `@XPCService` to generate distributed-target
metadata. No experimental SPI or hand-written metadata table is required.

The bundle currently demonstrates packaging, connection setup, and service-side default actor
factory registration. `DemoApp` still constructs `DemoGreeter` locally, so its method calls do not yet
demonstrate remote actor discovery. A stable bootstrap API is still required before the example
can obtain a service-owned actor proxy and exercise the complete cross-process path.
