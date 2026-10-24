# Track Versions live aus Nuendo zurücklesen

> Übergabe für die Session auf dem Mac des Entwicklers. Stand: Oktober 2026.
> **Nichts hiervon ist getestet.** Alles unten ist Recherche und Entwurf; was
> Nuendo tatsächlich kann, zeigt erst Schritt 1.

## Ziel

Ein kleiner Dienst, der **live** meldet, welche Track Version auf welcher Spur aktiv
ist, damit CastPilot nach dem Umschalten weiß, ob es geklappt hat.

Rahmenbedingungen, nicht verhandelbar:

- **Nur MIDI.** Nuendo kann kein OSC, und aktiviertes Ethernet lässt Nuendo im
  Betrieb stocken.
- **Nichts speichern.** Das Projekt wird nicht gesichert, keine Auto-Save-Tricks.
- **Nuendo darf nicht stocken.** Was in Nuendo läuft, muss sparsam sein.
- Nuendo 14 oder neuer.

## Ausgangslage

CastPilot schaltet heute **blind**. `fireMidi()` in `CastPilot/MidiController.swift`
schickt pro Spur:

```
Select × 2, Previous Version × (Versionen − 1), Select, Next Version × (Ziel-Slot − 1)
```

Bei einer echten Show mit sechs Rollen waren das rund **200 Nachrichten in etwa
20 Sekunden**, bei der größten Einzelspur 17. Jede muss ankommen, in der richtigen
Reihenfolge. Fällt eine Blätter-Nachricht aus, steht die Spur auf der falschen
Version — und niemand merkt es.

Fällt ein *Select* aus, ist es schlimmer: Die Blätter-Befehle treffen dann die Spur,
die in Nuendo gerade ausgewählt ist, und verstellen deren Version.

CastPilot hat **keinen MIDI-Eingang** (`MidiController.swift`, Aufbau in
`setupMIDI()`: nur `MIDISourceCreate` und `MIDIOutputPortCreate`). Jeder Rückkanal
braucht also neuen Code in der App.

Bekanntes aus der Generic-Remote-Definition des Hauses:

- Spurauswahl läuft über `Mixer / <Kanal> / selected`, Blättern über die Kategorie
  `TrackVersions` mit den Aktionen `Previous Version` und `Next Version`.
- Die Control-Namen können gegenläufig sein (ein Control namens „step up" löst
  *Previous* Version aus). Immer über die Aktion zuordnen, nie über den Namen.
- Audio- und MIDI-Spur einer Rolle dürfen in Nuendo **gleich heißen** und haben
  dieselbe Versionsliste. Nur die Spurart unterscheidet sie.

## Ansatz A — MIDI-Remote-Skript mit DirectAccess (zuerst prüfen)

Nuendos MIDI-Remote-API ist JavaScript, das **in Nuendo** läuft und über MIDI-Ports
redet — passt also zu „nur MIDI".

- Seit API 1.2 gibt es **DirectAccess**, seit 1.3 **Introspektion**: Ein Skript kann
  Nuendos internen Objektbaum durchlaufen und Titel, Typnamen und Werte lesen.
- **Offene Frage, an der alles hängt:** Taucht die aktive Track Version in diesem
  Baum auf? Keine Quelle bestätigt es, keine schließt es aus.
- Hinweis aus zweiter Hand, unbestätigt: DirectAccess-Ereignisse feuern angeblich
  nicht, wenn sich etwas über Nuendos eigene Oberfläche ändert. Dann müsste das
  Skript regelmäßig nachsehen statt auf Ereignisse zu warten.

**Maßgebliche Quelle liegt auf dem Mac:** Nuendo bringt die Typdefinition der API
selbst mit (`midiremote_api_v1.d.ts`, im MIDI-Remote-Ordner unter
`~/Documents/Steinberg/Nuendo/MIDI Remote/` — genauen Pfad vor Ort suchen).
**Diese Datei zuerst lesen.** Nicht aus dem Gedächtnis programmieren und nicht der
Recherche unten mehr glauben als ihr.

### Schritt 1 — Erkundungsskript

Ziel: herausfinden, ob die Track Version lesbar ist. Noch kein Dienst, nur Ausgabe.

1. **IAC-Bus anlegen:** Audio-MIDI-Setup → MIDI-Studio → IAC-Treiber → „Gerät ist
   online", Bus `CastPilot Probe`. Ein MIDI-Remote-Skript braucht einen Port.
