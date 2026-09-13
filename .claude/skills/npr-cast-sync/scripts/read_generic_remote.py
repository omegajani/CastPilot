#!/usr/bin/env python3
"""
read_generic_remote.py -- MIDI-Kommandos aus Nuendos Generic-Remote-XML

Das .npr enthaelt die MIDI-Zuordnung NICHT. Welches Kommando einen Track anwaehlt
und welches durch die Track Versions blaettert, steht in der Generic-Remote-
Definition, die in Nuendo importiert wird ("midi list nuendo.xml" o.ae.).

Geliefert werden zwei Dinge:
  1. Trackname -> Select-Kommando
  2. die TrackVersions-Kommandos (Previous / Next Version)

Format siehe ../references/generic-remote-format.md

Der Parser ist bewusst tolerant: Steinberg hat das XML-Layout mehrfach geaendert.
Erkannt werden die Feldnamen aller bekannten Varianten. Passt nichts, zeigt --dump
die tatsaechlichen Tags, damit FIELD_ALIASES in Minuten nachgezogen werden kann.

Aufruf:
    python3 read_generic_remote.py <datei.xml> [--json out.json] [--print]
                                   [--dump] [--channel-base 0|1] [--selftest]
"""
import os
import re
import sys
import json
import argparse
import xml.etree.ElementTree as ET

# MIDI-Status -> CastPilot MidiCommandType.rawValue
STATUS_TYPES = {
    0x80: "Note",            # Note Off -- CastPilot kennt nur "Note"
    0x90: "Note",            # Note On
    0xB0: "Control Change",
    0xC0: "Program Change",
}

# Feldnamen aller bekannten Steinberg-Schreibweisen.
# <stat>/<chan>/<addr>/<max> ist das echte "remotedescription"-Format.
FIELD_ALIASES = {
    "name": ("name", "title", "controlname", "control name"),
    "status": ("stat", "status", "midistatus", "midi status", "messagetype", "type"),
    "channel": ("chan", "channel", "midichannel", "midi channel", "chn"),
    "value1": ("addr", "address", "midiaddress", "midi address", "value1",
               "controller", "cc", "ccnumber", "data1", "note", "notenumber",
               "program"),
    "value2": ("max", "maxvalue", "max value", "value2", "data2", "velocity",
               "value"),
}
ALIAS_LOOKUP = {alias: key for key, aliases in FIELD_ALIASES.items() for alias in aliases}

# Nuendo-Aktionen, mit denen CastPilot durch die Track Versions blaettert.
VERSION_ACTIONS = {"previous": "prev", "next": "next"}


def _norm(s):
    return re.sub(r"[^a-z0-9 ]", "", (s or "").strip().lower())


def _as_int(text):
    if text is None:
        return None
    text = text.strip()
    try:
        return int(text, 0) if text.lower().startswith("0x") else int(text)
    except ValueError:
        return None


def _fields(elem):
    """Sammelt {kanonisches_feld: wert} aus den DIREKTEN Kindern von elem.

    Nur direkte Kinder, bewusst: <chan> bedeutet je nach Ebene zwei verschiedene
    Dinge -- im <ctrl> der MIDI-Kanal, im <entry><value> der Mixer-Kanal des
    anzuwaehlenden Tracks. Ein Walk ueber den ganzen Teilbaum wuerde beides
    vermischen und aus Vater-Elementen Phantom-Eintraege bauen.

    Deckt alle bekannten Layouts ab:
      <ctrl><name>X</name><stat>144</stat>…            Tag == Feldname
      <item><string name="Name" value="X"/>…           name/value-Attributpaar
    """
    found = {}
    for node in elem:
        label = node.get("name") or node.tag
        key = ALIAS_LOOKUP.get(_norm(label))
        if key is None:
            continue
        raw = node.get("value")
        if raw is None:
            raw = (node.text or "").strip()
        if raw == "":
            continue
        if key == "name":
            found.setdefault("name", raw)
        else:
            val = _as_int(raw)
            if val is not None:
                found.setdefault(key, val)
    return found


