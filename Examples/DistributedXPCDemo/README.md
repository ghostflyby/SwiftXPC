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

The demo currently imports `DistributedXPC` experimental SPI for hand-written
target metadata. That should be replaced by macro-generated metadata before the
API is treated as stable.
