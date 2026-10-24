# CastPilot — Hinweise für Claude

## Für wen
Der Entwickler arbeitet allein an CastPilot
und ist Tonmeister, kein Softwareentwickler. Antworte auf Deutsch. Begriffe wie CI,
Pull Request oder Review vermeiden — oder in einem Satz erklären, wenn sie nötig sind.

## Projekt
- macOS-App in SwiftUI mit CoreMIDI, gebaut in Xcode. Der Quellcode liegt in
  `CastPilot/`, nach Thema aufgeteilt (Übersicht im README unter „Development").
  Neue `.swift`-Dateien in `CastPilot/` erkennt Xcode automatisch.
- Alles MIDI-Seitige steckt in `CastPilot/MidiController.swift`. CastPilot kann
  heute nur **senden** — einen MIDI-Eingang gibt es nicht.
- Bauen und Ausprobieren geht nur auf dem Mac des Entwicklers. Eine Cloud-Session kann nichts
  kompilieren und Nuendo nicht sehen — das offen sagen, statt Ergebnisse zu raten.

## Arbeitsweise
- `main` ist die App. Neue Arbeit auf einem kurzlebigen Branch, danach nach `main`
  mergen und den Branch löschen (siehe README). Keine Pull Requests — es gibt
  niemanden außer dem Entwickler, der sie prüfen würde.

## Öffentliches Repo — keine Show-Daten
Dieses Repo ist öffentlich. Nie committen: echte Sänger- oder Rollennamen,
Nuendo-Projekte (`.npr`), Generic-Remote-Zuordnungen des Hauses, Show-Files
(`.castpilot`) oder Besetzungslisten. All das gehört ins private Repo
`CastPilot-Shows` — dort liegt auch der Skill `npr-cast-sync`. Beispiele in Code
und Doku immer mit erfundenen Namen.

## Laufendes Vorhaben
Track Versions live aus Nuendo zurücklesen: `docs/track-version-readback.md`
