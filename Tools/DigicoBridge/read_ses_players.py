#!/usr/bin/env python3
"""
read_ses_players.py — DiGiCo Theatre-Player aus einem SD7-Sessionfile (.ses)
Referenz-Reader und Test-Orakel für die DiGiCo-Bridge von CastPilot.

Liefert je Kanal die Liste der Player und (sobald das Format bekannt ist) den
geladenen Player — im selben JSON wie die Bridge (`GET /players`):

    {"source": "file", "read_at": "...", "session": "show.ses",
     "channels": [{"ch": 1, "name": "Aurora TS",
                   "players": ["Mira Lang", ...], "loaded": null}, ...]}

Format (siehe README.md):
- Player-Records im 42-Byte-Raster am Dateiende, relativ zum Record-Start r:
    r+0  0x2A          r+2  Listen-ID (gruppiert die Player eines Kanals)
    r+3  0x01          r+4  Index in der Liste (0-basiert)
    r+6  Set-Bitmaske (u32 LE, Bit 0 = Set 1)
    r+10 Namenslänge   r+11 Name (latin1)
- Kanal → Liste: Byte o+55 im 92er-Kanalrecord (o = Namensfeld) ist der
  1-basierte Zeiger auf den ersten Player-Record des Kanals, 0 = keine Player.
- Welcher Player geladen ist, ist noch NICHT erschlossen → "loaded": null.

Aufruf:
    python3 read_ses_players.py <datei.ses> [--json out.json] [--print]
    python3 read_ses_players.py <datei.ses|ordner> --serve 8790 [--host 127.0.0.1] [--loaded test.json]

--serve startet eine nur lesende Test-Bridge. Bei einem Ordner folgt sie der zuletzt
gespeicherten .ses und liest neu ein, sobald dort gespeichert wird. --loaded zeigt auf eine JSON-Datei
{"1": "Mira Lang", "7": "Mira Lang", ...}; sie wird bei jeder Anfrage neu
gelesen, damit sich Ladezustände beim Testen von CastPilot live umschalten lassen.
"""
import sys, os, re, json, struct, argparse, datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import read_ses  # Kanaltabelle (92er-Raster, Längen-Byte)

PLAYER_STRIDE = 42
PTR_OFF = 55            # Player-Zeiger im Kanalrecord, relativ zum Namensfeld
# r+0 0x2A, r+1 0x00, r+3 0x01, r+5 0x00, r+10 Länge 1..31, danach Name
PLAYER_RE = re.compile(rb"(?=\x2a\x00[\x00-\xff]\x01[\x00-\xff]\x00[\x00-\xff]{4}[\x01-\x1f][\x20-\x7e\xa0-\xff])")


def _player_at(data, r):
    """Liest einen Player-Record oder None, wenn r keiner ist."""
    if r + PLAYER_STRIDE > len(data) or data[r] != 0x2A or data[r + 1] or data[r + 3] != 1:
        return None
    n = data[r + 10]
    if not 0 < n < 32:
        return None
    raw = data[r + 11:r + 11 + n]
    if any(b < 0x20 or 0x7f <= b < 0xa0 for b in raw):
        return None
    return {"list": data[r + 2], "index": data[r + 4],
            "sets": struct.unpack_from("<I", data, r + 6)[0],
            "name": raw.decode("latin1"), "offset": r}


def find_players(data):
    """Längster zusammenhängender Lauf von Player-Records im 42er-Raster."""
    starts = [m.start() for m in PLAYER_RE.finditer(data)]
    valid = {s for s in starts if _player_at(data, s)}
    best = []
    for s in sorted(valid):
        if s - PLAYER_STRIDE in valid:
            continue
        run = [s]
        while run[-1] + PLAYER_STRIDE in valid:
            run.append(run[-1] + PLAYER_STRIDE)
        if len(run) > len(best):
            best = run
    return [_player_at(data, r) for r in best]


# Länge eines Kanalrecords je Formatversion (Buchstabe am Ende des Headers)
CHANNEL_STRIDE = {"M": 92, "O": 125}


