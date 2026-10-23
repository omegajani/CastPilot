"""
digico_live.py — DiGiCo-Bridge, Live-Quelle: liest die geladenen Theatre-Player
direkt aus dem Arbeitsspeicher von SD7Q.exe (Offline-Software oder Remote), nur lesend.
Läuft unter Wine im selben Prefix wie SD7Q:

    wine C:\\digico-live\\python\\python.exe C:\\digico-live\\digico_live.py [--port 8799] [--host 127.0.0.1]

Liefert GET /players im Format der CastPilot-Bridge:
    {"source": "memory", "read_at": ..., "session": ..., "software": ...,
     "channels": [{"ch", "name", "players", "loaded"}]}

Speicher-Layout (gefunden 23.10.2026 per A/B, SD7Q 22.0.2242; Details in
README.md im selben Ordner):
- Player-Tabelle: Records wie in der .ses (r+2 Listen-ID, r+4 Index, r+10 Länge,
  r+11 Name), im Speicher aber im 48-Byte-Raster.
- Kanaleintrag wie in der .ses: o = Namensfeld, o-1 Länge, o-3 Kanalnummer (u16),
  o+32 Kanalbreite 1/2, o+33..o+36 = 0, o+37 "30 01". Bei o+55 steht im Speicher
  ein ZEIGER (u32) auf den geladenen Player-Record (in der Datei die Nummer).
"""
import sys, re, json, struct, time, datetime, threading, argparse, os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
sys.path.insert(0, r"C:\digico-live")
from memlib import find_pid, Process

PSTRIDE = 48
PLAYER_RE = re.compile(rb"(?=\x2a\x00[\x00-\xff]\x01[\x00-\xff]\x00[\x00-\xff]{4}[\x01-\x1f][\x20-\x7e\xa0-\xff])")
CHANNEL_RE = re.compile(rb"[\x01\x02]\x00\x00\x00\x00\x30\x01")   # liegt bei o+32
PTR_OFF = 55
LOG = r"C:\Quantum7\Log.txt"
VERIFIED_BUILDS = {"22.0.2242"}


def printable(b):
    return all(32 <= c < 127 or c >= 0xa0 for c in b)


def software_and_session():
    """Version und zuletzt geladene/gespeicherte Session aus dem Log der Software."""
    version, session = None, None
    try:
        for line in open(LOG, encoding="latin1"):
            if "starting software version" in line:
                version = line.split("starting software version", 1)[1].split()[0]
            elif "loading session" in line or "saving session" in line:
                session = line.rsplit("\\", 1)[-1].strip()
    except OSError:
        pass
    return version, session


