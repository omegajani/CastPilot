# DiGiCo-Bridge

Tells CastPilot which DiGiCo Theatre **player** is loaded on each console channel, so the live window can show a tick per role in the **Pult** column. The bridge only ever **reads**. It never writes to the DiGiCo software or the console, and it never clicks anything.

```
Mac B (remote Mac)                                   Nuendo Mac
DiGiCo SD7Q (Wine) as remote ── SD7                  CastPilot
digico_live.py ── reads SD7Q memory ── HTTP/JSON ──► Settings → DiGiCo → bridge address
```

## Two sources

| Script | Source | When |
|---|---|---|
| `digico_live.py` | the memory of the running `SD7Q.exe` | normal operation, live, no saving |
| `read_ses_players.py` | a saved `.ses` file | tests, offline checks, fallback |

Both answer `GET /players` with the same JSON:

```json
{"source": "memory", "read_at": "2026-10-23T22:26:15+02:00", "session": "show.ses", "software": "22.0.2242",
 "channels": [{"ch": 1, "name": "Aurora TS", "players": ["Mira Lang", "Sofia Brandt"], "loaded": "Mira Lang"}]}
```

On an error (SD7Q not running, structure not found) the live bridge answers HTTP 503, and CastPilot shows "?" instead of a tick — never a wrong green.

## Setup on the remote Mac

Requirements: the DiGiCo offline software runs under Wine (CrossOver engine) in the prefix `~/Wine/digico`, and Rosetta is installed.

1. Download the official **Python 3.12.10 Windows embeddable package (64-bit)** from python.org (`python-3.12.10-embed-amd64.zip`, MD5 `fe8ef205f2e9c3ba44d0cf9954e1abd3`) and unpack it to `~/Wine/digico/drive_c/digico-live/python`.
2. Copy `digico_live.py`, `memlib.py` and `mem_ab.py` to `~/Wine/digico/drive_c/digico-live/`.
3. Start the bridge in the same prefix as SD7Q. `pythonw.exe` and stdin from `/dev/null` are required, because Wine has no console in the background:

```bash
. ~/Wine/digico-env.sh
"$WINE_BIN/wine" 'C:\digico-live\python\pythonw.exe' 'C:\digico-live\digico_live.py' --host 0.0.0.0 --port 8799 < /dev/null > /dev/null 2>&1 &
```

`--host 0.0.0.0` makes it reachable from the Nuendo Mac. For a test on one Mac, leave the default `127.0.0.1`.

4. In CastPilot on the Nuendo Mac: Settings → DiGiCo → switch on, enter `<remote-mac-ip>:8799`.

One-off check without a server: `wine … python.exe C:\digico-live\digico_live.py --once`.

Load: the first search reads ~860 MB of SD7Q memory once (~3 s). After that the bridge re-reads only the player table and one pointer per channel every 1.5 s (a few KB). Measured: 0–0.1 % CPU, ~110 MB RAM, no measurable effect on SD7Q.

## How it reads

`memlib.py` opens `SD7Q.exe` with `PROCESS_VM_READ | PROCESS_QUERY_INFORMATION` only and uses `ReadProcessMemory`. Wine passes this through its own server, so no admin rights are needed. There is no write access in the code.

## Layouts (SD7Q build 22.0.2242, found by A/B tests)

**Session file (`.ses`, versions vM and vO):**
- Player records, 42-byte grid near the end of the file: `r+0` = `0x2A`, `r+2` list ID, `r+3` = `0x01`, `r+4` index in the list, `r+6` set bitmask (u32 LE), `r+10` name length, `r+11` name (latin1).
- Channel record: `o` = name field, `o-1` name length, `o-3` channel number (u16), `o+32` channel width (1 mono, 2 stereo). Record length 92 bytes (vM) or 125 bytes (vO).
- **`o+55` = loaded player** as a u16, the 1-based number of the player record (0 = none). A channel's player list = all records with the same list ID.
- The macOS editor always saves as vO.

**Memory of SD7Q.exe:**
- Player table: the same records, but in a **48-byte** grid.
- Channel record: the same layout, **528 bytes** per channel. `o+33..o+36` are `00` instead of `FF`, `o+37` = `30 01`.
- **`o+55` = u32 pointer to the loaded player record.** Player number = (pointer − table start) / 48 + 1. Exactly one record per channel.

Neither OSC nor the CommandBridge (the layer behind OSC and the iPad app) exposes the loaded player, and nothing is written to disk when a player is loaded.

## After a DiGiCo software update

The bridge reports `software` and adds a `warning` when the build is not in `VERIFIED_BUILDS`. If it no longer finds the structures, find them again with `mem_ab.py` (same method as the first time):

1. `mem_ab.py snap A` with player 1 loaded on a channel, `snap A2` again without changes (noise reference).
2. Load player 5 → `snap B`, then `diff A2 B 1 5`.
3. Load player 3 → `live <candidate file> 3`. The remaining addresses hold the value; the pointer search in `digico_live.py` (`scan`) shows how to turn that into a pattern.

Then add the build to `VERIFIED_BUILDS`.

## Test bridge from a file

```bash
python3 read_ses_players.py show.ses --print
python3 read_ses_players.py "~/Documents/DiGiCo Sessions" --serve 8798 [--loaded test.json]
```

With a folder, it follows the most recently saved `.ses`. `--loaded` overrides load states for UI tests, e.g. `{"1": "Mira Lang", "7": "Mira Lang"}`; the file is re-read on every request.
