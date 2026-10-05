"""Phase 1 - scan a Flutter lib/ folder into a compact knowledge JSON.

Usage (from backend/):  python scanner/scan_app.py ../lib
Output: data/app_knowledge.json  (no LLM, no tokens, runs in <1s)
"""
import argparse, hashlib, json, os, re, sys, time

SKIP_FILES = {"firebase_options.dart"}          # contains keys - never read
SKIP_SUFFIX = (".g.dart", ".freezed.dart")
SKIP_METHODS = {"build", "dispose", "initState", "didChangeDependencies",
                "didUpdateWidget", "createState", "toString", "setState"}
Q = r"""(?:'((?:[^'\\\n]|\\.)*)'|"((?:[^"\\\n]|\\.)*)")"""
RE_TEXT = re.compile(r"\bText\(\s*(?:const\s+)?" + Q)
RE_KEYED = re.compile(r"\b(?:title|label|labelText|hintText|tooltip|subtitle|message)"
                      r"\s*:\s*(?:const\s+)?(?:Text\(\s*)?" + Q)
RE_TITLE = re.compile(r"(?:PageHeader|AppBar|NeoScaffold)\s*\([^;]{0,250}?\btitle\s*:\s*"
                      r"(?:const\s+)?(?:Text\(\s*)?" + Q)
RE_CLASS = re.compile(r"^class\s+(\w+)(?:\s+extends\s+([\w<>?]+))?", re.M)
RE_METHOD = re.compile(r"^\s{2}(?:static\s+)?(?:Future<[^>\n]*>|Future|void|bool)\s+(_?\w+)\s*\(", re.M)
RE_COLL = re.compile(r"\.collection\(\s*['\"](\w+)['\"]")
RE_PKG = re.compile(r"^import\s+'package:(\w+)/", re.M)
RE_IMP = re.compile(r"^import\s+'((?:\.\./|\./)[^']+\.dart)'", re.M)
RE_DOC = re.compile(r"^\s*///\s?(.+)$", re.M)
RE_SECT = re.compile(r"^\s*//\s*=+\s*\n\s*//\s*(.+?)\s*\n\s*//\s*=+", re.M)
RE_TABS = re.compile(r"(?:IndexedStack|PageView)\s*\([^\]]*?children:\s*(?:const\s*)?\[([^\]]*)\]")
RE_TABLBL = re.compile(r"\(Icons\.\w+,\s*Icons\.\w+,\s*'([^']+)'\)")
RE_LABEL = re.compile(r"\blabel\s*:\s*'([^']+)'")
RE_INTERP = re.compile(r"\$\{[^}]*\}|\$\w+")


def clean(s):
    s = RE_INTERP.sub("…", s.replace("\\'", "'").replace('\\"', '"')).strip()
    if len(s) < 2 or len(s) > 80 or not re.search(r"[A-Za-z]", s) or s == "…":
        return None
    if "$" in s or "{" in s or "}" in s:               # broken interpolation leftovers
        return None
    if s.startswith(("http", "assets/", "package:")):
        return None
    if " " not in s and re.search(r"[_/.:]", s):      # keys, paths, ids
        return None
    return s


def strings(src):
    out = []
    for rx in (RE_TEXT, RE_KEYED):
        for m in rx.finditer(src):
            c = clean(m.group(1) or m.group(2) or "")
            if c and c not in out:
                out.append(c)
    return out[:60]


def scan_file(path, rel, text):
    classes = RE_CLASS.findall(text)
    widgets = [n for n, b in classes if not n.startswith("_")
               and b in ("StatefulWidget", "StatelessWidget")]
    plain = [n for n, b in classes if not n.startswith("_") and n not in widgets]
    t = RE_TITLE.search(text)
    d = {
        "sha": hashlib.sha1(text.encode("utf-8", "ignore")).hexdigest()[:10],
        "lines": text.count("\n") + 1,
        "kind": rel.split("/")[0] if "/" in rel else "root",
        "widgets": widgets,
        "classes": plain,
        "title": clean((t.group(1) or t.group(2)) if t else "") if t else None,
        "doc": [x.strip() for x in RE_DOC.findall(text)][:3],
        "sections": [x for x in RE_SECT.findall(text)][:15],
        "strings": strings(text),
        "actions": [m for m in dict.fromkeys(RE_METHOD.findall(text))
                    if m not in SKIP_METHODS][:25],
        "collections": sorted(set(RE_COLL.findall(text))),
        "packages": sorted(p for p in set(RE_PKG.findall(text)) if p != "flutter"),
        "admin": bool(re.search(r"\bisAdmin\b|AdminService", text)),
    }
    tm = RE_TABS.search(text)
    if tm:
        ws = re.findall(r"\b(_?[A-Z]\w*)\s*\(", tm.group(1))
        ls = RE_TABLBL.findall(text)
        d["tabs"] = [f"{l}={w}" for l, w in zip(ls, ws)] if len(ls) == len(ws) else ws
    base = os.path.dirname(rel)
    imps = []
    for i in RE_IMP.findall(text):
        p = os.path.normpath(os.path.join(base, i)).replace("\\", "/")
        imps.append(p)
    d["imports"] = imps
    return {k: v for k, v in d.items() if v not in (None, [], "", False) or k == "sha"}


