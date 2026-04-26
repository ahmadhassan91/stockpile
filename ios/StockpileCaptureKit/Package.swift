// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StockpileCaptureKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "StockpileDesignSystem", targets: ["StockpileDesignSystem"]),
        .library(name: "StockpileCaptureFlow", targets: ["StockpileCaptureFlow"]),
        .library(name: "StockpileMobileFirstCapture", targets: ["StockpileMobileFirstCapture"]),
        .library(name: "StockpileResultsUI", targets: ["StockpileResultsUI"]),
        .library(name: "StockpileMobileAPI", targets: ["StockpileMobileAPI"]),
        .library(name: "StockpileCameraCapture", targets: ["StockpileCameraCapture"]),
        .library(name: "StockpileUploadPipeline", targets: ["StockpileUploadPipeline"]),
        .library(name: "StockpileProcessingRuntime", targets: ["StockpileProcessingRuntime"]),
        .library(name: "StockpileOperatorDashboard", targets: ["StockpileOperatorDashboard"]),
        .library(name: "StockpileAppShell", targets: ["StockpileAppShell"]),
    ],
    dependencies: [
        // ZIPFoundation: required to produce standard PKZIP (DEFLATE) archives that
        // Python's stdlib zipfile module can unpack on the Stockpile backend.
        // Apple's AppleArchive emits a different (Apple-specific) container which
        // is not compatible with Python's zipfile reader.
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ],
    targets: [
        .target(
            name: "StockpileDesignSystem"
        ),
        .target(
            name: "StockpileCaptureFlow",
            dependencies: ["StockpileDesignSystem"]
        ),
        .target(
            name: "StockpileMobileFirstCapture",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .target(
            name: "StockpileResultsUI",
            dependencies: ["StockpileDesignSystem"]
        ),
        .target(
            name: "StockpileMobileAPI"
        ),
        .target(
            name: "StockpileCameraCapture"
        ),
        .target(
            name: "StockpileUploadPipeline"
        ),
        .target(
            name: "StockpileProcessingRuntime",
            dependencies: ["StockpileMobileAPI"]
        ),
        .target(
            name: "StockpileOperatorDashboard",
            dependencies: ["StockpileDesignSystem"]
        ),
        .target(
            name: "StockpileAppShell",
            dependencies: [
                "StockpileDesignSystem",
                "StockpileCaptureFlow",
                "StockpileResultsUI",
                "StockpileOperatorDashboard",
            ]
        ),
        .testTarget(
            name: "StockpileDesignSystemTests",
            dependencies: ["StockpileDesignSystem"]
        ),
        .testTarget(
            name: "StockpileCaptureFlowTests",
            dependencies: ["StockpileCaptureFlow"]
        ),
        .testTarget(
            name: "StockpileMobileFirstCaptureTests",
            dependencies: ["StockpileMobileFirstCapture"]
        ),
        .testTarget(
            name: "StockpileResultsUITests",
            dependencies: ["StockpileResultsUI"]
        ),
        .testTarget(
            name: "StockpileMobileAPITests",
            dependencies: ["StockpileMobileAPI"]
        ),
        .testTarget(
            name: "StockpileCameraCaptureTests",
            dependencies: ["StockpileCameraCapture"]
        ),
        .testTarget(
            name: "StockpileUploadPipelineTests",
            dependencies: ["StockpileUploadPipeline"]
        ),
        .testTarget(
            name: "StockpileProcessingRuntimeTests",
            dependencies: [
                "StockpileProcessingRuntime",
                "StockpileMobileAPI",
            ]
        ),
        .testTarget(
            name: "StockpileOperatorDashboardTests",
            dependencies: ["StockpileOperatorDashboard"]
        ),
        .testTarget(
            name: "StockpileAppShellTests",
            dependencies: ["StockpileAppShell"]
        ),
    ]
)
