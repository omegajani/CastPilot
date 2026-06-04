# CastPilot · `feature/covers` branch

> ⚠️ **Experimental branch.** This is the development version with ballet-cover and track-variant support. For the stable release without these features, switch to the [`main`](https://github.com/omegajani/Midi-Cast-Switcher/tree/main) branch.

> **Rebrand:** formerly *Midi Cast Switcher (MCS)*. Since **v2.0** the app is named **CastPilot** (`CastPilot.app`). The bundle ID, GitHub repo and the Nuendo MIDI input name (*MidiCastSwitcher Source*) are unchanged, so existing configs and Nuendo setups keep working.

A compact macOS utility for live shows that automates Nuendo track version switching based on daily cast assignments — including ballet covers borrowing playback from absent principals.

## What it does

In live shows running with Nuendo, each role (e.g. *NOVA*, *AURORA*, *ECHO*) has multiple performers, each recorded on a separate **Track Version**. Every day the cast changes — MCS sends the exact MIDI sequence needed to select each track and navigate to the correct version in one click.

Beyond the basic principal-per-slot mapping, this branch adds two related concepts:

### Cover (ballet doubles)

Ballet performers who don't sing themselves but borrow a principal's playback. Two modes:
- **Fixed** — e.g. *Clara covert Aurora* always uses Mira's playback.
- **Dynamic** — e.g. *Max covert Luna*; MCS automatically picks the Luna-principal who is **not** live in the show today and uses that playback.

### Ballett-Variant tracks

Many Nuendo tracks ship two flavours of each principal — a plain version and a *"& Ballett"* variant. Linking a variant member to its principal lets MCS automatically pick the right version per track:

- **Principal live** → prefer the principal's own slot, fall back to the variant slot if the track doesn't have a plain version.
- **Cover active** → prefer the variant slot ("& Ballett"), fall back to the principal slot if no variant exists.

No global "ballet today" toggle needed — the rules above resolve correctly from the slot assignments alone.

## Live window

```
MCS                ✉ ✉⚙ ⚙
─────────────────────────
Aurora    [Mira            ▾]
Nova   [Paul              ▾]
Echo     [Nina Roth (C)     ▾]
        ↳ via Lena & Ballett
Luna    [—                 ▾]
Orion    [Lena             ▾]
Iris    [Paul              ▾]
─────────────────────────
       [ ⌁ Send to Nuendo ]
```

- Covers appear under a divider with `(C)` suffix and a sub-label showing the resolved playback source.
- Ballett-variant members are hidden from the picker; only "real" principals + covers are selectable.

## Features

- **Compact live window** — always on top of Nuendo, ~280px wide
- **Send to Nuendo** — fires the complete MIDI sequence for all assigned roles in one click
- **Resizable config window** — fixed left + tracks columns, flexible members column
- **Email import** — fetches the daily cast email via IMAP, parses role assignments, shows a confirmation view; unmatched roles flagged in red
- **Auto-resolved covers** — cross-role name matching (Sofia-in-Aurora counts as Sofia-live in Echo even though the UUIDs differ)
- **Per-track slot assignment** — drag-and-drop-style dropdowns; the Versionen +/- buttons add or remove slot rows
- **Virtual MIDI source** — appears as *MidiCastSwitcher Source* in Nuendo/Cubase
- **Hardware MIDI output** — choose a USB interface or Apple Network MIDI session as alternative output
- **In-app update check** — Settings → Update → Auf Update prüfen
- **Debug trace** — fireMidi prints the resolved per-track logic and complete MIDI byte schedule to the Xcode console

## Requirements

- macOS 14.0 or later
- Nuendo or Cubase (any version with Track Versions and MIDI remote)

## Install (Terminal — only needed once)

From **v1.9** onward MCS updates itself in-app (Einstellungen → Update → *Jetzt aktualisieren*). You only need the Terminal command for the **first** install (or when migrating from a sandboxed build ≤ 1.8 — a sandboxed app can't replace itself).

Downloads the latest release of **this branch**, removes any old `Midi Cast Switcher.app`, installs `CastPilot.app` and copies the example `config.json` only if none exists yet:

```bash
curl -sL "$(curl -sL https://api.github.com/repos/omegajani/Midi-Cast-Switcher/releases/tags/v2.0 | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['assets'][0]['browser_download_url'])")" -o /tmp/MCS.zip && \
unzip -qo /tmp/MCS.zip -d /tmp/MCS && \
rm -rf "/Applications/Midi Cast Switcher.app" "/Applications/CastPilot.app" && \
mv "/tmp/MCS/CastPilot.app" /Applications/ && \
xattr -cr "/Applications/CastPilot.app" && \
mkdir -p "$HOME/Library/Application Support/MidiCastSwitcher" && \
CFG="$HOME/Library/Application Support/MidiCastSwitcher/config.json" && \
[ -f "$CFG" ] || cp /tmp/MCS/config.json "$CFG" && \
rm -rf /tmp/MCS /tmp/MCS.zip && \
open "/Applications/CastPilot.app"
```

> **Note:** This branch is marked as pre-release on GitHub, so `releases/latest` always resolves to the stable v1.6 on `main`. The script above uses the explicit tag `v2.0` to target this branch correctly.

> **Config location:** Since v1.9 the sandbox is off, so config lives at `~/Library/Application Support/MidiCastSwitcher/config.json`. Upgrading from an older sandboxed build automatically migrates the config out of the old container on first launch.

## Building from source

```bash
git clone -b feature/covers git@github.com:omegajani/Midi-Cast-Switcher.git
cd Midi-Cast-Switcher
open "Midi Cast Switcher.xcodeproj"
# Cmd+R in Xcode
```

## Configuring covers

### Add a cover

Settings → pick a role → under **Cover** click **+ Cover**:
- Name (e.g. *Nina Roth*)
- Playback dropdown:
  - **Auto (dynamisch)** — MCS picks the absent principal at fire time
  - or any specific principal — fixed mapping

### Mark a member as ballet-variant

Settings → pick a role → in the Darsteller list, on any member row click the small grey **"als Ballett-Variante markieren"** link → pick the parent principal. The member becomes italic with a `↪ Variante von X` sub-label and disappears from the live picker.

### Naming convention (not enforced)

Variants are typically named `{Principal} & Ballett` so Nuendo's track version names match — but any name works since the linking is by UUID, not by name.

## MIDI Setup in Nuendo

1. Open **Studio → MIDI Remote** (or Macros/Generic Remote depending on version)
2. Select *MidiCastSwitcher Source* as input device (or your USB interface / Network MIDI session)
3. Map the MIDI messages to **Track Version: Select Previous** and **Track Version: Select Next** macros
4. Assign each track's select command to the corresponding **Select Track** action

**Slot order matters:** MCS slot N maps to Nuendo's N-th track version. Configure them in the exact same order both sides.

## Email Import

MCS can fetch the daily cast email directly via IMAP:

1. **Setup once:** Einstellungen → Email Import → enter server, port, username, password (stored in macOS Keychain).
2. **Each show:** envelope-open icon in the live window → fetches the latest email with *"Cast Information"* in the subject, auto-applies recognised assignments, opens the verification window. Unrecognised roles are shown in red.

The role ↔ email mapping is configured per role via the **Keyword** field (e.g. `AURORA`, `NOVA`, `ECHO`).

## Built with

SwiftUI · CoreMIDI · Network.framework · macOS 14
