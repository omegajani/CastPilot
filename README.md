# MCS — Midi Cast Switcher

**Stable release · v1.6** · A compact macOS utility for live shows that automates Nuendo track version switching based on daily cast assignments.

> Looking for ballet-cover / track-variant support? See the experimental [`feature/covers`](https://github.com/omegajani/Midi-Cast-Switcher/tree/feature/covers) branch. This `main` branch is the production-ready version without those features.

---

## What it does

In live shows running with Nuendo, each role (e.g. *NOVA*, *AURORA*, *ECHO*) has multiple performers, each recorded on a separate **Track Version**. Every day the cast changes — MCS sends the exact MIDI sequence needed to select each track and navigate to the correct version in one click.

You configure once:
- Which MIDI note/CC selects each Nuendo track
- How many versions a track has
- Which slot (1-based position) belongs to which performer

MCS then calculates the full sequence automatically: `select track → prev × (versions−1) → next × (position−1)`.

## Features

- **Compact always-on-top live window** — ~280 px wide, one dropdown per role, big "Send to Nuendo" button
- **Slot-centric per-track configuration** — drag the +/- buttons to add/remove version slots, pick a member per slot from a dropdown
- **Email import** — fetches the daily cast email via IMAP (GMX, etc.), parses assignments by keyword, lets you confirm before applying
- **Auto-scroll email** — preview pane jumps to *"Last updated"* line so today's cast is instantly visible
- **In-app update check** — Settings → Update → "Auf Update prüfen" → "Befehl kopieren" → paste into Terminal
- **MIDI output selection** — virtual source, USB MIDI interface, or Apple Network MIDI session (auto-refreshes when devices connect/disconnect)
- **Universal binary** — Apple Silicon + Intel, macOS 14+

## Requirements

- macOS 14.0 or later
- Nuendo or Cubase (any version with Track Versions and MIDI Remote)

## Install (Terminal)

One-line installer. Downloads the latest release, installs the app to `/Applications`, removes the Gatekeeper quarantine flag, and places the example `config.json` **only if no config exists yet**:

```bash
curl -sL "$(curl -sL https://api.github.com/repos/omegajani/Midi-Cast-Switcher/releases/latest | grep browser_download_url | cut -d '"' -f 4)" -o /tmp/MCS.zip && \
unzip -qo /tmp/MCS.zip -d /tmp/MCS && \
rm -rf "/Applications/Midi Cast Switcher.app" && \
mv "/tmp/MCS/Midi Cast Switcher.app" /Applications/ && \
xattr -cr "/Applications/Midi Cast Switcher.app" && \
mkdir -p "$HOME/Library/Containers/com.janoslinde.Midi-Cast-Switcher/Data/Library/Application Support/MidiCastSwitcher" && \
CFG="$HOME/Library/Containers/com.janoslinde.Midi-Cast-Switcher/Data/Library/Application Support/MidiCastSwitcher/config.json" && \
[ -f "$CFG" ] || cp /tmp/MCS/config.json "$CFG" && \
rm -rf /tmp/MCS /tmp/MCS.zip && \
open "/Applications/Midi Cast Switcher.app"
```

## Update (Terminal)

Replaces the installed app with the latest release. **Your `config.json` is left untouched**:

```bash
curl -sL "$(curl -sL https://api.github.com/repos/omegajani/Midi-Cast-Switcher/releases/latest | grep browser_download_url | cut -d '"' -f 4)" -o /tmp/MCS.zip && \
unzip -qo /tmp/MCS.zip -d /tmp/MCS && \
rm -rf "/Applications/Midi Cast Switcher.app" && \
mv "/tmp/MCS/Midi Cast Switcher.app" /Applications/ && \
xattr -cr "/Applications/Midi Cast Switcher.app" && \
rm -rf /tmp/MCS /tmp/MCS.zip && \
open "/Applications/Midi Cast Switcher.app"
```

Or from inside the app: **Einstellungen → Update → Auf Update prüfen → Befehl kopieren**.

## Manual install

1. Download `MCS-v*.zip` from the [latest release](../../releases/latest)
2. Unzip and move `Midi Cast Switcher.app` to `/Applications`
3. On first launch: right-click → Open (to bypass Gatekeeper on unsigned builds)
4. Place `config.json` in:
   ```
   ~/Library/Containers/com.janoslinde.Midi-Cast-Switcher/Data/Library/Application Support/MidiCastSwitcher/config.json
   ```
   The container folder is created automatically when the app first runs.

## Nuendo MIDI setup

1. Open **Studio → MIDI Remote** (or Macros / Generic Remote, depending on Nuendo version)
2. Pick *MidiCastSwitcher Source* as input device (or your USB interface / Network MIDI session, configurable in MCS)
3. Map the global previous/next MIDI commands to **Track Version: Select Previous** and **Track Version: Select Next**
4. Assign each track's per-track MIDI command to the corresponding **Select Track** action

**Important — slot order:** MCS slot N navigates Nuendo to its N-th track version. The slot order inside MCS must match Nuendo's actual track-version order exactly, otherwise the wrong version will be selected.

## Email import

1. **Setup once:** Einstellungen → Email Import → enter IMAP server, port, username, password (password is stored in the macOS Keychain).
2. **Each show:** click the **envelope-open icon** in the live window → fetches the newest mail with *"Cast Information"* in the subject → auto-applies recognised role assignments → opens a verification window showing the original email next to the parsed result.

The role ↔ email mapping is configured per role via the **Keyword** field in Settings (e.g. `AURORA`, `NOVA`, `ECHO`).

## Configuration cheat sheet

| Field | Description |
|---|---|
| Verzögerung (ms) | Pause between consecutive MIDI messages |
| Prev/Next Version Command | Global MIDI command mapped to Nuendo's track-version navigation |
| MIDI Ausgang | Which MIDI destination to send commands to (virtual / USB / network) |
| Track → Auswahl-Befehl | MIDI message that selects this specific track in Nuendo |
| Track → Versionen | Total number of track versions (drives the reset step) |
| Track → Slot N | Which member sits at the N-th Nuendo version |
| Keyword | String to match in the cast email body for this role |

## Built with

SwiftUI · CoreMIDI · Network.framework · macOS 14