def _to_command(f, channel_base=0):
    """{status, channel, value1, value2} -> CastPilot MidiCommand oder None.

    channel_base: 0, wenn das XML MIDI-Kanaele ab 0 zaehlt (Steinberg-Default),
    1, wenn bereits ab 1. CastPilot speichert immer ab 1.
    """
    status = f.get("status")
    if status is None:
        return None
    if status <= 0x0F:
        # Manche Exporte schreiben nur das High-Nibble (9, 11, 12) statt 144/176/192.
        status <<= 4
    kind = STATUS_TYPES.get(status & 0xF0)
    if kind is None:
        return None
    # Der Kanal steht mal als eigenes Feld, mal nur im Status-Nibble.
    channel = f.get("channel")
    channel = (status & 0x0F) + 1 if channel is None else channel + (1 - channel_base)
    return {
        "type": kind,
        "channel": max(1, min(16, channel)),
        "value1": f.get("value1", 0),
        "value2": f.get("value2", 127),
    }


def parse(path, channel_base=0):
    """-> (mapping, skipped). mapping = {control_name: MidiCommand}"""
    root = ET.parse(path).getroot()
    mapping, skipped = {}, []
    for elem in root.iter():
        f = _fields(elem)
        if "name" not in f or "status" not in f:
            continue
        name = f["name"].strip()
        cmd = _to_command(f, channel_base)
        if cmd is None:
            skipped.append(name)
        elif name and name not in mapping:
            mapping[name] = cmd
    return mapping, skipped


def bank_controls(path):
    """-> {control_name: (kategorie, aktion)} aus dem <bank>-Abschnitt.

    Damit laesst sich unterscheiden, ob ein Control einen Track anwaehlt oder
    eine Nuendo-Funktion ausloest -- "step up" ist kein ungenutztes Track-Select.
    """
    out = {}
    for entry in ET.parse(path).getroot().iter("entry"):
        cmd = entry.find("command")
        if cmd is not None and entry.get("ctrl"):
            out[entry.get("ctrl")] = (_norm(cmd.findtext("category")),
                                      _norm(cmd.findtext("action")))
    return out


def parse_actions(path, channel_base=0):
    """TrackVersions-Kommandos: -> {"prev": MidiCommand, "next": MidiCommand}

    Im <bank>-Abschnitt haengt an jedem Control eine Nuendo-Aktion:
        <entry ctrl="step up"><command>
            <category>TrackVersions</category><action>Previous Version</action>

    Die Control-Namen sind gegenlaeufig zur Intuition ("step up" = Previous),
    deshalb wird ueber die <action> gegangen, nie ueber den Namen.
    """
    mapping, _skipped = parse(path, channel_base)
    root = ET.parse(path).getroot()
    out = {}
    for entry in root.iter("entry"):
        cmd_node = entry.find("command")
        if cmd_node is None:
            continue
        if _norm(cmd_node.findtext("category")) != "trackversions":
            continue
        action = _norm(cmd_node.findtext("action"))
        slot = next((v for k, v in VERSION_ACTIONS.items() if k in action), None)
        ctrl = entry.get("ctrl")
        if slot and ctrl in mapping:
            out.setdefault(slot, mapping[ctrl])
    return out


# -- Zuordnung Track -> Control ------------------------------------------

def apply_aliases(name, kind, aliases):
    """Track-Name so umschreiben, wie das Control in der XML heisst.

    Zwei Regeln:
      * Token-Aliase, Wort fuer Wort (z.B. Luci->Lucy, HH->HS). Das Projekt und
        die XML sind von verschiedenen Leuten gepflegt und driften auseinander.
      * Gleichnamige PB-Spuren: Nuendo laesst zu, dass Audio- und MIDI-Spur
        beide "Dream PB" heissen. Die XML unterscheidet sie als "Dream PB" und
        "Dream MIDI" -- die Trackart loest die Dublette also auf.
    """
    aliases = aliases or {}
    toks = [aliases.get(t.lower(), t) for t in (name or "").split()]
    if kind == "midi" and toks and toks[-1].lower() == "pb":
        toks[-1] = "MIDI"
    return " ".join(toks)


