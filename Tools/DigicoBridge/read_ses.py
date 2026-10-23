#!/usr/bin/env python3
"""
read_ses.py — DiGiCo SD (SDQ) .ses Channel-List Extractor
Liest die geordnete Kanalliste aus einem SD7-Sessionfile,
ohne die Binärdatei in einen LLM-Kontext zu laden.

Format 'DiGiCo  SDQ .SES vM': Namens-Records im 92-Byte-Raster.
Record-Layout (relativ zum Namensfeld-Offset `o`):
    o-5  Port-/Kanal-Index (0-basiert)
    o-3  Port-/Kanal-Nummer (1-basiert)
    o-1  NAMENSLÄNGE in Bytes   <-- maßgeblich!
    o    Namensfeld, 32 Byte, latin1
    o+32 Signatur 01 FF FF FF FF

WICHTIG: Das Pult schreibt bei Umbenennungen nur die ersten `len` Bytes neu und
lässt den Rest des 32-Byte-Feldes stehen. Wer bis zum NUL liest, nimmt Reste
älterer Namen mit ("Lead HH 14b" statt "Lead HH", "Ch 15y" statt "Ch 15").
Daher: Name = Feld[:len]. len == 0 heißt "kein eigener Name" — dann steht im
Puffer das Default-Label des Pults, das wir als Fallback zurückgeben.

Das Längen-Byte ist zugleich der Record-Validator: ein Offset ohne plausible
Länge (0..31) ist kein Record. Ohne diese Prüfung lief der Lauf der
Kanaltabelle einen Record zu weit in den Header des nächsten Geräts
("Talkback Input") und meldete 178 statt 177 Kanäle.

SD7-Kanalnummer = Listenposition + 1.

Aufruf: python3 read_ses.py <datei.ses> [--json out] [--csv out] [--print]
"""
import sys, re, json, os, argparse
NAMELEN=32; STRIDE=92; LENOFF=-1
NAME_RE=re.compile(rb"^([\x20-\x7e\xa0-\xff]{1,31})")

def namelen(data,off):
    """Deklarierte Namenslänge aus dem Byte vor dem Feld (0..31, sonst None)."""
    if off+LENOFF < 0: return None
    n=data[off+LENOFF]
    return n if 0<=n<NAMELEN else None

def namecell(data,off):
    """Rohname: bis zum ersten NUL. Nur für den Locator/Scoring."""
    m=NAME_RE.match(data[off:off+NAMELEN])
    return m.group(1).decode("latin1") if m else None

def cleanname(data,off):
    """Angezeigter Name: Feld[:len].

    len == 0 heißt "kein eigener Name" — das Pult zeigt dann sein Default-Label.
    Der Puffer kann in diesem Fall BEIDES enthalten: das Default-Label (nie
    umbenannt) oder einen alten, gelöschten Namen (z. B. ch 48 'Vibra High').
    Deshalb wird er NICHT als Name ausgegeben, sondern nur als `raw` geführt.
    """
    n=namelen(data,off)
    if n is None: return namecell(data,off), None
    if n==0:      return "", 0
    return data[off:off+n].decode("latin1"), n

def extract(path, stride=STRIDE):
    data=open(path,"rb").read()
    header=data[:24].decode("latin1","replace").strip()
    cells=set()
    # alle Offsets mit gültigem Namensfeld einsammeln
    i=0; n=len(data)
    while i<n-NAMELEN:
        if 0x20<=data[i]<=0x7e and namelen(data,i) is not None:
            m=NAME_RE.match(data[i:i+NAMELEN])
            if m: cells.add(i)
        i+=1
    # Kandidaten-Läufe nach Namensvielfalt bewerten (nicht nur Länge) —
    # verhindert Treffer auf Läufe gleicher Zellen (z. B. 'X'-Matrixmarken).
    SIG=b"\x01\xff\xff\xff\xff"   # Datensatz-Signatur bei Name+32 (bei kurzen Namen)
    def score(run):
        sig=sum(1 for o in run if data[o+NAMELEN:o+NAMELEN+5]==SIG)
        distinct=len({namecell(data,o) for o in run if len(namecell(data,o) or "")>=3})
        return (sig, distinct, len(run))
    runs=[]
    for s in cells:
        if s-stride in cells: continue
        run=[s]; nxt=s+stride
        while nxt in cells: run.append(nxt); nxt+=stride
        if len(run)>=20: runs.append(run)
    best=max(runs,key=score) if runs else []
    chans=[]
    for i,off in enumerate(best):
        nm,ln=cleanname(data,off)
        chans.append({"ch":i+1,"name":nm or "","offset":off,
                      "namelen":ln,"named":bool(ln),"raw":namecell(data,off) or ""})
    return header,chans

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("ses"); ap.add_argument("--json"); ap.add_argument("--csv"); ap.add_argument("--print",action="store_true")
    a=ap.parse_args()
    header,chans=extract(a.ses)
    base=os.path.splitext(a.ses)[0]
    jp=a.json or base+"_channels.json"; cp=a.csv or base+"_channels.csv"
    json.dump({"header":header,"count":len(chans),"channels":chans},open(jp,"w"),ensure_ascii=False,indent=0)
    with open(cp,"w") as w:
        w.write("ch;name;named\n")
        for c in chans: w.write(f'{c["ch"]};{c["name"]};{1 if c["named"] else 0}\n')
    dirty=sum(1 for c in chans if c["raw"]!=c["name"])
    print(f"{header} | {len(chans)} Kanäle -> {os.path.basename(jp)}, {os.path.basename(cp)}")
    print(f"  {dirty} Namen hatten Puffer-Reste hinter dem Namen (jetzt per Längen-Byte bereinigt)")
    if a.print:
        for c in chans:
            flag="" if c["named"] else "  [unbenannt]"
            extra=f'   (roh: {c["raw"]!r})' if c["raw"]!=c["name"] else ""
            print(f'  {c["ch"]:3} {c["name"]}{flag}{extra}')

if __name__=="__main__": main()
