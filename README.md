# APRSKit

APRS-Protokollkern und AX.25-Funkmodem in Swift, UI-frei und ohne externe Abhängigkeiten.
Herausgelöst aus HAM-Tools; genutzt von HAM-Tools und «HAM-Tools APRS».

| Produkt | Inhalt | Abhängigkeiten |
|---|---|---|
| `APRSKit` | TNC2-Parser, Positionen (auch Mic-E), Objekte, Wetter, Nachrichten, Encoder, APRS-IS-Protokoll, iGate-Regeln, Stationsspeicher, Sendeschutz | `Foundation` |
| `AX25Kit` | AX.25-UI-Rahmen, HDLC (FCS, Bit-Stuffing), AFSK-1200-Modulator und -Demodulator | `Foundation`, `Accelerate` |

Plattform: macOS 14 oder neuer.

## Einbinden

```swift
.package(url: "<Repo-URL>", from: "1.0.0"),
// …
.product(name: "APRSKit", package: "APRSKit"),
.product(name: "AX25Kit", package: "APRSKit"),
```

## Testen

```sh
swift test
```

Die Tests brauchen kein Netz und keine Hardware. `Tests/APRSKitTests/Resources/corpus.txt` ist ein Mitschnitt
realer Pakete aus dem öffentlichen APRS-IS-Netz.

## Regeln

- Protokoll gehört hierher, Bedienung in die Apps.
- Kein fremder GPL-Code in diesem Package (MIT, siehe `LICENSE`).
- Breaking Changes werden im Tag und im Changelog benannt.

73 de Chris HB9HJI
