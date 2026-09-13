#!/usr/bin/env python3
"""
build_castpilot_show.py -- aus Nuendo-Track-Versionen eine .castpilot-Show bauen

Nimmt die Ausgabe von read_track_versions.py (oder direkt ein .npr), deutet die
Versionsnamen nach den Regeln in ../references/naming-rules.md und schreibt eine
.castpilot-Datei -- das ist exakt ein JSON-kodiertes AppConfig, wie CastPilot es
in "Show exportieren" schreibt.

Vor dem Schreiben gibt es IMMER einen Report. Mit --dry-run bleibt es dabei.

Aufruf:
    python3 build_castpilot_show.py --npr <datei.npr> [-o show.castpilot]
        [--versions versions.json]   statt --npr die fertige Parser-Ausgabe
        [--remote-xml "midi list nuendo.xml"]   MIDI-Select-Kommandos
        [--base config.json]         bestehende UUIDs/Keywords/Cover uebernehmen
        [--show-name NAME]           Default: Dateiname des .npr
        [--dry-run]                  nur Report, nichts schreiben
"""
import os
import re
import sys
import json
import uuid
import argparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# CastPilot-Defaults, 1:1 aus AppConfig in MidiCastTrigger.swift
DEFAULT_DELAY_MS = 100
DEFAULT_INTER_ROLE_DELAY_MS = 100
EMPTY_COMMAND = {"type": "Program Change", "channel": 1, "value1": 0, "value2": 127}
DEFAULT_PREV = {"type": "Control Change", "channel": 1, "value1": 1, "value2": 127}
DEFAULT_NEXT = {"type": "Control Change", "channel": 1, "value1": 2, "value2": 127}

# Marker in Versionsnamen. "ballett" macht aus einem Eintrag die Cover-Variante
# des gleichnamigen Principals (CastMember.coverVariantOf).
MARKERS = ("safety", "ballett", "ballet", "cut")
VARIANT_MARKER = ("ballett", "ballet")

# Versionsnamen, die nie eine Person meinen.
NON_CAST_RE = [
    re.compile(r"^v\d+$", re.I),                 # Nuendos Default: v1, v2, ...
    re.compile(r"^\d{6}$"),                      # reines Datum: 260813
    re.compile(r"^abgenommen\b", re.I),
    re.compile(r"^ganze\s+show\b", re.I),
    re.compile(r"^(kopie|copy|backup|alt|old|neu|new|test)\b", re.I),
]
DATE_RE = re.compile(r"(\d{6})$")
UUID_NS = uuid.UUID("6f1a3b52-0f4e-5c8a-9d31-0a5c6b7d8e90")


# -- Namensregeln --------------------------------------------------------

def normalize(raw):
    """Vereinheitlicht die unsauberen Realdaten aus dem Projekt.

    'Marc Safety ' -> 'Marc Safety',  'Katalin260814' -> 'Katalin 260814'
    """
    s = (raw or "").replace(" ", " ")
    s = re.sub(r"\s+", " ", s).strip()
    s = re.sub(r"([A-Za-zÀ-ɏ])(\d{6})$", r"\1 \2", s)
    return s


def classify(raw):
    """-> dict(raw, norm, base, markers, date, is_cast)."""
    norm = normalize(raw)
    info = {"raw": raw, "norm": norm, "base": "", "markers": [],
            "date": None, "is_cast": False}
    if not norm:
        return info

    rest = norm
    m = DATE_RE.search(rest)
    if m:
        info["date"] = m.group(1)
        rest = rest[:m.start()].strip()

    markers = []
    # Marker-Woerter entfernen; was uebrig bleibt, ist der Personenname.
    for word in MARKERS:
        pattern = re.compile(r"\b" + word + r"\b", re.I)
        if pattern.search(rest):
            markers.append("ballett" if word in VARIANT_MARKER else word.lower())
            rest = pattern.sub(" ", rest)
    rest = re.sub(r"[&/,+]+", " ", rest)
    rest = re.sub(r"\s+", " ", rest).strip(" -_")

    info["markers"] = sorted(set(markers))
    info["base"] = rest

    if any(p.match(norm) for p in NON_CAST_RE):
        return info
    if not rest or rest.isdigit():
        return info
    # Personen sind 1-3 Woerter und enthalten keine Ziffern.
    words = rest.split()
    if len(words) > 3 or any(any(c.isdigit() for c in w) for w in words):
        return info
    info["is_cast"] = True
    return info