class LiveReader:
    def __init__(self):
        self.proc = None
        self.layout = None      # (pbase, n, channels: [(ch, o_addr)])
        self.lock = threading.Lock()
        self.state = {"error": "Noch nicht gelesen"}

    # --- Suche (beim Start und wenn die Struktur nicht mehr passt) ---------------
    def scan(self):
        regions = []
        for base, size in self.proc.regions(writable_only=True):
            data = self.proc.read(base, size)
            if data:
                regions.append((base, data))
        # Player-Tabelle: längster Lauf von Records im 48er-Raster
        best = (0, None)
        for base, data in regions:
            starts = {m.start() for m in PLAYER_RE.finditer(data)}
            for s in starts:
                if s - PSTRIDE in starts:
                    continue
                n = 1
                while s + n * PSTRIDE in starts:
                    n += 1
                if n > best[0]:
                    best = (n, base + s)
        n, pbase = best
        if n < 2:
            raise LookupError("Keine Player-Tabelle im Speicher (Session ohne Player oder anderes Programm-Update)")
        # Kanaleinträge, deren Player-Zeiger in die Tabelle zeigt (oder 0 ist)
        found = {}
        for base, data in regions:
            for m in CHANNEL_RE.finditer(data):
                o = m.start() - 32
                if o < 5 or o + PTR_OFF + 4 > len(data):
                    continue
                ln = data[o - 1]
                if not (0 < ln < 32 and printable(data[o:o + ln]) and data[o - 4] == 0x01):
                    continue
                ptr = struct.unpack_from("<I", data, o + PTR_OFF)[0]
                d = ptr - pbase
                if not (0 <= d < n * PSTRIDE and d % PSTRIDE == 0):
                    continue
                ch = struct.unpack_from("<H", data, o - 3)[0]
                found.setdefault(ch, []).append(base + o)
        # Mehrdeutige Kanäle lieber weglassen als raten
        channels = sorted((ch, addrs[0]) for ch, addrs in found.items() if len(addrs) == 1)
        if not channels:
            raise LookupError("Keine Kanaleinträge mit Playern im Speicher gefunden")
        self.layout = (pbase, n, channels)

    # --- Schnelles Nachlesen ---------------------------------------------------
    def read_once(self):
        if self.proc is None:
            pid = find_pid()
            if not pid:
                raise LookupError("SD7Q.exe läuft nicht")
            self.proc = Process(pid)
            self.layout = None
        if self.layout is None:
            self.scan()
        pbase, n, channels = self.layout
        table = self.proc.read(pbase, n * PSTRIDE)
        if not table or len(table) < n * PSTRIDE:
            raise LookupError("Player-Tabelle nicht mehr lesbar")
        players = []
        for k in range(n):
            r = table[k * PSTRIDE:(k + 1) * PSTRIDE]
            if r[0] != 0x2A or r[3] != 1 or not 0 < r[10] < 32:
                raise LookupError("Player-Tabelle hat sich verschoben")
            players.append({"list": r[2], "index": r[4], "name": r[11:11 + r[10]].decode("latin1")})
        out = []
        for ch, o in channels:
            rec = self.proc.read(o - 5, 5 + PTR_OFF + 4)
            if not rec:
                raise LookupError(f"Kanal {ch} nicht mehr lesbar")
            ln = rec[4]
            if struct.unpack_from("<H", rec, 2)[0] != ch or not 0 < ln < 32:
                raise LookupError(f"Kanaleintrag {ch} hat sich verschoben")
            name = rec[5:5 + ln].decode("latin1")
            ptr = struct.unpack_from("<I", rec, 5 + PTR_OFF)[0]
            d = ptr - pbase
            if not (0 <= d < n * PSTRIDE and d % PSTRIDE == 0):
                raise LookupError(f"Player-Zeiger von Kanal {ch} ungültig")
            loaded = players[d // PSTRIDE]
            group = sorted((p for p in players if p["list"] == loaded["list"]), key=lambda p: p["index"])
            out.append({"ch": ch, "name": name, "players": [p["name"] for p in group], "loaded": loaded["name"]})
        return out

    def poll_forever(self, interval):
        while True:
            try:
                channels = self.read_once()
                version, session = software_and_session()
                state = {"source": "memory",
                         "read_at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
                         "session": session or "?", "software": version or "?", "channels": channels}
                if version and version not in VERIFIED_BUILDS:
                    state["warning"] = f"Software {version} ist nicht geprüft (geprüft: {', '.join(sorted(VERIFIED_BUILDS))})"
            except LookupError as e:
                state = {"error": str(e)}
                self.layout = None          # beim nächsten Mal neu suchen
                if "läuft nicht" in str(e) and self.proc:
                    self.proc.close(); self.proc = None
            except Exception as e:          # Prozess weg o. ä.: neu verbinden
                state = {"error": f"{type(e).__name__}: {e}"}
                if self.proc:
                    self.proc.close()
                self.proc, self.layout = None, None
            with self.lock:
                self.state = state
            time.sleep(interval)


def main():
    # pythonw.exe (Hintergrund, ohne Konsole) hat keine Standardausgabe: ins Log schreiben.
    if sys.stdout is None:
        sys.stdout = sys.stderr = open(r"C:\digico-live\live.log", "a", buffering=1, encoding="utf-8")
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8799)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--interval", type=float, default=1.5)
    ap.add_argument("--once", action="store_true", help="einmal lesen, JSON ausgeben, beenden")
    a = ap.parse_args()

    reader = LiveReader()
    if a.once:
        t0 = time.time()
        channels = reader.read_once()
        print(json.dumps({"channels": channels[:12]}, ensure_ascii=False, indent=1))
        print(f"{len(channels)} Kanäle, erste Suche {time.time() - t0:.1f} s", file=sys.stderr)
        t0 = time.time(); reader.read_once()
        print(f"Nachlesen: {(time.time() - t0) * 1000:.0f} ms", file=sys.stderr)
        return

    threading.Thread(target=reader.poll_forever, args=(a.interval,), daemon=True).start()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path.split("?")[0] != "/players":
                self.send_error(404)
                return
            with reader.lock:
                state = reader.state
            if "error" in state:
                self.send_error(503, state["error"])
                return
            body = json.dumps(state, ensure_ascii=False).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, fmt, *args):
            pass

    print(f"DiGiCo-Live-Bridge: http://{a.host}:{a.port}/players (liest SD7Q.exe, nur lesend)", flush=True)
    ThreadingHTTPServer((a.host, a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
