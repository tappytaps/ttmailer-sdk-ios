// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TTMailer",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "TTMailer", targets: ["TTMailer"]),
    ],
    targets: [
        .target(name: "TTMailer", path: "Sources/TTMailer", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "TTMailerTests", dependencies: ["TTMailer"], path: "Tests/TTMailerTests"),
    ]
)