def is_variant(info):
    return "ballett" in info["markers"]


# -- Aufbau --------------------------------------------------------------

def det_uuid(*parts):
    """Stabile UUID -- gleicher Input, gleiche UUID. Swift schreibt UPPERCASE."""
    return str(uuid.uuid5(UUID_NS, "castpilot:" + ":".join(parts))).upper()


def role_of(track_name, regex):
    m = re.match(regex, track_name or "")
    return m.group(1) if m else (track_name or "").strip()


def pick_cast_tracks(tracks, min_cast=2):
    """Trennt Cast-Tracks von Technik-Tracks und sammelt Grenzfaelle."""
    cast, dropped, unclear = [], [], []
    for t in tracks:
        infos = [classify(v["raw"]) for v in t["versions"]]
        n_cast = sum(1 for i in infos if i["is_cast"])
        entry = dict(t, infos=infos, n_cast=n_cast)
        if t["version_count"] < 2 or n_cast == 0:
            dropped.append(entry)
        elif n_cast < min_cast or n_cast != t["version_count"]:
            # teils Personen, teils nicht -> nicht raten, vorlegen
            unclear.append(entry)
        else:
            cast.append(entry)
    return cast, dropped, unclear


def build(tracks, show_name, role_regex, midi_map=None, base=None):
    """-> (config, report)"""
    midi_map = midi_map or {}
    cast, dropped, unclear = pick_cast_tracks(tracks)
    report = {"dropped": dropped, "unclear": unclear, "warnings": [],
              "variants": [], "stale_dates": [], "missing_midi": [],
              "duplicate_names": []}

    # Nuendo laesst gleiche Tracknamen zu (hier: je ein Track fuer Kopfhoerer- und
    # Saal-Playback). CastPilot unterscheidet Tracks nur ueber das MIDI-Kommando --
    # gleichnamige Tracks bekommen aus der Generic-Remote-XML dasselbe zugeordnet
    # und wuerden beide denselben Nuendo-Track schalten.
    seen = {}
    for t in cast:
        seen.setdefault(t["track"], []).append(t["index"])
    report["duplicate_names"] = [(name, idxs) for name, idxs in seen.items()
                                 if len(idxs) > 1]

    # 1. Tracks nach Rolle gruppieren
    by_role = {}
    for t in cast:
        by_role.setdefault(role_of(t["track"], role_regex), []).append(t)

    base_index = index_base(base) if base else None
    roles = []

    for role_name in sorted(by_role, key=lambda r: min(t["index"] for t in by_role[r])):
        rtracks = sorted(by_role[role_name], key=lambda t: t["index"])

        # 2. Primaertrack = meiste verschiedene Principals. Er gibt die
        #    Reihenfolge der Darsteller vor (versionPosition).
        def principals_of(t):
            seen = []
            for i in t["infos"]:
                if i["is_cast"] and not is_variant(i) and i["base"] not in seen:
                    seen.append(i["base"])
            return seen

        primary = max(rtracks, key=lambda t: (len(principals_of(t)), -t["index"]))
        order = principals_of(primary)
        for t in rtracks:
            for name in principals_of(t):
                if name not in order:
                    order.append(name)

        # 3. Varianten (Ballett) je Principal -- die App findet genau eine.
        variant_bases = []
        for t in rtracks:
            for i in t["infos"]:
                if i["is_cast"] and is_variant(i) and i["base"] not in variant_bases:
                    variant_bases.append(i["base"])
                    if i["base"] not in order:
                        order.append(i["base"])

        members, member_id = [], {}
        for pos, name in enumerate(order, 1):
            mid = reuse_member(base_index, role_name, name) or \
                det_uuid(show_name, role_name, name)
            member_id[("principal", name)] = mid
            members.append({"id": mid, "name": name,
                            "versionPosition": pos, "coverVariantOf": None})
        for name in variant_bases:
            vname = name + " & Ballett"
            vid = reuse_member(base_index, role_name, vname) or \
                det_uuid(show_name, role_name, vname)
            member_id[("variant", name)] = vid
            members.append({"id": vid, "name": vname,
                            "versionPosition": len(members) + 1,
                            "coverVariantOf": member_id[("principal", name)]})
            report["variants"].append((role_name, vname, name))

        # 4. Slots belegen
        out_tracks = []
        for t in rtracks:
            slots = [None] * t["version_count"]
            # Bei mehreren datierten Fassungen derselben Person gewinnt die juengste.
            newest = {}
            for idx, i in enumerate(t["infos"]):
                if i["is_cast"] and i["date"]:
                    key = (is_variant(i), i["base"])
                    if key not in newest or i["date"] > t["infos"][newest[key]]["date"]:
                        newest[key] = idx

            for idx, i in enumerate(t["infos"]):
                if not i["is_cast"]:
                    continue
                key = (is_variant(i), i["base"])
                if i["date"] and newest.get(key) != idx:
                    report["stale_dates"].append(
                        (t["track"], idx + 1, i["raw"],
                         t["infos"][newest[key]]["raw"]))
                    continue
                mid = member_id.get(("variant" if is_variant(i) else "principal",
                                     i["base"]))
                if mid is None:
                    continue
                if mid in slots:
                    report["warnings"].append(
                        "%s: %r zeigt auf dieselbe Person wie Slot %d -- Slot %d bleibt leer"
                        % (t["track"], i["raw"], slots.index(mid) + 1, idx + 1))
                    continue
                slots[idx] = mid

            duplicated = any(t["track"] == name
                             for name, _ in report["duplicate_names"])
            cmd = None if duplicated else midi_map.get(t["track"])
            cmd = cmd or reuse_track_command(base_index, role_name, t["track"])
            if cmd is None:
                label = "%s (Projektposition %d)" % (t["track"], t["index"]) \
                    if duplicated else t["track"]
                report["missing_midi"].append(label)
                cmd = dict(EMPTY_COMMAND)
            cmd = dict(cmd, id=det_uuid(show_name, role_name, t["track"], "cmd"))

            out_tracks.append({
                "id": reuse_track(base_index, role_name, t["track"]) or
                      det_uuid(show_name, role_name, t["track"], str(t["index"])),
                "name": t["track"],
                "selectCommand": cmd,
                "versionCount": t["version_count"],
                "slotAssignments": slots,
                "slotOverrides": {},
            })

        prev_role = base_index["roles"].get(role_name.lower()) if base_index else None
        roles.append({
            "id": (prev_role or {}).get("id") or det_uuid(show_name, role_name),
            "name": role_name,
            "emailKeyword": (prev_role or {}).get("emailKeyword") or role_name.upper(),
            "tracks": out_tracks,
            "members": members,
            "covers": carry_covers(prev_role, members, report, role_name),
            "selectedMemberId": None,
            "borrowsLinesFromRoleId": None,
        })

    # borrowsLinesFromRoleId nur uebernehmen, wenn beide Rollen noch existieren
    if base_index:
        by_name = {r["name"].lower(): r for r in roles}
        for r in roles:
            prev = base_index["roles"].get(r["name"].lower())
            prev_link = (prev or {}).get("_borrows_name")
            if prev_link and prev_link.lower() in by_name:
                r["borrowsLinesFromRoleId"] = by_name[prev_link.lower()]["id"]
            elif prev_link:
                report["warnings"].append(
                    "Rolle %s: Verknuepfung zu %r ging verloren (Rolle nicht mehr im Projekt)"
                    % (r["name"], prev_link))

    cfg = {
        "delayMs": (base or {}).get("delayMs", DEFAULT_DELAY_MS),
        "interRoleDelayMs": (base or {}).get("interRoleDelayMs",
                                             DEFAULT_INTER_ROLE_DELAY_MS),
        "prevVersionCommand": with_id((base or {}).get("prevVersionCommand", DEFAULT_PREV),
                                      show_name, "prev"),
        "nextVersionCommand": with_id((base or {}).get("nextVersionCommand", DEFAULT_NEXT),
                                      show_name, "next"),
        "roles": roles,
        "emailConfig": (base or {}).get("emailConfig",
                                        {"imapServer": "", "imapPort": 993, "username": ""}),
        "midiOutputName": (base or {}).get("midiOutputName", ""),
        "showName": show_name,
    }
    return cfg, report


