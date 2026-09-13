#!/usr/bin/env python3
"""
read_track_versions.py -- Track Versions aus einem Steinberg Nuendo/Cubase Projekt (.npr)

Liest pro Track die Track-Version-Liste IN ORIGINALREIHENFOLGE aus, ohne die
20-30 MB grosse Binaerdatei in einen LLM-Kontext zu laden.

Nuendo nennt Track Versions intern "MTrackVariation"; sie haengen in einer
"MTrackVariationCollection" am jeweiligen Track-Event. Die Listenposition ist
exakt die Slot-Nummer, die Nuendo im Track-Version-Menue anzeigt -- und damit
die Nummer, auf die CastPilot per MIDI schaltet.

Format siehe ../references/npr-format.md

Aufruf:
    python3 read_track_versions.py <datei.npr> [--json out.json] [--csv out.csv]
                                   [--print] [--all] [--selftest]
"""
import sys
import os
import re
import json
import struct
import argparse

BOM = b"\x00\xef\xbb\xbf"          # NUL + UTF8-BOM: Terminator jedes String-WERTS
NEW_CLASS = 0xFFFFFFFF             # Inline-Klassendefinition
BASE_CLASS = 0xFFFFFFFE            # Basisklasse der Vererbungskette
REF_FLAG = 0x80000000              # Referenz auf eine bereits definierte Klasse
DEFAULT_ROOT_BASE = 0xE8           # Offset des GDocument-Roots

# Jede Klasse "M<irgendwas>TrackEvent" ist eine Spur. Ihre payloadSize spannt den
# Byte-Bereich auf, in dem die zugehoerige Version-Collection liegt. Dynamisch
# erkannt statt fest verdrahtet -- so fallen auch Tempo-, Taktart- und
# Marker-Spuren nicht durchs Raster.
TRACK_EVENT_RE = re.compile(r"^M[A-Za-z]*TrackEvent$")
COLLECTION_CLASS = "MTrackVariationCollection"

# Spurarten, die nie zum Cast gehoeren -- global, nicht pro Saenger.
GLOBAL_TRACK_CLASSES = frozenset((
    "MTempoTrackEvent", "MSignatureTrackEvent", "MMarkerTrackEvent",
    "MDeviceTrackEvent", "MAutomationTrackEvent",
))


class NprError(Exception):
    pass


