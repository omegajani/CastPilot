---
name: npr-cast-sync
description: >
  Liest aus einem Nuendo-Projekt (.npr) die Track-Version-Reihenfolge der Sänger
  aus und baut daraus eine CastPilot-Showdatei (.castpilot) — inklusive Slot-
  Belegung, Ballett-Varianten und MIDI-Select-Kommandos aus der Generic-Remote-XML.
  Auslösen bei: "Trackversionen aus Nuendo", "Cast-Reihenfolge prüfen", "CastPilot
  aus npr aktualisieren", ".npr nach CastPilot", "Slot-Reihenfolge stimmt nicht",
  "welcher Sänger liegt auf welchem Slot", "Show-File aus Nuendo bauen".
  NICHT für Marker/Timecode/Cue-Listen aus Nuendo — dafür ist nuendo-npr-reader da.
---

# .npr → CastPilot

## Wozu

CastPilot schaltet in Nuendo per MIDI die Track Version, die zum heutigen Cast gehört.
Welcher Sänger auf welchem Slot liegt, wurde bisher von Hand gepflegt. Ändert die
Playback-Abteilung die Reihenfolge der Track Versions oder kommt eine dazu, schaltet
CastPilot still auf den falschen Sänger — und das fällt erst in der Vorstellung auf.

Dieser Skill liest die Reihenfolge direkt aus dem Projekt.

## Was gebraucht wird

1. das Nuendo-Projekt (`.npr`)
2. die Generic-Remote-XML, die in Nuendo importiert ist (im CastPilot-Release-Zip
   als `midi list nuendo.xml`) — ohne sie bekommt kein Track ein MIDI-Kommando
3. möglichst die laufende `config.json` aus
   `~/Library/Application Support/MidiCastSwitcher/` als `--base`

## Ablauf

Immer in dieser Reihenfolge. Schritt 2 ist eine echte Rückfrage, nicht Deko — die
Namensdeutung ist heuristisch und die Show hängt dran.

### 1. Auslesen und Report zeigen

```bash
python3 scripts/build_castpilot_show.py --npr <projekt.npr> --dry-run \
    --remote-xml "midi list nuendo.xml" \
    --alias HH=HS --alias Luci=Lucy \
    --base ~/Library/Application\ Support/MidiCastSwitcher/config.json
```

`--base` mitgeben, wann immer erreichbar: nur dann zeigt der Report einen **Diff**
("Slot 3: Daniel → Marc GEÄNDERT") statt einer Liste ohne Bezug, und nur dann bleiben
UUIDs, E-Mail-Keywords, Cover und MIDI-Einstellungen erhalten.

**Aliase:** Projekt und XML driften auseinander, weil sie von verschiedenen Leuten
gepflegt werden. `--alias` schreibt einzelne Wörter im Tracknamen um. Die oben genannten
Paare gelten für die Grand Show; bei einer anderen Produktion erst ohne Alias laufen
lassen und im Report unter „Tracks ohne Control" / „Controls ohne Track" ablesen, welche
Paare nötig sind. Der Skill rät **nicht** — ein Fuzzy-Match hätte im Test `Endo PB` auf
`Select Endo TS` gelegt und damit den falschen Track angewählt.

### 2. Report mit dem Nutzer durchgehen

Den Report **vollständig zeigen** und explizit nachfragen zu:

- **Verworfene Tracks** — ohne Select-Kommando fliegt ein Track raus. Grund unten.
- **Ballett-Varianten** — jede Deutung `"X & Ballett"` → Variante von `X` bestätigen lassen.
- **Ältere datierte Fassungen** — der Skill nimmt die jüngste. Läuft heute bewusst eine
  ältere, muss der Slot von Hand gesetzt werden.
- **Darsteller ohne Slot** — bleiben wählbar, schalten aber nichts.
- **Unklare Tracks** — teils Person, teils nicht. Wurden nicht übernommen.
- **Blätter-Kommandos** — kommen aus der XML und überstimmen `--base`. Weicht die alte
  Konfiguration ab, steht das als Warnung im Report.

Bei Zweifeln an der Rollen-Gruppierung: `--role-regex` anpassen. Default ist das erste
Wort des Tracknamens (`Dream PB` → Rolle `Dream`).

### 3. Erst nach Bestätigung schreiben

Denselben Aufruf ohne `--dry-run`, mit `-o <Show>.castpilot`.

Dann in CastPilot über **Show importieren** laden. Danach unbedingt **einen Track gegen
Nuendo gegenprüfen** — Skript und App teilen keinen Code, der Abgleich am echten Pult ist
die einzige harte Verifikation.

Das Script schreibt nie in die laufende `config.json`, immer nur eine separate Datei.

## Warum Tracks ohne Select-Kommando rausfliegen

`fireMidi()` sendet pro Track erst `selectCommand`, dann `prevVersionCommand` ×
(versionCount−1), dann `nextVersionCommand` × (Slot−1).

Ein Track ohne wirksames Select-Kommando wählt nichts an — **die Blätter-Befehle werden
aber trotzdem gesendet** und treffen den Track, der in Nuendo gerade ausgewählt ist. Der
verstellt dann seine Version. Ein unbrauchbarer Track ist also nicht harmlos, sondern
verstellt einen anderen.

Ihre Darsteller bleiben trotzdem in der Rolle, damit niemand aus dem Live-Picker
verschwindet; sie stehen im Report unter „Darsteller ohne Slot".

`--keep-unmapped` hebt das Verwerfen auf — nur benutzen, wenn die Controls gleich danach
in Nuendo angelegt werden. Gibt es weder `--remote-xml` noch `--base`, bleiben alle Tracks
stehen: dann baut man erkennbar nur ein Gerüst.

## Scripts

| Script | Zweck |
|---|---|
| `scripts/read_track_versions.py` | `.npr` → Track-Version-Listen als JSON/CSV. Einzeln nutzbar für „welche Versionen hat Track X?". `--selftest` prüft gegen bekannte Werte. |
| `scripts/read_generic_remote.py` | Generic-Remote-XML → Select-Kommandos und Blätter-Kommandos. `--dump` zeigt die XML-Struktur, wenn nichts erkannt wird. `--selftest` prüft gegen die Fixtures. |
| `scripts/build_castpilot_show.py` | Alles zusammen → `.castpilot`. |

Nie das `.npr` direkt lesen — die Datei ist 20–30 MB groß.

## Wenn die Generic-Remote-XML nicht erkannt wird

```bash
python3 scripts/read_generic_remote.py "midi list nuendo.xml" --dump
```

zeigt die tatsächlichen Tags und markiert, welche als Feld erkannt wurden. Fehlende
Schreibweisen in `FIELD_ALIASES` ergänzen — ein Eintrag pro Feld. Steinberg hat das Layout
mehrfach geändert; genau so wurde das echte Format nachgezogen.

## Hintergrund

- `references/npr-format.md` — das `.npr`-Binärformat, auch als Vorlage für einen
  späteren Swift-Port in die App.
- `references/generic-remote-format.md` — das XML-Format, die Doppelbedeutung von
  `<chan>`, und warum `step up` Previous Version ist.
- `references/naming-rules.md` — wie `Safety`, `& Ballett`, `Ballett & Cut`,
  Datums-Suffixe und die Track-Namensunterschiede gedeutet werden.
- `tests/fixtures/` — anonymisierte XML-Nachbauten für die Selbsttests.