def with_id(cmd, show_name, tag):
    cmd = dict(cmd)
    cmd.setdefault("type", "Control Change")
    cmd.setdefault("channel", 1)
    cmd.setdefault("value1", 0)
    cmd.setdefault("value2", 127)
    cmd["id"] = cmd.get("id") or det_uuid(show_name, tag)
    return cmd


# -- Uebernahme aus einer bestehenden Konfiguration -----------------------

def index_base(base):
    """Rollen/Tracks/Member der Altkonfiguration nach Namen indizieren."""
    idx = {"roles": {}, "members": {}, "tracks": {}, "commands": {}}
    id_to_role = {r.get("id"): r.get("name", "") for r in base.get("roles", [])}
    for r in base.get("roles", []):
        name = (r.get("name") or "").lower()
        entry = dict(r)
        entry["_borrows_name"] = id_to_role.get(r.get("borrowsLinesFromRoleId"))
        idx["roles"][name] = entry
        for m in r.get("members", []):
            idx["members"][(name, (m.get("name") or "").strip().lower())] = m.get("id")
        for t in r.get("tracks", []):
            key = (name, (t.get("name") or "").strip().lower())
            idx["tracks"][key] = t.get("id")
            if t.get("selectCommand"):
                idx["commands"][key] = t["selectCommand"]
    return idx


