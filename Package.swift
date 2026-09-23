// swift-tools-version:5.5

import Foundation
import PackageDescription

let package = Package(
    name: "OfflineTranslator",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15)
    ],
    products: [
        .library(
            name: "OfflineTranslator",
            targets: ["OfflineTranslator"]
        )
    ],
    targets: [
        .binaryTarget(
            name: "OfflineTranslator",
            url: "https://github.com/lingvanex-mt/offline-translation-apple-sdk/releases/download/4.0.0/OfflineTranslator.xcframework.zip",
            checksum: "54a19b269730a0ed2926bae90a9f188d66d262c47b45b80610d93c4d3acd123a"
        )
    ]
)