def match_tracks(mapping, tracks, strip=(), aliases=None):
    """Ordnet Tracks ihren Select-Kommandos zu.

    tracks: [{"index":…, "track":…, "kind":…}]
    -> (matched, ambiguous, missing, unused)
       matched  {track_index: (control_name, MidiCommand)}
       missing  [(track, gesuchter_name)]
       unused   [control_name] -- Controls ohne Track

    Bewusst KEIN Fuzzy-Matching: im Echttest schlug difflib fuer "Endo PB" das
    Control "Select Endo TS" vor. Das haette den falschen Track angewaehlt.
    Stattdessen werden beide Seiten gemeldet und per Alias bestaetigt.
    """
    by_norm = {}
    for ctrl in mapping:
        label = ctrl
        for pre in strip:
            label = re.sub(r"^\s*" + re.escape(pre) + r"\s*", "", label, flags=re.I)
        by_norm.setdefault(_norm(label), []).append(ctrl)

    matched, ambiguous, missing, used = {}, {}, [], set()
    for t in tracks:
        wanted = apply_aliases(t.get("track"), t.get("kind"), aliases)
        hits = by_norm.get(_norm(wanted), [])
        if not hits:
            missing.append((t, wanted))
        elif len(hits) > 1:
            ambiguous[t["index"]] = (t, hits)
        else:
            matched[t["index"]] = (hits[0], mapping[hits[0]])
            used.add(hits[0])
    unused = sorted(set(mapping) - used)
    return matched, ambiguous, missing, unused


# -- Diagnose ------------------------------------------------------------

def dump(path):
    """Zeigt die tatsaechliche XML-Struktur -- zum Nachziehen der Feldnamen."""
    root = ET.parse(path).getroot()
    tags, attrs, labels = {}, {}, {}
    for node in root.iter():
        tags[node.tag] = tags.get(node.tag, 0) + 1
        for a in node.attrib:
            attrs[a] = attrs.get(a, 0) + 1
        label = node.get("name")
        if label:
            labels[label] = labels.get(label, 0) + 1
    print("Root: <%s>" % root.tag)
    print("\nTags (-> = als Feld erkannt):")
    for t, c in sorted(tags.items(), key=lambda x: -x[1])[:40]:
        mapped = ALIAS_LOOKUP.get(_norm(t))
        print("  %6d  <%-16s %s" % (c, t + ">", "-> " + mapped if mapped else ""))
    print("\nAttribute:")
    for a, c in sorted(attrs.items(), key=lambda x: -x[1])[:20]:
        print("  %6d  %s=" % (c, a))
    if labels:
        print("\nWerte von name= :")
        for l, c in sorted(labels.items(), key=lambda x: -x[1])[:40]:
            mapped = ALIAS_LOOKUP.get(_norm(l))
            print("  %6d  %-32s %s" % (c, l, "-> " + mapped if mapped else ""))


FIXTURES = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "tests", "fixtures")