class Npr:
    """Minimal-Parser fuer den Nuendo-Objektbaum -- nur so viel wie noetig."""

    def __init__(self, data):
        if data[:4] != b"RIFF" or data[8:16] != b"NUNDROOT":
            raise NprError("Keine Nuendo-Projektdatei (RIFF/NUNDROOT-Header fehlt)")
        self.data = data
        self.n = len(data)
        self.class_defs = self._scan_class_defs()
        self.root_base = self._derive_root_base()

    # -- Grundtypen ------------------------------------------------------

    def u32(self, p):
        if p < 0 or p + 4 > self.n:
            return None
        return struct.unpack(">I", self.data[p:p + 4])[0]

    def read_string(self, p):
        """String-WERT an p: u32 len + UTF-8, terminiert auf 00 EF BB BF."""
        ln = self.u32(p)
        if ln is None or not (0 < ln <= 4096) or p + 4 + ln > self.n:
            return None
        raw = self.data[p + 4:p + 4 + ln]
        if not raw.endswith(BOM):
            return None
        return raw[:-4].decode("utf-8", "replace")

    # -- Klassentabelle --------------------------------------------------

    def _scan_class_defs(self):
        """Offset -> Klassenname fuer jede Inline-Klassendefinition."""
        defs = {}
        for m in re.finditer(rb"\xff\xff\xff[\xfe\xff]", self.data):
            off = m.start()
            ln = self.u32(off + 4)
            if ln is None or not (3 < ln <= 64) or off + 8 + ln > self.n:
                continue
            raw = self.data[off + 8:off + 8 + ln]
            if not raw.endswith(b"\x00"):
                continue
            name = raw[:-1]
            if re.fullmatch(rb"[A-Za-z][A-Za-z0-9_]*", name):
                defs[off] = name.decode("ascii")
        return defs

    def _derive_root_base(self):
        """Klassenreferenzen sind relativ zum Dokument-Root (GDocument)."""
        for off, name in sorted(self.class_defs.items()):
            if name == "GDocument":
                return off
        return DEFAULT_ROOT_BASE

    def first_def_offset(self, class_name):
        for off, name in sorted(self.class_defs.items()):
            if name == class_name:
                return off
        return None

    def instances(self, class_name):
        """Alle Objekt-Startoffsets dieser Klasse: Inline-Definition + Referenzen."""
        def_off = self.first_def_offset(class_name)
        if def_off is None:
            return []
        ref = struct.pack(">I", REF_FLAG | (def_off - self.root_base))
        offs = [m.start() for m in re.finditer(re.escape(ref), self.data)]
        offs.append(def_off)          # die Definition ist zugleich die 1. Instanz
        return sorted(set(offs))

    # -- Objekt-Header ---------------------------------------------------

    def header(self, p):
        """-> (payload_start, payload_size). Flag-Bytes gibt es NUR inline."""
        r = self.u32(p)
        if r is None:
            raise NprError("Objekt-Header ausserhalb der Datei")
        if r in (NEW_CLASS, BASE_CLASS):
            ln = self.u32(p + 4)
            if ln is None:
                raise NprError("Defekte Inline-Klassendefinition")
            p = p + 8 + ln + 2        # + 2 Flag-Bytes
        else:
            p = p + 4
        size = self.u32(p)
        if size is None:
            raise NprError("Objekt-Groesse ausserhalb der Datei")
        return p + 4, size

    # -- Fachlogik -------------------------------------------------------

    def track_event_classes(self):
        return sorted({n for n in self.class_defs.values() if TRACK_EVENT_RE.match(n)})

    def track_spans(self):
        """[(start, end, klasse)] aller Track-Events, nach Offset sortiert."""
        spans = []
        for cls in self.track_event_classes():
            for off in self.instances(cls):
                try:
                    payload, size = self.header(off)
                except NprError:
                    continue
                if 0 < size <= self.n:
                    spans.append((off, payload + size, cls))
        spans.sort()
        return spans

    @staticmethod
    def innermost(spans, pos):
        """Index des kleinsten Spans, der pos enthaelt -- Spuren koennen schachteln."""
        best, best_len = None, None
        for i, (start, end, _cls) in enumerate(spans):
            if start < pos < end:
                length = end - start
                if best_len is None or length < best_len:
                    best, best_len = i, length
        return best

    def track_name(self, payload_start, end, window=8192):
        """Der erste String-WERT im Track-Event ist der Trackname."""
        stop = min(end, payload_start + window)
        for p in range(payload_start, stop):
            s = self.read_string(p)
            if s is not None and s.strip():
                return s
        return None

    def version_names(self, coll_off):
        """Namen der MTrackVariation-Kinder einer Collection, in Reihenfolge."""
        p, _size = self.header(coll_off)
        p += 6                        # Tag (4) + Typ (2) des Container-Arrays
        count = self.u32(p)
        p += 4
        if count is None or count > 4096:
            raise NprError("Unplausible Versionsanzahl: %r" % (count,))
        names = []
        for _ in range(count):
            q, vsize = self.header(p)
            if vsize is None or q + vsize > self.n:
                raise NprError("MTrackVariation ragt ueber das Dateiende hinaus")
            names.append(self.read_string(q))
            p = q + vsize
        return names


def extract(data):
    """-> (tracks, stats). tracks = Liste in Projektreihenfolge."""
    npr = Npr(data)
    spans = npr.track_spans()
    colls = npr.instances(COLLECTION_CLASS)

    tracks = []
    unparsed = 0
    orphans = 0
    by_span = {}

    for coll in colls:
        i = npr.innermost(spans, coll)
        if i is None:
            orphans += 1
            continue
        try:
            names = npr.version_names(coll)
        except NprError:
            unparsed += 1
            continue
        by_span.setdefault(i, []).append((coll, names))

    for i, (start, end, cls) in enumerate(spans):
        entries = by_span.get(i)
        if not entries:
            continue
        payload, _size = npr.header(start)
        name = npr.track_name(payload, end)
        # Ein Track hat genau eine Version-Collection; bei mehreren gewinnt die erste.
        coll, names = entries[0]
        tracks.append({
            "index": len(tracks),
            "track": name,
            "kind": "global" if cls in GLOBAL_TRACK_CLASSES else (
                "midi" if cls == "MMidiTrackEvent" else "audio"),
            "class": cls,
            "offset": start,
            "version_count": len(names),
            "versions": [{"slot": k + 1, "raw": v} for k, v in enumerate(names)],
        })

    stats = {
        "collections": len(colls),
        "parsed": len(tracks),
        "unparsed": unparsed,
        "orphans": orphans,
        "track_events": len(spans),
        "multi_version": sum(1 for t in tracks if t["version_count"] > 1),
    }
    return tracks, stats


