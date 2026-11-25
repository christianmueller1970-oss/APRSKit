// swift-tools-version: 5.9
import PackageDescription

// APRSKit — APRS-Protokollkern und AX.25-Funkmodem für macOS.
// Zwei Produkte, beide UI-frei und ohne externe Dependencies:
//   APRSKit  TNC2-Parser, Encoder, APRS-IS-Protokoll, iGate-Regeln,
//            Nachrichten, Stationsspeicher, Sendeschutz (nur Foundation)
//   AX25Kit  UI-Rahmen, HDLC und AFSK-1200-Modem (Foundation, Accelerate)
// Herausgelöst aus HAM-Tools (Stand fad5e0aa); Tools-Version und damit der
// Sprachmodus bleiben wie dort, damit sich am Verhalten nichts ändert.
let package = Package(
    name: "APRSKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "APRSKit", targets: ["APRSKit"]),
        .library(name: "AX25Kit", targets: ["AX25Kit"]),
    ],
    targets: [
        .target(name: "APRSKit"),
        .target(name: "AX25Kit"),
        // Die Korpus-Dateien werden über #filePath gelesen, nicht über
        // Bundle.module — deshalb vom Target ausgeschlossen. AX25KitTests
        // liest denselben Korpus aus ../APRSKitTests/Resources.
        .testTarget(
            name: "APRSKitTests",
            dependencies: ["APRSKit"],
            exclude: ["Resources"]
        ),
        .testTarget(
            name: "AX25KitTests",
            dependencies: ["AX25Kit"]
        ),
    ]
)