2. **Minimales Skript** im lokalen Skriptordner, an diesen Bus gebunden.
3. Beim Aktivieren: DirectAccess auf die **ausgewählte Spur**, den Objektbaum
   rekursiv ablaufen, alles in die **Script Console** schreiben — Titel, Typname,
   Werte, Kinder.
4. **Test:** Eine Spur mit drei Versionen anlegen, eindeutig benannt (`Probe A`,
   `Probe B`, `Probe C`). Spur wählen, Ausgabe sichern. Version wechseln, erneut.
   Unterscheidet sich die Ausgabe? Steht `Probe B` irgendwo?
5. **Ergebnis hier in dieser Datei festhalten** — auch ein Nein.

### Schritt 2 — falls ja: der Dienst

- Das Skript fragt zyklisch die aktive Version der relevanten Spuren ab — **sparsam
  takten**, sonst stockt Nuendo genau wie mit Ethernet.
- Bei einer Änderung schickt es eine MIDI-Nachricht auf einen IAC-Bus. Vorschlag:
  SysEx mit der freien Hersteller-ID `7D`, darin Spurnummer und Versionsindex.
- Offen: wie das Skript eine Spur so benennt, dass CastPilot sie wiedererkennt
  (Spurname? Position?). Gleichnamige Audio-/MIDI-Spuren beachten.
- CastPilot bekommt einen MIDI-Eingang (neue Datei, z. B.
  `CastPilot/MidiFeedback.swift`) und zeigt je Spur: erwartet / bestätigt /
  abweichend.

## Ansatz B — MIDI-Zeugenspur (falls A nicht geht)

Funktioniert ohne DirectAccess, braucht aber eine Vorbereitung im Projekt:

1. Jede Rolle hat eine MIDI-Spur mit denselben Versionen wie die Audiospur. In
   **jede** dieser Versionen an den Anfang einen Program Change, Wert = Slot-Nummer.
2. Ausgang dieser MIDI-Spur auf einen IAC-Bus, den CastPilot mithört.
3. Einstellungen → MIDI → **Chase Events** für Program Change einschalten.
4. Nach dem Umschalten einen Locate auslösen (Generic Remote). Nuendo schickt den
   Program Change der **aktiven** Version.

Offen: ob Chase schon beim reinen Locate auslöst oder erst beim Abspielen. Falls
Letzteres, reicht eine halbe Sekunde Transport an einer stillen Prüfposition.

## Unabhängig davon lohnend — weniger blinde Schritte

Nuendo-Macros `Version 1` … `Version 8`, jeweils
`Previous Version × (größte Versionszahl + 2)`, dann `Next Version × (K − 1)`, jedes
auf eine eigene Note gelegt. Aus bis zu 17 Nachrichten pro Spur werden zwei
(Select + Macro).

Wichtiger noch: so ein Macro ist **idempotent** — zweimal „Version 3" ergibt
dasselbe wie einmal. CastPilot kann es gefahrlos mehrfach senden.

**Vorher von Hand testen:** Bleibt `Previous Version` bei Version 1 stehen, oder
springt es auf die letzte? Nur wenn es stehen bleibt, ist das Übersteuern sicher.
Bei der Gelegenheit nachsehen, ob die Kategorie Track Versions im Generic Remote
nummerierte Aktionen anbietet („Version 1 aktivieren" o. ä.) — dann braucht es gar
keine Macros.

## Quellen der Recherche

Von der Cloud-Session aus konnten die Steinberg-Seiten nicht geöffnet werden; das
Folgende stammt aus Suchergebnissen und ist entsprechend vorsichtig zu lesen.

- [MIDI Remote API 1.3 + Updated Docs](https://forums.steinberg.net/t/midi-remote-api-1-3-updated-docs/1028346) —
  DirectAccess seit 1.2, Introspektion und Typnamen seit 1.3
- [MIDI Remote Direct Access and Process Value](https://forums.steinberg.net/t/midi-remote-direct-access-and-process-value/1006676) —
  Beispiel für das Durchlaufen des Objektbaums
- [Vergleich Generic Remote / Direct Access / Key Commands](https://dredyson.com/i-tested-every-solution-for-getting-punch-in-out-and-pre-post-roll-state-with-midi-remote-api-heres-what-actually-works-complete-comparison-of-generic-remote-vs-direct-access-vs-key-commands-in/) —
  Hinweis, dass Ereignisse bei Änderungen über die Oberfläche ausbleiben können
- [Track Versions aktivieren (Steinberg-Hilfe)](https://www.steinberg.help/r/cubase-pro/15.0/en/cubase_nuendo/topics/track_handling/trackhandling_activating_trackversions_t.html)