def read(path):
    with open(path, "rb") as fh:
        return extract(fh.read())


# -- Selbsttest ----------------------------------------------------------

# Bekannte Werte aus GS25_260821.npr (Grand Show 2025, Friedrichstadt-Palast).
SELFTEST_EXPECT = {
    "Dream PB": ["Julian", "Markus", "Marc", "Daniel", "Antonio"],
    "Luci PB": ["Denise", "Myrthes", "Floor", "Katalin"],
    "Oxy PB": ["Myrthes", "Floor", "Julia"],
    "Dope PB": ["Markus", "Marc", "Antonio"],
    "Endo PB": ["Floor", "Katalin"],
    "Sero PB": ["Marc", "Antonio"],
}


def selftest(path):
    tracks, stats = read(path)
    problems = []
    if stats["unparsed"]:
        problems.append("%d Collections nicht parsebar" % stats["unparsed"])
    if stats["orphans"]:
        problems.append("%d Collections ohne Track" % stats["orphans"])

    found = {}
    for t in tracks:
        found.setdefault(t["track"], []).append([v["raw"] for v in t["versions"]])

    for track, expect in SELFTEST_EXPECT.items():
        got = found.get(track)
        if not got:
            problems.append("Track %r nicht gefunden" % track)
        elif expect not in got:
            problems.append("Track %r: erwartet %r, gefunden %r" % (track, expect, got))

    print("Collections: %(collections)d | geparst: %(parsed)d | "
          "mehr als 1 Version: %(multi_version)d" % stats)
    if problems:
        for p in problems:
            print("  FEHLER: " + p)
        return 1
    print("  OK -- alle %d erwarteten Tracks stimmen" % len(SELFTEST_EXPECT))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("npr")
    ap.add_argument("--json", help="JSON-Ausgabe (Default: <npr>_versions.json)")
    ap.add_argument("--csv", help="CSV-Ausgabe (Default: <npr>_versions.csv)")
    ap.add_argument("--print", dest="show", action="store_true",
                    help="Tabelle auf stdout")
    ap.add_argument("--all", action="store_true",
                    help="auch Tracks mit nur einer Version ausgeben")
    ap.add_argument("--selftest", action="store_true",
                    help="gegen bekannte Werte aus GS25_260821.npr pruefen")
    a = ap.parse_args()

    if a.selftest:
        return selftest(a.npr)

    tracks, stats = read(a.npr)
    out = tracks if a.all else [t for t in tracks if t["version_count"] > 1]

    base = os.path.splitext(a.npr)[0]
    jp = a.json or base + "_versions.json"
    with open(jp, "w") as fh:
        json.dump({"source": os.path.basename(a.npr), "stats": stats, "tracks": out},
                  fh, ensure_ascii=False, indent=1)

    cp = a.csv or base + "_versions.csv"
    with open(cp, "w") as fh:
        fh.write("track_index;track;slot;version\n")
        for t in out:
            for v in t["versions"]:
                fh.write("%d;%s;%d;%s\n" % (t["index"], t["track"], v["slot"], v["raw"]))

    print("%d Tracks mit Versionsliste (%d davon mit mehr als einer Version), "
          "%d Collections gesamt, %d nicht parsebar"
          % (stats["parsed"], stats["multi_version"], stats["collections"],
             stats["unparsed"]))
    print("  -> %s\n  -> %s" % (jp, cp))
    if a.show:
        for t in out:
            print("  %-28s %d  %s" % (str(t["track"])[:28], t["version_count"],
                                      ", ".join(str(v["raw"]) for v in t["versions"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
