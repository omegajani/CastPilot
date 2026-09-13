#!/usr/bin/env python3
"""
read_generic_remote.py -- MIDI-Select-Kommandos aus Nuendos Generic-Remote-XML

Das .npr enthaelt die MIDI-Zuordnung NICHT. Welches MIDI-Kommando einen Track
anwaehlt, steht in der Generic-Remote-Definition, die in Nuendo importiert wird
(im CastPilot-Release-Zip: "midi list nuendo.xml").

Dieses Script liest daraus  Trackname -> MidiCommand  im CastPilot-Format.

WICHTIG -- der Parser ist absichtlich tolerant: Steinberg hat das XML-Layout
zwischen Versionen mehrfach geaendert, und Nuendo 13+ nutzt teils MIDI Remote
statt Generic Remote. Statt auf ein Layout zu wetten, sammelt das Script jedes
Element, das einen Namen UND MIDI-Felder traegt, und akzeptiert die gaengigen
Feld-Schreibweisen. Passt nichts, zeigt --dump die tatsaechlich gefundenen
Tags/Attribute, damit die Zuordnung in Minuten nachgezogen werden kann.

Aufruf:
    python3 read_generic_remote.py <midi list nuendo.xml> [--json out.json]
                                   [--dump] [--print]
"""
import sys
import os
import re
import json
import argparse
import xml.etree.ElementTree as ET

# MIDI-Status-Nibble -> CastPilot MidiCommandType.rawValue
STATUS_TYPES = {
    0x80: "Note",            # Note Off -- CastPilot kennt nur "Note"
    0x90: "Note",            # Note On
    0xB0: "Control Change",
    0xC0: "Program Change",
}

# Feldnamen, wie Steinberg sie ueber die Versionen geschrieben hat.
FIELD_ALIASES = {
    "name": ("name", "title", "controlname", "control name"),
    "status": ("status", "midistatus", "midi status", "messagetype", "type"),
    "channel": ("channel", "midichannel", "midi channel", "chn"),
    "value1": ("address", "midiaddress", "midi address", "value1", "controller",
               "cc", "ccnumber", "data1", "note", "notenumber", "program"),
    "value2": ("maxvalue", "max value", "value2", "data2", "velocity", "value"),
}
ALIAS_LOOKUP = {alias: key for key, aliases in FIELD_ALIASES.items() for alias in aliases}


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
    """Sammelt {kanonisches_feld: wert} aus einem Element und seinen Kindern.

    Deckt beide Steinberg-Stile ab:
      <string name="Name" value="Luci PB"/>   (name/value-Attributpaar)
      <Name>Luci PB</Name>                    (Tag == Feldname)
    """
    found = {}
    for node in elem.iter():
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

    channel_base: 0, wenn das XML MIDI-Kanaele 0-basiert zaehlt (Steinberg-Default),
    1, wenn bereits 1-basiert. CastPilot speichert immer 1-basiert.
    """
    status = f.get("status")
    if status is None:
        return None
    if status < 0x80:
        # Manche Exporte schreiben nur das High-Nibble (9, 11, 12) statt 144/176/192.
        status = (status << 4) if status <= 0x0F else status
    kind = STATUS_TYPES.get(status & 0xF0)
    if kind is None:
        return None
    # Kanal steht mal im Status-Nibble, mal als eigenes Feld. CastPilot zaehlt ab 1.
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
        cmd = _to_command(f, channel_base)
        name = f["name"].strip()
        if cmd is None:
            skipped.append(name)
        elif name and name not in mapping:
            # Aeussere Elemente erben die Felder ihrer Kinder; das erste (innerste)
            # Vorkommen eines Namens gewinnt, weil iter() Dokumentreihenfolge liefert.
            mapping[name] = cmd
    return mapping, skipped


def match_tracks(mapping, track_names, strip=()):
    """Ordnet Trackname -> MidiCommand zu.

    Generic-Remote-Eintraege heissen selten exakt wie der Track ("Select Luci PB",
    "Luci PB Sel"). Deshalb drei Stufen: exakt, nach Praefix-Strip, dann Teilstring.
    Mehrdeutiges wird NICHT geraten, sondern gemeldet.
    """
    by_norm = {}
    for ctrl, cmd in mapping.items():
        label = ctrl
        for pre in strip:
            label = re.sub(r"^\s*" + re.escape(pre) + r"\s*", "", label, flags=re.I)
        by_norm.setdefault(_norm(label), []).append((ctrl, cmd))

    result, ambiguous, missing = {}, {}, []
    for track in track_names:
        key = _norm(track)
        hits = by_norm.get(key)
        if not hits:
            hits = [(c, v) for norm, entries in by_norm.items()
                    for c, v in entries if key and key in norm]
        if not hits:
            missing.append(track)
        elif len(hits) > 1:
            ambiguous[track] = [c for c, _ in hits]
        else:
            result[track] = hits[0][1]
    return result, ambiguous, missing


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
    print("\nTags:")
    for t, c in sorted(tags.items(), key=lambda x: -x[1])[:40]:
        print("  %6d  <%s>" % (c, t))
    print("\nAttribute:")
    for a, c in sorted(attrs.items(), key=lambda x: -x[1])[:20]:
        print("  %6d  %s=" % (c, a))
    print("\nWerte von name= (die Feldnamen):")
    for l, c in sorted(labels.items(), key=lambda x: -x[1])[:60]:
        mapped = ALIAS_LOOKUP.get(_norm(l))
        print("  %6d  %-32s %s" % (c, l, "-> " + mapped if mapped else ""))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("xml")
    ap.add_argument("--json", help="JSON-Ausgabe (Default: <xml>_midi.json)")
    ap.add_argument("--print", dest="show", action="store_true")
    ap.add_argument("--dump", action="store_true",
                    help="XML-Struktur zeigen, wenn nichts erkannt wird")
    ap.add_argument("--channel-base", type=int, choices=(0, 1), default=0,
                    help="zaehlt das XML MIDI-Kanaele ab 0 (Steinberg-Default) "
                         "oder ab 1? Gegenprobe: ein bekannter Track muss in "
                         "CastPilot denselben Kanal zeigen wie in Nuendo.")
    a = ap.parse_args()

    if a.dump:
        dump(a.xml)
        return 0

    mapping, skipped = parse(a.xml, a.channel_base)
    if not mapping:
        print("Keine MIDI-Kommandos erkannt. Struktur pruefen mit:\n"
              "  python3 %s %s --dump" % (os.path.basename(sys.argv[0]), a.xml),
              file=sys.stderr)
        return 1

    jp = a.json or os.path.splitext(a.xml)[0] + "_midi.json"
    with open(jp, "w") as fh:
        json.dump(mapping, fh, ensure_ascii=False, indent=1, sort_keys=True)
    print("%d MIDI-Kommandos erkannt%s\n  -> %s"
          % (len(mapping),
             ", %d Eintraege ohne brauchbaren Status uebersprungen" % len(skipped)
             if skipped else "", jp))
    if a.show:
        for name in sorted(mapping):
            c = mapping[name]
            print("  %-36s %s ch%d %d/%d"
                  % (name, c["type"], c["channel"], c["value1"], c["value2"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
