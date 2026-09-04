// swift-tools-version: 6.0

import PackageDescription

// gateway-sdk-kit is the gateway-independent half of every tacogips gateway
// client SDK: the neutral schema catalog, SDL printing, regex schema search,
// the operation-to-document builder, and the variable inliner. It has no
// dependencies and contains no gateway code, so linking it never widens a
// gateway's capability tier or its link boundary.
let package = Package(
  name: "gateway-sdk-kit",
  platforms: [
    .macOS(.v14)
  ],
  products: [
    .library(name: "GatewaySDKKit", targets: ["GatewaySDKKit"])
  ],
  targets: [
    .target(name: "GatewaySDKKit"),
    .testTarget(
      name: "GatewaySDKKitTests",
      dependencies: ["GatewaySDKKit"],
      resources: [.copy("Fixtures")]
    )
  ],
  swiftLanguageModes: [.v6]
)