def reuse_member(idx, role, name):
    return idx["members"].get((role.lower(), name.strip().lower())) if idx else None


def reuse_track(idx, role, name):
    return idx["tracks"].get((role.lower(), name.strip().lower())) if idx else None


def reuse_track_command(idx, role, name):
    return idx["commands"].get((role.lower(), name.strip().lower())) if idx else None


def carry_covers(prev_role, members, report, role_name):
    """Cover uebernehmen, solange ihre Quelle noch existiert."""
    if not prev_role:
        return []
    valid = {m["id"] for m in members}
    out = []
    for c in prev_role.get("covers", []):
        src = c.get("fixedSourceMemberId")
        if src and src not in valid:
            report["warnings"].append(
                "Rolle %s: Cover %r verliert seine feste Quelle (Darsteller nicht mehr im Projekt)"
                % (role_name, c.get("name")))
            c = dict(c, fixedSourceMemberId=None)
        out.append(c)
    return out


# -- Report --------------------------------------------------------------

def print_report(cfg, report, base=None):
    print("Show: %s" % cfg["showName"])
    print("%d Rollen, %d Tracks, %d Darsteller\n"
          % (len(cfg["roles"]),
             sum(len(r["tracks"]) for r in cfg["roles"]),
             sum(len(r["members"]) for r in cfg["roles"])))

    base_slots = {}
    if base:
        for r in base.get("roles", []):
            id_name = {m.get("id"): m.get("name") for m in r.get("members", [])}
            for t in r.get("tracks", []):
                base_slots[(r.get("name", "").lower(), t.get("name", "").lower())] = [
                    id_name.get(s) for s in t.get("slotAssignments", [])]

    for r in cfg["roles"]:
        id_name = {m["id"]: m["name"] for m in r["members"]}
        print("ROLLE %s   (E-Mail-Keyword: %s)" % (r["name"], r["emailKeyword"]))
        for m in sorted(r["members"], key=lambda m: m["versionPosition"]):
            kind = "Variante von %s" % id_name.get(m["coverVariantOf"], "?") \
                if m["coverVariantOf"] else "Principal"
            print("   %d. %-24s %s" % (m["versionPosition"], m["name"], kind))
        for t in r["tracks"]:
            old = base_slots.get((r["name"].lower(), t["name"].lower()))
            print("   Track %s  (%d Slots)" % (t["name"], t["versionCount"]))
            for i, sid in enumerate(t["slotAssignments"]):
                new = id_name.get(sid, "-- leer --")
                if old is not None and i < len(old) and (old[i] or "-- leer --") != new:
                    print("      Slot %d: %s  ->  %s   GEAENDERT"
                          % (i + 1, old[i] or "-- leer --", new))
                else:
                    print("      Slot %d: %s" % (i + 1, new))
        print()

    if report["variants"]:
        print("Als Ballett-Variante gedeutet -- bitte gegenlesen:")
        for role, vname, principal in report["variants"]:
            print("   %s: %r wird Variante von %r" % (role, vname, principal))
        print()
    if report["duplicate_names"]:
        print("Gleiche Tracknamen mehrfach im Projekt -- CastPilot kann sie nur ueber "
              "verschiedene MIDI-Kommandos auseinanderhalten:")
        for name, idxs in report["duplicate_names"]:
            print("   %s: %d Tracks (Projektpositionen %s)"
                  % (name, len(idxs), ", ".join(str(i) for i in idxs)))
        print()
    if report["stale_dates"]:
        print("Aeltere datierte Fassungen -- Slot bleibt leer, juengste gewinnt:")
        for track, slot, raw, winner in report["stale_dates"]:
            print("   %s Slot %d: %r  (aktiv: %r)" % (track, slot, raw, winner))
        print()
    if report["missing_midi"]:
        print("MIDI-SELECT-KOMMANDO FEHLT -- in CastPilot nachtragen, sonst schaltet "
              "der Track nicht:")
        for name in report["missing_midi"]:
            print("   %s" % name)
        print()
    if report["unclear"]:
        print("Unklar, teils Person / teils nicht -- NICHT uebernommen, bitte entscheiden:")
        for t in report["unclear"]:
            print("   %s: %s" % (t["track"],
                                 ", ".join(repr(v["raw"]) for v in t["versions"])))
        print()
    if report["warnings"]:
        print("Warnungen:")
        for w in report["warnings"]:
            print("   %s" % w)
        print()
    print("Ohne Cast verworfen: %d Tracks (z.B. Mikrofonspuren mit 'v1')"
          % len(report["dropped"]))


