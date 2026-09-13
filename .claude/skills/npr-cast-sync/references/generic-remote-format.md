# Nuendo Generic Remote — XML-Format

Das `.npr` enthält **keine** MIDI-Zuordnung. Welches Kommando einen Track anwählt und
welches durch die Track Versions blättert, steht in der Generic-Remote-Definition, die in
Nuendo unter **Studio → MIDI Remote / Generic Remote** importiert wird.

Reverse Engineering gegen die Produktionsdatei des Friedrichstadt-Palasts (22 Controls).
Anonymisierte Nachbauten liegen in `../tests/fixtures/`.

## Aufbau

```xml
<remotedescription version="1.1">
  <ctrltable name="Standard MIDI">
    <ctrl>
      <name>Select Dream PB</name>
      <stat>144</stat>   <!-- MIDI-Status: 144=Note On, 176=CC, 192=PC -->
      <chan>0</chan>     <!-- MIDI-Kanal, ab 0 gezählt -->
      <addr>19</addr>    <!-- Notennummer / CC-Nummer / Programm -->
      <max>127</max>     <!-- Velocity / CC-Wert -->
      <flags>1</flags>
    </ctrl>
  </ctrltable>
  <bank name="VST 1-16">
    <entry ctrl="step up">
      <command><category>TrackVersions</category><action>Previous Version</action></command>
    </entry>
    <entry ctrl="Select Dream PB">
      <value><device>Mixer</device><chan>167</chan><name>selected</name></value>
    </entry>
  </bank>
</remotedescription>
```

`<ctrltable>` definiert **was gesendet wird**, `<bank>` **was es in Nuendo auslöst**.

## Zwei Fallen

### `<chan>` bedeutet zweierlei

Im `<ctrl>` ist es der **MIDI-Kanal** (ab 0). Im `<entry><value>` ist es der
**Mixer-Kanal** des anzuwählenden Tracks — im Beispiel 167, weit jenseits von 16.

Deshalb liest `read_generic_remote.py` nur **direkte Kinder** eines Elements, nie den
ganzen Teilbaum. Ein Teilbaum-Walk vermischt beide Bedeutungen und baut aus Vater-Elementen
Phantom-Controls.

Ebenso trägt `<name>` im `<entry><value>` den Wert `selected` — nicht den Tracknamen.
Der Trackname steckt im Attribut `ctrl=` bzw. im `<name>` des `<ctrl>`.

### Die Blätter-Controls heißen gegenläufig

```
ctrl "step up"   → TrackVersions / Previous Version
ctrl "step down" → TrackVersions / Next Version
```

Deshalb wird immer über `<action>` zugeordnet, nie über den Control-Namen.

## Zuordnung Track → Control

Der Control-Name enthält den Tracknamen, meist mit Präfix (`Select Dream PB`).
`--strip-prefix` entfernt es. Danach müssen die Namen exakt passen — drei Regeln helfen:

1. **Token-Aliase** (`--alias HH=HS`, `--alias Luci=Lucy`). Projekt und XML werden von
   verschiedenen Leuten gepflegt und driften auseinander.
2. **Audio- vs. MIDI-Spur.** Nuendo lässt zu, dass beide `Dream PB` heißen. Die XML
   unterscheidet sie als `Select Dream PB` und `Select Dream MIDI`. Der Skill ersetzt bei
   MIDI-Spuren das letzte Token `PB` durch `MIDI` — die Trackart löst die Dublette auf.
3. **Kein Fuzzy-Matching.** Im Echttest schlug `difflib` für `Endo PB` das Control
   `Select Endo TS` vor. Das hätte den falschen Track angewählt. Stattdessen meldet der
   Report beide Seiten: Tracks ohne Control und Controls ohne Track.

## Terminologie der Suffixe

| Suffix | Bedeutung |
|---|---|
| `TS` | Taschensender (Headset) — heißt in Projekt und XML gleich |
| `HS` (XML) / `HH` (Projekt) | Handsender / Handheld — dasselbe Mikrofon |
| `PB` | Playback (Audiospur) |
| `MIDI` (XML) / `PB` (Projekt, MIDI-Spur) | die MIDI-Spur derselben Rolle |

## Wenn nichts erkannt wird

```bash
python3 read_generic_remote.py <datei.xml> --dump
```

zeigt die tatsächlichen Tags und `name=`-Felder samt Markierung, welche davon als Feld
erkannt wurden. Fehlende Schreibweisen in `FIELD_ALIASES` ergänzen — ein Eintrag pro Feld.
Genau so wurde das echte Format eingebaut: der erste Parser war gegen ein vermutetes
Layout geschrieben und erkannte die echte Datei nicht.

Zählt ein Export MIDI-Kanäle ab 1 statt ab 0, `--channel-base 1` setzen. Gegenprobe: ein
bekannter Track muss in CastPilot denselben Kanal zeigen wie in Nuendo.

## Tracks ohne Control sind gefährlich

`fireMidi()` (MidiCastTrigger.swift:546-583) sendet pro Track erst `selectCommand`, dann
`prevVersionCommand` × (versionCount−1), dann `nextVersionCommand` × (Slot−1).

Ein Track ohne wirksames Select-Kommando bewirkt beim Anwählen nichts — **die
Blätter-Befehle werden aber trotzdem gesendet** und treffen den Track, der in Nuendo gerade
ausgewählt ist. Der verstellt dann seine Version.

Deshalb fliegen solche Tracks aus dem Show-File. `--keep-unmapped` hebt das auf, sollte aber
nur benutzt werden, wenn die Controls gleich danach in Nuendo angelegt werden.
