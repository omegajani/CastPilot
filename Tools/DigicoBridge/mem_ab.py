"""
mem_ab.py — A/B-Suche im Speicher von SD7Q (nur lesend).

    mem_ab.py snap NAME            Abzug aller beschreibbaren Bereiche nach DUMPDIR\\NAME.*
    mem_ab.py diff A B a b         Adressen, deren Byte in A == a und in B == b ist
    mem_ab.py live ADDRFILE v      welche Kandidaten haben JETZT den Wert v
"""
import sys, json, os, struct
sys.path.insert(0, r"C:\digico-live")
from memlib import find_pid, Process

DUMPDIR = os.environ.get("DUMPDIR", r"C:\digico-live\dumps")
PAGE = 4096


def snap(name):
    os.makedirs(DUMPDIR, exist_ok=True)
    p = Process(find_pid())
    index = []
    with open(os.path.join(DUMPDIR, name + ".bin"), "wb") as out:
        for base, size in p.regions(writable_only=True):
            data = p.read(base, size)
            if not data:
                continue
            index.append([base, out.tell(), len(data)])
            out.write(data)
    p.close()
    json.dump(index, open(os.path.join(DUMPDIR, name + ".json"), "w"))
    print(f"{name}: {len(index)} Bereiche, {sum(r[2] for r in index) / 1e6:.0f} MB")


def load(name):
    index = json.load(open(os.path.join(DUMPDIR, name + ".json")))
    return {base: (off, size) for base, off, size in index}, open(os.path.join(DUMPDIR, name + ".bin"), "rb")


def diff(a, b, va, vb):
    ia, fa = load(a)
    ib, fb = load(b)
    hits = []
    for base, (oa, sa) in ia.items():
        if base not in ib or ib[base][1] != sa:
            continue
        fa.seek(oa); da = fa.read(sa)
        fb.seek(ib[base][0]); db = fb.read(sa)
        if da == db:
            continue
        for pg in range(0, sa, PAGE):
            if da[pg:pg + PAGE] == db[pg:pg + PAGE]:
                continue
            for i in range(pg, min(pg + PAGE, sa)):
                if da[i] == va and db[i] == vb and da[i] != db[i]:
                    hits.append(base + i)
    out = os.path.join(DUMPDIR, f"cand_{a}_{b}_{va}_{vb}.json")
    json.dump(hits, open(out, "w"))
    print(f"{len(hits)} Kandidaten ({va}->{vb}) -> {out}")
    for h in hits[:30]:
        print("  ", hex(h))


def live(addrfile, v):
    cands = json.load(open(addrfile))
    p = Process(find_pid())
    keep = [a for a in cands if (d := p.read(a, 1)) and d[0] == v]
    p.close()
    print(f"{len(keep)} von {len(cands)} Kandidaten haben jetzt {v}:", [hex(a) for a in keep[:40]])
    json.dump(keep, open(addrfile.replace(".json", f"_live{v}.json"), "w"))


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "snap":
        snap(sys.argv[2])
    elif cmd == "diff":
        diff(sys.argv[2], sys.argv[3], int(sys.argv[4]), int(sys.argv[5]))
    elif cmd == "live":
        live(sys.argv[2], int(sys.argv[3]))
