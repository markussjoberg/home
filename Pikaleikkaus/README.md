# Pikaleikkaus

Minimaalinen videoeditori iPhonelle: muutama klippi yhteen, trimmaus,
suora leikkaus tai crossfade, äänet hallintaan — ei mitään muuta.
Tarkoitettu nopeisiin pätkiin Viesteihin/WhatsAppiin ja someen.

## Ominaisuudet (MVP)

- Klippien tuonti Kuvista (`PhotosPicker`), useita kerralla
- Klippien järjestely, trimmaus ja poisto (pitkä painallus → valikko)
- Pysty 9:16 tai vaaka 16:9 -lopputulos; klipit sovitetaan (aspect fit)
- Klipin kääntö 90° askelin
- Suora leikkaus tai crossfade (säädettävä 0,2–1,5 s)
- Ääni irti kuvasta:
  - klipin oman äänen mykistys ja voimakkuus
  - "Käytä vain ääni" — klipin ääni taustalle ilman kuvaa
  - musiikki/puhe äänitiedostosta (Tiedostot-appi)
  - taustaraidat alkavat ajasta 0 ja katkeavat videon loppuun
- Esikatselu (`AVPlayer` + sama kompositio kuin exportissa)
- Vienti mp4:ksi ja jako natiivilla share sheetillä
  ("Tallenna video" vie Kuviin)

## Rakentaminen

Vaatii Macin ja Xcode 15:n tai uudemman (iOS 17 -kohde).

1. Avaa `Pikaleikkaus.xcodeproj` Xcodessa
2. Valitse Signing & Capabilities -välilehdeltä oma tiimisi
   (bundle id `fi.sjoberg.Pikaleikkaus` — vaihda tarvittaessa)
3. Aja omalla iPhonella (simulaattorissa Kuvat-kirjasto on tyhjähkö)

## Arkkitehtuuri

| Tiedosto | Vastuu |
|---|---|
| `Models/Clip.swift` | Klippi: trimmausväli, mute, volume, kierto, "pelkkä ääni" -lippu |
| `Models/EditorModel.swift` | Aikajanan tila, esikatselun päivitys, vienti |
| `Engine/CompositionBuilder.swift` | `AVMutableComposition`: A/B-videoraidat crossfadea varten, opacity-rampit, orientaatio- ja sovitustransformit, `AVAudioMix` |
| `Engine/Exporter.swift` | `AVAssetExportSession` → mp4 |
| `Views/` | SwiftUI: editori, aikajana, trimmaus |

Kompositio rakennetaan samalla koodilla sekä esikatseluun että vientiin,
joten mitä näet, sen saat.

## Jatkokehitysideoita

- Share-extension: valitse klipit Kuvissa → jaa → Pikaleikkaus
- Kuvat-tyylinen trimmauskahva-UI sliderien tilalle
- Aaltomuoto ääniriveille
- Taustaraidan aloituskohdan siirto (J/L-leikkaukset offsetilla)
- Passthrough-vienti (ei uudelleenpakkausta), kun yksi klippi eikä muunnoksia
- Äänen volume-rampit crossfaden kohdalla (nyt raidat soivat päällekkäin,
  mikä toimii käytännössä ristihäivytyksenä)