def extract(path):
    data = open(path, "rb").read()
    version = data[:24].decode("latin1", "replace").strip()[-1:]
    stride = CHANNEL_STRIDE.get(version)
    if stride is None:
        raise ValueError(f"Unbekannte Sessionversion '{version}' — nur vM und vO sind geprüft")
    header, chans = read_ses.extract(path, stride=stride)
    players = find_players(data)
    lists = {}
    for p in players:
        lists.setdefault(p["list"], []).append(p)
    out = []
    for c in chans:
        # Der geladene Player als 1-basierte Nummer in der Player-Tabelle; 0 = keiner.
        num = struct.unpack_from("<H", data, c["offset"] + PTR_OFF)[0]
        if num == 0 or num > len(players):
            continue
        loaded = players[num - 1]
        group = lists[loaded["list"]]
        out.append({"ch": c["ch"], "name": c["name"],
                    "players": [p["name"] for p in sorted(group, key=lambda p: p["index"])],
                    "loaded": loaded["name"]})
    return header, out, len(players)


def snapshot(path, channels, loaded_override=None):
    chans = [dict(c) for c in channels]
    source = "file"
    if loaded_override:
        source = "file+test"
        for c in chans:
            if str(c["ch"]) in loaded_override:
                c["loaded"] = loaded_override[str(c["ch"])]
    # read_at = when the session was saved: that is the moment the data describes.
    saved = datetime.datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
    return {"source": source,
            "read_at": saved.isoformat(timespec="seconds"),
            "session": os.path.basename(path),
            "channels": chans}


def newest_session(target):
    """Die Datei selbst oder die zuletzt gespeicherte .ses in einem Ordner."""
    if not os.path.isdir(target):
        return target
    files = [os.path.join(target, f) for f in os.listdir(target) if f.lower().endswith(".ses")]
    return max(files, key=os.path.getmtime) if files else None


class SessionCache:
    """Liest neu ein, sobald eine neuere oder geänderte Session da ist."""
    def __init__(self, target):
        self.target, self.key, self.path, self.channels = target, None, None, []

    def get(self):
        path = newest_session(self.target)
        if not path:
            return None, []
        st = os.stat(path)
        key = (path, st.st_mtime, st.st_size)
        if key != self.key:
            try:
                _, channels, n = extract(path)
            except Exception as e:  # z. B. Datei wird gerade noch geschrieben
                print(f"Lesen fehlgeschlagen ({os.path.basename(path)}): {e}", file=sys.stderr)
                return self.path, self.channels
            self.key, self.path, self.channels = key, path, channels
            print(f"Session gelesen: {os.path.basename(path)} — {len(channels)} Kanäle, {n} Player",
                  file=sys.stderr)
        return self.path, self.channels


def serve(target, host, port, loaded_path):
    cache = SessionCache(target)
    cache.get()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0] != "/players":
                self.send_error(404)
                return
            override = None
            if loaded_path and os.path.exists(loaded_path):
                try:
                    override = json.load(open(loaded_path))
                except ValueError as e:
                    self.send_error(500, f"--loaded ungültig: {e}")
                    return
            path, channels = cache.get()
            if not path:
                self.send_error(503, "Keine Session gefunden")
                return
            body = json.dumps(snapshot(path, channels, override), ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            pass

    print(f"Test-Bridge: http://{host}:{port}/players  (folgt {target})", file=sys.stderr)
    ThreadingHTTPServer((host, port), Handler).serve_forever()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("ses")
    ap.add_argument("--json")
    ap.add_argument("--print", action="store_true")
    ap.add_argument("--serve", type=int, metavar="PORT")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--loaded", metavar="TEST.json")
    a = ap.parse_args()

    if a.serve:  # Datei oder Ordner; liest neu ein, sobald dort neu gespeichert wird
        serve(a.ses, a.host, a.serve, a.loaded)
        return

    header, channels, n = extract(a.ses)
    if "SDQ .SES vM" not in header.replace("  ", " ").replace("  ", " "):
        print(f"WARNUNG: Format '{header}' — Reader ist nur gegen 'SDQ .SES vM' geprüft.", file=sys.stderr)
    print(f"{header} | {n} Player-Records, {len(channels)} Kanäle mit Playern", file=sys.stderr)

    if a.json:
        json.dump(snapshot(a.ses, channels), open(a.json, "w"), ensure_ascii=False, indent=1)
    if a.print:
        for c in channels:
            print(f'{c["ch"]:3} {c["name"]:16} ' + " | ".join(c["players"]))


if __name__ == "__main__":
    main()
