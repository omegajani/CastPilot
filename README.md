# MCS — Midi Cast Switcher

A compact macOS utility for live shows that automates Nuendo track version switching based on daily cast assignments.

## What it does

In live shows running with Nuendo, each role (e.g. *NOVA*, *AURORA*, *ECHO*) has multiple performers, each recorded on a separate **Track Version**. Every day the cast changes — MCS sends the exact MIDI sequence needed to select each track and navigate to the correct version in one click.

Instead of manually sending dozens of MIDI commands, you configure once:
- Which MIDI note/CC selects each Nuendo track
- How many versions a track has
- Which slot (1-based position) belongs to which performer

MCS then calculates the full sequence automatically:  
`select track → prev × (versions−1) → next × (position−1)`

## Features

- **Compact live window** — always on top of Nuendo, ~280px wide, one dropdown per role
- **Send to Nuendo** — fires the complete MIDI sequence for all assigned roles in one click
- **Config window** — full role/track/member editor, opens separately via ⚙
- **Email import** — fetches the daily cast email via IMAP, parses role assignments, shows a confirmation view before applying
- **Slot uniqueness** — each performer occupies a unique version slot; stepper swaps on conflict
- **Virtual MIDI source** — appears as *MidiCastSwitcher Source* in Nuendo/Cubase, no hardware needed

## Requirements

- macOS 14.0 or later
- Nuendo or Cubase (any version with Track Versions and MIDI remote)

## Installation

1. Download `MCS.zip` from the [latest release](../../releases/latest)
2. Unzip and move `Midi Cast Switcher.app` to your Applications folder
3. On first launch: right-click → Open (to bypass Gatekeeper on unsigned builds)

### Pre-configured setup (demo show)

The release includes a `config.json` with the full role/track/member configuration for the demo show.

To use it, place the file here:

```
~/Library/Application Support/MidiCastSwitcher/config.json
```

The folder is created automatically on first launch — you can also let the app start once, then replace the file while it's closed.

## MIDI Setup in Nuendo

1. Open **Studio → MIDI Remote** (or Macros/Generic Remote depending on version)
2. Select *MidiCastSwitcher Source* as input device
3. Map the MIDI messages to **Track Version: Select Previous** and **Track Version: Select Next** macros
4. Assign each track's select command to the corresponding **Select Track** action

## Email Import

MCS can fetch the daily cast email directly via IMAP:

1. Click the **✉ envelope icon** in the live window
2. Click ⚙ to enter your IMAP credentials (password is stored in macOS Keychain)
3. Click **E-Mail abrufen** — the app fetches the latest email with *"Cast Information"* in the subject
4. Review the parsed assignments on the right, adjust if needed, click **Besetzung übernehmen**

The role ↔ email mapping is configured per role via the **Keyword** field in Settings (e.g. `AURORA`, `NOVA`, `ECHO`).

## Configuration

| Field | Description |
|---|---|
| Delay (ms) | Pause between consecutive MIDI messages |
| Prev/Next Version Command | Global MIDI command mapped to Nuendo's track version navigation |
| Track → Select Command | MIDI message that selects this specific track in Nuendo |
| Track → Versionen | Total number of track versions (used for the reset step) |
| Darsteller → Slot | 1-based position of this performer in Nuendo's version list |
| Keyword | String to match in the cast email subject/body for this role |

## Built with

SwiftUI · CoreMIDI · Network.framework · macOS 14