# -- Validierung gegen das Swift-Datenmodell -----------------------------

def validate(cfg):
    """Prueft, was JSONDecoder in CastPilot spaeter voraussetzt."""
    problems = []
    for key in ("delayMs", "interRoleDelayMs", "prevVersionCommand",
                "nextVersionCommand", "roles", "emailConfig", "midiOutputName",
                "showName"):
        if key not in cfg:
            problems.append("AppConfig fehlt %r" % key)
    for r in cfg["roles"]:
        ids = {m["id"] for m in r["members"]}
        if len(ids) != len(r["members"]):
            problems.append("Rolle %s: doppelte Member-UUID" % r["name"])
        for m in r["members"]:
            if m["coverVariantOf"] and m["coverVariantOf"] not in ids:
                problems.append("Rolle %s: %s verweist auf unbekannten Principal"
                                % (r["name"], m["name"]))
        variants = {}
        for m in r["members"]:
            if m["coverVariantOf"]:
                variants.setdefault(m["coverVariantOf"], []).append(m["name"])
        for pid, names in variants.items():
            if len(names) > 1:
                problems.append("Rolle %s: %d Varianten fuer denselben Principal (%s) "
                                "-- die App findet nur die erste"
                                % (r["name"], len(names), ", ".join(names)))
        for t in r["tracks"]:
            if len(t["slotAssignments"]) != t["versionCount"]:
                problems.append("Track %s: slotAssignments %d != versionCount %d"
                                % (t["name"], len(t["slotAssignments"]),
                                   t["versionCount"]))
            filled = [s for s in t["slotAssignments"] if s]
            if len(filled) != len(set(filled)):
                problems.append("Track %s: Member doppelt belegt" % t["name"])
            for slot_id in filled:
                if slot_id not in ids:
                    problems.append("Track %s: Slot verweist auf unbekannten Darsteller"
                                    % t["name"])
            missing = [k for k in ("id", "name", "selectCommand", "versionCount",
                                   "slotAssignments", "slotOverrides") if k not in t]
            if missing:
                problems.append("Track %s: fehlende Felder %s" % (t["name"], missing))
            for k in ("id", "type", "channel", "value1", "value2"):
                if k not in t["selectCommand"]:
                    problems.append("Track %s: selectCommand fehlt %r" % (t["name"], k))
    return problems


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--npr")
    src.add_argument("--versions", help="JSON aus read_track_versions.py")
    ap.add_argument("-o", "--out")
    ap.add_argument("--remote-xml")
    ap.add_argument("--channel-base", type=int, choices=(0, 1), default=0)
    ap.add_argument("--strip-prefix", default="Select",
                    help="Praefix in den Generic-Remote-Namen, z.B. 'Select Luci PB'")
    ap.add_argument("--base", help="bestehende config.json / .castpilot")
    ap.add_argument("--show-name")
    ap.add_argument("--role-regex", default=r"^(\S+)",
                    help="wie der Rollenname aus dem Tracknamen faellt")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.npr:
        from read_track_versions import read
        tracks, _stats = read(a.npr)
        source = a.npr
    else:
        with open(a.versions) as fh:
            tracks = json.load(fh)["tracks"]
        source = a.versions

    show_name = a.show_name or re.sub(r"^[0-9a-f]{8}-", "",
                                      os.path.splitext(os.path.basename(source))[0])
    show_name = re.sub(r"_versions$", "", show_name)

    midi_map = {}
    if a.remote_xml:
        from read_generic_remote import parse as parse_remote, match_tracks
        mapping, _skipped = parse_remote(a.remote_xml, a.channel_base)
        names = [t["track"] for t in tracks if t["track"]]
        midi_map, ambiguous, _missing = match_tracks(
            mapping, names, strip=(a.strip_prefix,) if a.strip_prefix else ())
        for track, hits in ambiguous.items():
            print("MEHRDEUTIG in der Generic-Remote-XML: %r passt auf %s "
                  "-- Kommando bleibt leer" % (track, ", ".join(hits)), file=sys.stderr)

    base = None
    if a.base:
        with open(a.base) as fh:
            base = json.load(fh)

    cfg, report = build(tracks, show_name, a.role_regex, midi_map, base)
    print_report(cfg, report, base)

    problems = validate(cfg)
    if problems:
        print("\nFEHLER im erzeugten Show-File -- nicht importieren:")
        for p in problems:
            print("   %s" % p)
        return 1

    if a.dry_run:
        print("\n--dry-run: nichts geschrieben.")
        return 0

    out = a.out or (show_name + ".castpilot")
    with open(out, "w") as fh:
        json.dump(cfg, fh, ensure_ascii=False, indent=1)
    print("\nGeschrieben: %s" % out)
    print("In CastPilot ueber 'Show importieren' laden und einen Track gegen "
          "Nuendo gegenpruefen.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