def link(files):
    """Add opens (navigation) / uses (embedded widgets) between files."""
    owner = {w: f for f, d in files.items() for w in d.get("widgets", [])}
    for f, d in files.items():
        text = d.pop("_text")
        opens, uses = [], []
        for w, wf in owner.items():
            if wf == f or not re.search(r"\b" + w + r"\s*\(", text):
                continue
            nav = re.search(r"(?:MaterialPageRoute|PageRouteBuilder|pushReplacement|pushAndRemoveUntil)"
                            r"[\s\S]{0,500}?\b" + w + r"\s*\(", text)
            (opens if nav else uses).append(w)
        if opens: d["opens"] = sorted(opens)
        if uses: d["uses"] = sorted(uses)
    for f, d in files.items():          # reverse edges: who opens this page
        for w in d.get("widgets", []):
            by = sorted(g for g, e in files.items() if w in e.get("opens", []))
            if by: d.setdefault("opened_by", {})[w] = by
    return files


def name_tabs(files):
    """IndexedStack children give page classes; a nav-bar file gives their labels.
    If a file has N unlabeled tab pages and a *nav* file has N `label:` texts, pair them."""
    navs = [d["_labels"] for f, d in files.items() if "nav" in f.lower() and d.get("_labels")]
    for d in files.values():
        t = d.get("tabs")
        if t and not any("=" in x for x in t):
            for labels in navs:
                if len(labels) == len(t):
                    d["tabs"] = [f"{l}={w}" for l, w in zip(labels, t)]
                    break
    for d in files.values():
        d.pop("_labels", None)


def scan(lib, out_path):
    """Scan lib/ and write the JSON atomically. Returns stats."""
    lib = os.path.abspath(lib)
    files, app = {}, None
    for root, dirs, names in os.walk(lib):
        dirs.sort()
        for n in sorted(names):
            if not n.endswith(".dart") or n in SKIP_FILES or n.endswith(SKIP_SUFFIX):
                continue
            p = os.path.join(root, n)
            rel = os.path.relpath(p, lib).replace("\\", "/")
            text = open(p, encoding="utf-8", errors="ignore").read()
            files[rel] = scan_file(p, rel, text)
            files[rel]["_text"] = text
            files[rel]["_labels"] = RE_LABEL.findall(text)
            m = re.search(r"appName\s*=\s*['\"]([^'\"]+)", text)
            if m: app = app or m.group(1)

    files = link(files)
    name_tabs(files)
    total = hashlib.sha1("".join(sorted(d["sha"] for d in files.values())).encode()).hexdigest()[:10]
    out = {"app": app or os.environ.get("APP_NAME", "Nexus"), "generated": int(time.time()), "hash": total,
           "files": dict(sorted(files.items()))}
    out_path = os.path.abspath(out_path)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)
    tmp = out_path + ".tmp"                      # write + swap: readers never see a half file
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(out, f, ensure_ascii=False, indent=1)
    os.replace(tmp, out_path)
    return {"app": out["app"], "files": len(files), "hash": total,
            "widgets": sum(len(d.get("widgets", [])) for d in files.values()),
            "strings": sum(len(d.get("strings", [])) for d in files.values())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("lib", nargs="?", default="../lib")
    ap.add_argument("-o", "--out", default="data/app_knowledge.json")
    a = ap.parse_args()
    if not os.path.isdir(a.lib):
        sys.exit(f"lib folder not found: {os.path.abspath(a.lib)}")
    st = scan(a.lib, a.out)
    print(f"app={st['app']} files={st['files']} widgets={st['widgets']} "
          f"strings={st['strings']} -> {a.out} ({os.path.getsize(a.out)//1024} KB)")


if __name__ == "__main__":
    main()
