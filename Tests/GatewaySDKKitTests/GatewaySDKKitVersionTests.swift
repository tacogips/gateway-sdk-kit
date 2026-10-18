import Testing
@testable import GatewaySDKKit

@Test func versionIsSet() {
  #expect(GatewaySDKKitVersion.current == "0.1.1")
}
