# Edith

**Edith — for everyday video editing.**
Connect your clips, add a soundtrack. That's it.

Minimaalinen videoeditori iPhonelle: muutama klippi yhteen, trimmaus,
suora leikkaus tai crossfade, äänet hallintaan — ei mitään muuta.
Tarkoitettu nopeisiin pätkiin Viesteihin/WhatsAppiin ja someen.

## Ominaisuudet

- Klippien tuonti Kuvista (`PhotosPicker`), useita kerralla
- **Share-extension**: valitse videot Kuvissa → jaa → Edith → leikkaa →
  tallenna Kuviin, ilman että avaat appia erikseen
- Klippien järjestely, poisto ja säädöt (pitkä painallus → valikko)
- **Kuvat-tyylinen trimmaus**: keltaiset vedettävät kahvat filminauhan
  (videolla) tai aaltomuodon (äänellä) päällä
- Pysty 9:16 tai vaaka 16:9 -lopputulos; klipit sovitetaan (aspect fit)
- Klipin kääntö 90° askelin
- Suora leikkaus tai crossfade (säädettävä 0,2–1,5 s) — myös ääni
  ristihäivytetään volume-rampeilla
- Ääni irti kuvasta:
  - klipin oman äänen mykistys ja voimakkuus
  - "Käytä vain ääni" — klipin ääni taustalle ilman kuvaa
  - musiikki/puhe äänitiedostosta (Tiedostot-appi)
  - taustaraidan aloituskohdan voi siirtää aikajanalla (J/L-tyyliin);
    raita katkeaa viimeistään videon loppuun
  - aaltomuodot ääniriveillä (`AVAssetReader` → huippuarvot)
- **Passthrough-vienti**: yksi klippi ilman muunnoksia trimmataan ilman
  uudelleenpakkausta — alkuperäinen laatu säilyy
- Esikatselu (`AVPlayer` + sama kompositio kuin viennissä)
- Vienti ja jako natiivilla share sheetillä tai suoraan Kuviin

## Rakentaminen

Vaatii Macin ja Xcode 15:n tai uudemman (iOS 17 -kohde).

1. Avaa `Edith.xcodeproj` Xcodessa
2. Valitse Signing & Capabilities -välilehdeltä oma tiimisi molemmille
   targeteille (Edith ja EdithShare; bundle id:t `fi.sjoberg.Edith` ja
   `fi.sjoberg.Edith.share` — vaihda tarvittaessa)
3. Aja Edith-target omalla iPhonella; share-extension asentuu samalla ja
   löytyy Kuvien jakovalikosta (tarvittaessa jakovalikon "Muokkaa
   toimintoja" -kohdasta päälle)

Huomio: share-extensioneilla on tiukka muistiraja (~120 MB), joten hyvin
pitkien 4K-videoiden vienti kannattaa tehdä itse appissa.

## Arkkitehtuuri

| Tiedosto | Vastuu |
|---|---|
| `Edith/Models/Clip.swift` | Klippi: trimmausväli, mute, volume, kierto, offset, aaltomuoto, "pelkkä ääni" -lippu |
| `Edith/Models/EditorModel.swift` | Aikajanan tila, esikatselun päivitys, vienti (passthrough tai kompositio) |
| `Edith/Engine/CompositionBuilder.swift` | `AVMutableComposition`: A/B-raidat crossfadea varten, opacity- ja volume-rampit, orientaatio- ja sovitustransformit |
| `Edith/Engine/Exporter.swift` | `AVAssetExportSession` (highest quality / passthrough), tallennus Kuviin |
| `Edith/Engine/WaveformLoader.swift` | PCM-luku ja huippuarvot aaltomuotoon |
| `Edith/Views/` | SwiftUI: editori, aikajana, trimmauskahvat |
| `EdithShare/` | Share-extension: sama editori Kuvien jakovalikosta |

Editori ja moottori ovat samat molemmissa targeteissa (tiedostot
käännetään kumpaankin), ja kompositio rakennetaan samalla koodilla sekä
esikatseluun että vientiin — mitä näet, sen saat.

## Jatkokehitysideoita

- Klipin oman äänen J/L-jatko naapuriklipin puolelle
- Trimmauskahvojen live-esikatselu (kelaus kahvaa vetäessä)
- Taustaraidan häivytys sisään/ulos
- Projektin tallennus (nyt sessio elää vain muistissa)
