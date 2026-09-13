# Deutung der Track-Version-Namen

Die Namen kommen aus der Playback-Abteilung und sind gewachsen, nicht genormt.
Reale Beispiele aus `GS25_260821.npr`:

```
Julian                      Denise                      v1
Marc Safety                 Marc Safety                 Abgenommen von Tobi
Julian Safety & Ballett     Markus Ballett & Cut        Ganze Show 251116
Julia 260813                Katalin260814               260627
```

## Normalisierung

Vor jeder Deutung:

1. Geschützte Leerzeichen zu normalen, Mehrfach-Leerzeichen kollabieren, trimmen
   → `'Marc Safety '` wird `'Marc Safety'`
2. Fehlendes Leerzeichen vor einem angehängten 6-stelligen Datum einfügen
   → `'Katalin260814'` wird `'Katalin 260814'`

Beides kommt im Referenzprojekt vor. Ohne diesen Schritt gelten `'Marc Safety'` und
`'Marc Safety '` als zwei verschiedene Personen.

## Zerlegung

`Versionsname = Basisname + Marker + Datum`

| Element | Erkennung | Bedeutung |
|---|---|---|
| Datum | 6 Ziffern am Ende | Neuaufnahme vom TT.MM.JJ |
| `Safety` | Wort | Absicherungsfassung — ändert die Person **nicht** |
| `Ballett` | Wort | macht den Eintrag zur **Cover-Variante** des gleichnamigen Principals |
| `Cut` | Wort | Fassung für "Rolle gestrichen" — läuft ebenfalls über die Ballett-Variante |
| Basisname | was übrig bleibt | der Sänger |

## Was keine Person ist

Diese Einträge werden verworfen, der Slot bleibt leer:

- `v1`, `v2`, … — Nuendos Default-Name
- reines Datum (`260627`)
- `Abgenommen von …`, `Ganze Show …`
- `Kopie`, `Copy`, `Backup`, `alt`, `neu`, `Test` am Anfang
- alles mit mehr als drei Wörtern oder mit Ziffern im Namen

Ein Track gilt als **Cast-Track**, wenn er mindestens zwei Versionen hat und
**alle** davon Personen sind. Teils Person / teils nicht → der Track wird **nicht**
übernommen, sondern im Report zur Entscheidung vorgelegt.

Das verwirft im Referenzprojekt 287 von 311 Tracks — praktisch alle Mikrofonspuren,
die nur `v1` + `Abgenommen von Tobi` tragen.

## Abbildung auf CastPilot

| Nuendo | CastPilot |
|---|---|
| Listenposition der Track Version | Slot-Nummer (`slotAssignments[n-1]`) |
| Anzahl Track Versions | `NuendoTrack.versionCount` |
| Basisname ohne `Ballett` | `CastMember` (Principal) |
| Basisname mit `Ballett` | `CastMember` mit `coverVariantOf` = Principal, Name `"X & Ballett"` |
| Reihenfolge im Haupt-Playback-Track | `CastMember.versionPosition` |
| erstes Wort des Tracknamens | `Role.name` |

### Warum die Ballett-Deutung sicher ist

`fireMidi()` wählt den Slot so (MidiCastTrigger.swift:551):

```swift
let resolvedSlot = preferVariant ? (variantSlot ?? principalSlot)
                                 : (principalSlot ?? variantSlot)
```

Gibt es auf einem Track nur die Ballett-Fassung einer Person, greift bei normaler
Auswahl der Fallback `principalSlot ?? variantSlot` — der Slot wird trotzdem
angefahren. Wird ein Cover gewählt oder ist die verknüpfte Rolle gestrichen, gewinnt
die Variante. Genau das ist gewollt.

**Einschränkung:** Die App findet pro Principal nur **eine** Variante
(`members.first(where: coverVariantOf == …)`). Zwei Ballett-Fassungen derselben Person
in einer Rolle meldet die Validierung als Fehler.

## Tracknamen: Projekt vs. Generic-Remote-XML

Die Versionsnamen oben betreffen die *Sänger*. Davon unabhängig weichen die **Track**-Namen
zwischen Nuendo-Projekt und Generic-Remote-XML ab, weil beide von verschiedenen Leuten
gepflegt werden:

| Projekt | XML | |
|---|---|---|
| `Luci …` | `Select Lucy …` | reine Schreibweise |
| `… HH` | `… HS` | Handheld = Handsender, dasselbe Mikrofon |
| `… TS` | `… TS` | Taschensender / Headset, identisch |
| `… PB` (MIDI-Spur) | `… MIDI` | über die Trackart aufgelöst |

Die ersten beiden werden per `--alias HH=HS --alias Luci=Lucy` überbrückt, Token für Token
und ohne Rücksicht auf Groß-/Kleinschreibung. Das dritte macht der Skill selbst.

Die **Rollennamen im Show-File kommen aus dem Projekt**, nicht aus der XML — die Rolle heißt
also `Luci`, auch wenn das Control `Select Lucy PB` heißt.

## Mehrere datierte Fassungen

`Oxy TS` trägt fünf Julia-Fassungen (`260701` … `260818`). CastPilot kann pro Track nur
**einen** Slot je Person ansteuern, deshalb: **das jüngste Datum gewinnt**, die älteren
Slots bleiben leer und stehen im Report.

Stimmt das nicht — läuft heute z. B. bewusst eine ältere Fassung — muss der Slot in
CastPilot von Hand gesetzt werden.
