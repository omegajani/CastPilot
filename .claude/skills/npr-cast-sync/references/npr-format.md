# Nuendo `.npr` — Binärformat, soweit für Track Versions nötig

Reverse Engineering gegen `GS25_260821.npr` (Nuendo, 24 MB, 311 Track-Version-Listen,
alle 311 fehlerfrei geparst). Alles Big-Endian.

Dieses Dokument ist zugleich die Vorlage für einen späteren Swift-Port in CastPilot.

## Container

```
Offset 0   "RIFF"
Offset 4   u32  Dateigröße
Offset 8   "NUNDROOT"
Offset 16  Objektbaum
```

## Objekt

Jedes Objekt beginnt mit einer Klassenreferenz:

| Erste 4 Bytes | Bedeutung |
|---|---|
| `FF FF FF FF` | Inline-Klassendefinition — es folgt `u32 len` + NUL-terminierter ASCII-Klassenname |
| `FF FF FF FE` | dasselbe, aber für eine **Basisklasse** der Vererbungskette |
| High-Bit gesetzt | Referenz auf eine bereits definierte Klasse |

Eine Klasse wird genau einmal inline definiert; alle weiteren Instanzen referenzieren sie.
Die Referenz ist ein **Rückzeiger auf die Definitionsstelle**:

```
ref = 0x80000000 | (offset_der_definition − root_base)
root_base = Offset der GDocument-Definition (in der Praxis 0xE8)
```

Danach folgt:

```
[2 Byte Flags]   ← NUR bei Inline-Definition, nicht bei einer Referenz
u32 payloadSize
payload[payloadSize]
```

Dieser Unterschied ist die häufigste Fehlerquelle: bei referenzierten Klassen liegt die
Größe direkt hinter den 4 Referenz-Bytes.

Beim Anlegen eines neuen Objekttyps schreibt Nuendo erst die Basisklassenkette
(`FF FF FF FE`), dann die eigentliche Klasse (`FF FF FF FF`):

```
FF FF FF FE  00000008  "CmArray\0"
FF FF FF FE  00000012  "CmContainer\0"
FF FF FF FF  0000001A  "MTrackVariationCollection\0"
```

## Strings

Ein String-**Wert** ist `u32 len` + UTF-8, terminiert auf `00 EF BB BF` (NUL + UTF8-BOM);
`len` zählt den Terminator mit.

Ein Attribut**name** ist NUL-terminiertes ASCII **ohne** BOM. Daran lassen sich beide
sauber unterscheiden — wichtig, weil sonst Attributnamen als Werte durchrutschen.

## Track Versions

Nuendo nennt Track Versions intern **`MTrackVariation`**. Sie hängen in einer
`MTrackVariationCollection` am Track-Event:

```
MTrackVariationCollection
  u32 tag  (0x0000000A)
  u16 typ  (0x0002)
  u32 count
  count × MTrackVariation
      String  Versionsname       ← das, was Nuendo im Track-Version-Menü anzeigt
      …       Events dieser Version
```

**Die Listenposition ist die Slot-Nummer, auf die CastPilot schaltet.** Slot 1 = erster
Eintrag. Eine `MTrackVariation` kann sehr groß sein (sie enthält die Events ihrer
Fassung) — man muss über `payloadSize` springen, nicht linear scannen.

## Trackzuordnung

Jede Klasse, die auf `M…TrackEvent` endet, ist eine Spur (`MAudioTrackEvent`,
`MMidiTrackEvent`, dazu global `MTempoTrackEvent`, `MSignatureTrackEvent`,
`MMarkerTrackEvent`). Ihr `payloadSize` spannt den Bereich auf, in dem die Collection
liegt.

Spuren können schachteln, deshalb gewinnt bei der Zuordnung der **kleinste** Bereich,
der die Collection enthält — nicht einfach der zuletzt begonnene.

Der **erste String-Wert** im Payload eines Track-Events ist der Trackname.

## Grenzen

- Tracknamen sind **nicht eindeutig**. Im Referenzprojekt existiert jede `… PB`-Spur
  doppelt (Kopfhörer- und Saal-Playback). Nur die Projektreihenfolge trennt sie.
- MIDI-Zuordnung, Routing, Plugin-Werte und Automationsdaten liegen als Event-Binär-
  blöcke vor und werden hier **nicht** dekodiert.
- Getestet gegen Header `RIFF…NUNDROOT`. Ältere Cubase-Projekte sind ungeprüft.
