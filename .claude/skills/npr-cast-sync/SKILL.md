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

## Ablauf

Immer in dieser Reihenfolge. Schritt 2 ist eine echte Rückfrage, nicht Deko — die
Namensdeutung ist heuristisch und die Show hängt dran.

### 1. Auslesen und Report zeigen

```bash
python3 scripts/build_castpilot_show.py --npr <projekt.npr> --dry-run \
    [--base ~/Library/Application\ Support/MidiCastSwitcher/config.json] \
    [--remote-xml "midi list nuendo.xml"]
```

`--base` mit der laufenden Konfiguration mitgeben, wann immer sie erreichbar ist: nur
dann zeigt der Report einen **Diff** ("Slot 3: Daniel → Marc GEÄNDERT") statt einer
Liste ohne Bezug, und nur dann bleiben UUIDs, E-Mail-Keywords, Cover und MIDI-
Einstellungen erhalten.

### 2. Report mit dem Nutzer durchgehen

Den Report **vollständig zeigen** und explizit nachfragen zu:

- **Ballett-Varianten** — jede Deutung `"X & Ballett"` → Variante von `X` einzeln
  bestätigen lassen.
- **Ältere datierte Fassungen** — der Skill nimmt die jüngste. Läuft heute bewusst
  eine ältere, muss der Slot von Hand gesetzt werden.
- **Unklare Tracks** — teils Person, teils nicht. Wurden nicht übernommen.
- **Gleiche Tracknamen** — im Referenzprojekt existiert jede `… PB`-Spur doppelt
  (Kopfhörer/Saal). CastPilot unterscheidet sie nur über verschiedene MIDI-Kommandos.
- **Fehlende MIDI-Kommandos** — ohne sie schaltet der Track nicht.

Bei Zweifeln an der Rollen-Gruppierung: `--role-regex` anpassen. Default ist das erste
Wort des Tracknamens (`Dream PB` → Rolle `Dream`).

### 3. Erst nach Bestätigung schreiben

```bash
python3 scripts/build_castpilot_show.py --npr <projekt.npr> -o <Show>.castpilot \
    [--base …] [--remote-xml …]
```

Dann in CastPilot über **Show importieren** laden. Danach unbedingt **einen Track
gegen Nuendo gegenprüfen** — Skript und App teilen keinen Code, der Abgleich am
echten Pult ist die einzige harte Verifikation.

Das Script schreibt nie in die laufende `config.json`, immer nur eine separate Datei.

## Scripts

| Script | Zweck |
|---|---|
| `scripts/read_track_versions.py` | `.npr` → Track-Version-Listen als JSON/CSV. Einzeln nutzbar für die Frage "welche Versionen hat Track X?". `--selftest` prüft gegen bekannte Werte. |
| `scripts/read_generic_remote.py` | Generic-Remote-XML → MIDI-Kommandos. `--dump` zeigt die XML-Struktur, wenn nichts erkannt wird. |
| `scripts/build_castpilot_show.py` | Alles zusammen → `.castpilot`. |

Nie das `.npr` direkt lesen — die Datei ist 20–30 MB groß.

## Wenn die Generic-Remote-XML nicht erkannt wird

Steinberg hat das XML-Layout mehrfach geändert. Der Parser ist tolerant, aber nicht
allwissend:

```bash
python3 scripts/read_generic_remote.py "midi list nuendo.xml" --dump
```

zeigt die tatsächlichen Tags und `name=`-Felder. Passende Schreibweisen in
`FIELD_ALIASES` ergänzen — das ist ein Einzeiler pro Feld.

Zählt das XML MIDI-Kanäle ab 1 statt ab 0, `--channel-base 1` setzen. Gegenprobe: ein
bekannter Track muss in CastPilot denselben Kanal zeigen wie in Nuendo.

Ohne XML läuft alles andere weiter; die Kommandos bleiben leer und stehen im Report.

## Hintergrund

- `references/npr-format.md` — das Binärformat, auch als Vorlage für einen späteren
  Swift-Port in die App.
- `references/naming-rules.md` — wie `Safety`, `& Ballett`, `Ballett & Cut` und
  Datums-Suffixe gedeutet werden, und warum die Deutung zu `fireMidi()` passt.