def selftest():
    """Prueft beide Fixtures: volle Definition und Controller ohne Track-Selects."""
    problems = []

    full = os.path.join(FIXTURES, "generic_remote_full.xml")
    mapping, _skipped = parse(full)
    actions = parse_actions(full)
    if len(mapping) != 10:
        problems.append("volle Fixture: %d Controls statt 10" % len(mapping))
    expect_cmd = {"type": "Note", "channel": 1, "value1": 7, "value2": 127}
    if actions.get("prev") != expect_cmd:
        problems.append("Previous Version falsch: %r" % (actions.get("prev"),))
    if (actions.get("next") or {}).get("value1") != 8:
        problems.append("Next Version falsch: %r" % (actions.get("next"),))

    tracks = [
        {"index": 0, "track": "Alpha TS", "kind": "audio"},
        {"index": 1, "track": "Alpha HH", "kind": "audio"},
        {"index": 2, "track": "Alpha PB", "kind": "audio"},
        {"index": 3, "track": "Alpha PB", "kind": "midi"},
        {"index": 4, "track": "Beta PB", "kind": "audio"},
    ]
    matched, ambiguous, missing, unused = match_tracks(
        mapping, tracks, strip=("Select",), aliases={"hh": "HS"})
    got = {i: c for i, (c, _cmd) in matched.items()}
    want = {0: "Select Alpha TS", 1: "Select Alpha HS",
            2: "Select Alpha PB", 3: "Select Alpha MIDI"}
    if got != want:
        problems.append("Zuordnung: erwartet %r, bekommen %r" % (want, got))
    if [t["index"] for t, _ in missing] != [4]:
        problems.append("Beta PB muesste ohne Treffer sein, ist: %r"
                        % ([t["index"] for t, _ in missing],))
    if ambiguous:
        problems.append("unerwartet mehrdeutig: %r" % (list(ambiguous),))

    bare = os.path.join(FIXTURES, "generic_remote_transport_only.xml")
    bare_map, _ = parse(bare)
    bare_actions = parse_actions(bare)
    if bare_actions:
        problems.append("Transport-Fixture liefert TrackVersions-Aktionen: %r"
                        % (bare_actions,))
    _m, _a, bare_missing, _u = match_tracks(bare_map, tracks, strip=("Select",))
    if len(bare_missing) != len(tracks):
        problems.append("Transport-Fixture ordnet Tracks zu, obwohl sie keine hat")

    print("volle Fixture: %d Controls, prev/next erkannt | Transport-Fixture: "
          "%d Controls, keine Track-Selects" % (len(mapping), len(bare_map)))
    if problems:
        for p in problems:
            print("  FEHLER: " + p)
        return 1
    print("  OK")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml", nargs="?")
    ap.add_argument("--json", help="JSON-Ausgabe (Default: <xml>_midi.json)")
    ap.add_argument("--print", dest="show", action="store_true")
    ap.add_argument("--dump", action="store_true",
                    help="XML-Struktur zeigen, wenn nichts erkannt wird")
    ap.add_argument("--channel-base", type=int, choices=(0, 1), default=0,
                    help="zaehlt das XML MIDI-Kanaele ab 0 (Steinberg-Default) "
                         "oder ab 1? Gegenprobe: ein bekannter Track muss in "
                         "CastPilot denselben Kanal zeigen wie in Nuendo.")
    ap.add_argument("--selftest", action="store_true",
                    help="gegen die Fixtures in tests/fixtures pruefen")
    a = ap.parse_args()

    if a.selftest:
        return selftest()
    if not a.xml:
        ap.error("Dateiname fehlt (oder --selftest benutzen)")
    if a.dump:
        dump(a.xml)
        return 0

    mapping, skipped = parse(a.xml, a.channel_base)
    actions = parse_actions(a.xml, a.channel_base)
    if not mapping:
        print("Keine MIDI-Kommandos erkannt. Struktur pruefen mit:\n"
              "  python3 %s %s --dump" % (os.path.basename(sys.argv[0]), a.xml),
              file=sys.stderr)
        return 1

    jp = a.json or os.path.splitext(a.xml)[0] + "_midi.json"
    with open(jp, "w") as fh:
        json.dump({"controls": mapping, "trackVersionActions": actions},
                  fh, ensure_ascii=False, indent=1, sort_keys=True)
    print("%d Controls erkannt%s" % (len(mapping),
          ", %d ohne brauchbaren Status uebersprungen" % len(skipped) if skipped else ""))
    if actions:
        for slot, label in (("prev", "Previous Version"), ("next", "Next Version")):
            if slot in actions:
                c = actions[slot]
                print("  %-16s %s ch%d %d/%d"
                      % (label, c["type"], c["channel"], c["value1"], c["value2"]))
    else:
        print("  keine TrackVersions-Aktionen in dieser Datei")
    print("  -> %s" % jp)
    if a.show:
        for name in sorted(mapping):
            c = mapping[name]
            print("  %-36s %s ch%d %d/%d"
                  % (name, c["type"], c["channel"], c["value1"], c["value2"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
