# Noste – tietosuojaseloste (luonnos)

Rekisterinpitäjä: Aihio Labs Oy, yhteys: markus.sjoberg@gmail.com. Päivitetty 3.9.2026.

## Periaate

Liikuntadatasi on sinun. Sessioiden GPS-jälki, nopeus, syke, kiihtyvyysanturin
raakadata ja niistä lasketut tulokset **tallennetaan vain puhelimeesi ja
Apple Watchiin** sekä halutessasi Applen Terveys-sovellukseen (HealthKit).
Niitä ei lähetetä Nosten palvelimelle eikä kolmansille osapuolille. Voit viedä
ne itse tiedostona (GPX, raakadata) ja poistaa ne poistamalla session tai sovelluksen.

## Mitä palvelimelle tallennetaan

Nosten palvelin (Hetzner, Suomi/EU) tallentaa vain seuraavat tiedot:

1. **Tili** (vain jos kirjaudut Sign in with Applella): Applen antama pysyvä
   käyttäjätunniste, valitsemasi nimimerkki, tilin luontiaika. Sähköpostiosoitetta
   ei pyydetä eikä tallenneta. Salasanoja ei ole.
2. **Laitetunniste**: sovelluksen luoma satunnainen avain, josta palvelimelle
   lähetetään vain tiiviste (hash). Sillä osoitetaan julkaistujen spottien ja
   kommenttien omistus ilman tiliä.
3. **Omat spotit ja kelivahtihälytykset** (vain kirjautuneena): spottien nimet,
   sijainnit, muistiinpanot ja tuulirajat sekä hälytysrajat. Käytetään varmuuskopiona,
   laitteelta toiselle siirtoon ja kelivahdin ennustetarkistuksiin.
4. **Yhteisösisältö**: julkaisemasi spotit (nimi, sijainti tai karkea sijainti,
   kuvaus, lajit, suunnat, rajat), kommenttisi nimimerkillä, muokkaushistoria
   (kuka nimimerkillä, milloin, mitä) sekä tekemäsi ilmoitukset asiattomasta
   sisällöstä. Yhteisösisältö on julkista kaikille Nosten käyttäjille.
5. **Ilmoitukset**: sovelluksen sisäiset ilmoitukset sinulle (kelivahdin osumat,
   kommentit spotteihisi, poistoehdotukset).
6. **Tekniset lokit**: palvelin kirjaa virhetilanteet; pyyntölokeja ei säilytetä
   pysyvästi.

## Kolmannet osapuolet, joille sovellus tekee kyselyitä

Sovellus hakee palvelimen kautta sää- ja karttatietoa. Kyselyissä kulkee
karttanäkymän tai spotin sijainti, ei henkilötietoja: Ilmatieteen laitos
(havainnot, aaltopoijut, WAM), Open-Meteo (ennusteet, tuuli- ja aaltohilat),
Maanmittauslaitos ja Traficom (karttatiilet), OpenStreetMap ja Lipas (rantainfo),
Lappis (kalustokatalogi, ei tilaustietoja). Applen Kartat ja Sign in with Apple
toimivat Applen omilla ehdoilla.

## Säilytys ja poisto

- Tilin voit poistaa sovelluksesta (Asetukset → Tili → Poista tili). Poisto
  hävittää tunnisteen, istunnot, laitesidonnat, omat spotit, hälytykset ja
  ilmoitukset välittömästi. Julkaisemasi spotit ja kommentit jäävät yhteisölle
  wikimäisesti, mutta ne irrotetaan tilistäsi eikä niitä voi enää yhdistää sinuun
  muuten kuin nimimerkin tekstinä.
- Julkaistun spotin voit poistaa itse, jos muut eivät ole lisänneet siihen sisältöä.
  Muussa tapauksessa poisto etenee 7 päivän ehdotuksena. Poistot ovat pehmeitä:
  historia säilyy palvelimella väärinkäytösten selvittämistä varten.
- Ilman tiliä palvelimella on vain julkaisemasi yhteisösisältö laitetunnisteen
  tiivisteellä.

## Oikeutesi

Voit pyytää tietojesi kopion tai poiston yhteysosoitteesta. Sovelluksen omat
näkymät (Omat julkaisut, Ilmoitukset) näyttävät sinusta tallennetun sisällön.

## Muutokset

Selostetta päivitetään, kun sovellus muuttuu. Merkittävistä muutoksista
kerrotaan sovelluksessa.
