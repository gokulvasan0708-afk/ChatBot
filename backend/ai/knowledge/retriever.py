"""Phase 2 - pick only the app data relevant to a user question.

CLI test (from backend/):  python -m knowledge.retriever "group epdi create panradhu"
"""
import json, math, os, re, sys
from collections import Counter

DATA = os.path.join(os.path.dirname(__file__), "..", "data", "app_knowledge.json")

STOP = set("""a an the is are to of in on for and or it this that i me my you how what where
when can do does did be with from at as by if so epdi enga engae irukku iruku irukka panna
pannum pannalam panrathu panradhu pannunga enna ah la ku da ma vendum venum sollu sollunga
eppadi edhu idhu ithu athu atha itha oru""".split())

SYN = {  # query word -> extra words that appear in the app data
    "logout": ["sign", "out"], "signout": ["sign", "out"], "login": ["login", "sign"],
    "register": ["signup", "create", "account"], "signup": ["create", "account", "sign"],
    "community": ["hub"], "hub": ["community"], "forum": ["community", "discussion"],
    "friend": ["connect", "request"], "connect": ["request", "chat"], "message": ["chat"],
    "dm": ["chat", "private"], "group": ["groups", "chat"], "club": ["clubs"],
    "call": ["voice", "ring", "incoming"], "video": ["call"], "mute": ["notify", "notification"],
    "alert": ["notification", "notify"], "theme": ["dark", "light", "mode"],
    "dark": ["theme", "mode"], "account": ["profile", "me"], "profile": ["me"],
    "find": ["search"], "report": ["moderation"], "ban": ["moderation"],
    "vote": ["poll"], "announce": ["announcement"], "notice": ["board", "announcement"],
    "meetup": ["event"], "file": ["resource"], "upload": ["resource", "share"],
    "delete": ["remove", "manage"], "edit": ["manage"], "join": ["request", "password", "requirement"],
}
W = {"title": 3, "widgets": 3, "file": 3, "sections": 2, "strings": 2,
     "actions": 1.5, "doc": 1, "classes": 1.5, "collections": 0.5}

GENERIC = {"state", "init", "dispose", "build", "variables", "controllers", "message",
           "helpers", "ui", "form", "load", "save", "open", "close"}

_cache = {"mtime": None, "docs": None, "meta": None}


def _stem(w):
    if len(w) > 4 and w.endswith("ing"):
        return w[:-3]
    if len(w) > 3 and w.endswith("s") and not w.endswith("ss"):
        return w[:-1]
    return w


def _tok(text):
    text = re.sub(r"([a-z])([A-Z])", r"\1 \2", text)
    out = []
    for w in re.findall(r"[a-z0-9]+", text.lower()):
        if w not in STOP and len(w) > 1:
            out.append(_stem(w))
    return out


def _human(name):
    return " ".join(_tok_raw(name))


def _tok_raw(name):
    name = re.sub(r"([a-z])([A-Z])", r"\1 \2", name.replace("_", " "))
    return name.lower().split()


def _load():
    m = os.path.getmtime(DATA)
    if _cache["mtime"] == m:
        return _cache["docs"], _cache["meta"]
    kb = json.load(open(DATA, encoding="utf-8"))
    files = kb["files"]
    f2w = {f: d.get("widgets", []) for f, d in files.items()}
    docs, tabs = [], {}
    for f, d in files.items():
        for t in d.get("tabs", []):
            if "=" in t:
                l, w = t.split("=", 1)
                tabs[w] = l
    for f, d in files.items():
        if d.get("kind") == "features":      # the assistant itself isn't app content
            continue
        d["sections"] = [x for x in d.get("sections", []) if x.lower() not in GENERIC]
        tf = Counter()
        def add(field, items):
            for it in items:
                for t in _tok(it):
                    tf[t] += W[field]
        add("file", [os.path.splitext(os.path.basename(f))[0].replace("_", " ")])
        for k in ("widgets", "classes", "sections", "strings", "actions", "collections", "doc"):
            add(k, d.get(k, []))
        if d.get("title"):
            add("title", [d["title"]])
        reached = sorted({w for src in d.get("opened_by", {}).values() for g in src for w in f2w.get(g, [])})
        docs.append({"file": f, "d": d, "tab": tabs.get((d.get("widgets") or [""])[0]), "tf": tf, "len": sum(tf.values()) or 1, "reached": reached})
    avg = sum(x["len"] for x in docs) / max(len(docs), 1)
    df = Counter(t for x in docs for t in x["tf"])
    meta = {"app": kb["app"], "tabs": list(tabs.values()), "avg": avg, "df": df, "n": len(docs),
            "pages": [(w, d.get("title")) for f, d in files.items()
                      if d.get("kind") == "pages" for w in d.get("widgets", [])]}
    _cache.update(mtime=m, docs=docs, meta=meta)
    return docs, meta


def search(query, k=3):
    docs, meta = _load()
    q = _tok(query)
    for w in list(q):
        q += [_stem(x) for x in SYN.get(w, [])]
    q = set(q)
    scored = []
    for x in docs:
        s = 0.0
        for t in q:
            f = x["tf"].get(t, 0)
            if not f:
                continue
            idf = math.log(1 + (meta["n"] - meta["df"][t] + .5) / (meta["df"][t] + .5))
            s += idf * f * 2.2 / (f + 1.2 * (0.25 + 0.75 * x["len"] / meta["avg"]))
        if s > 0:
            if x["d"].get("kind") == "services":     # user-facing screens beat internals
                s *= 0.65
            scored.append((s, x))
    scored.sort(key=lambda p: -p[0])
    if not scored:
        return []
    top = scored[0][0]
    return [x for s, x in scored[:k] if s >= 0.55 * top]


def _cut(s, n):
    return s if len(s) <= n else s[:n].rsplit("; ", 1)[0].rstrip(",; ") + " ..."


def _render(x):
    d = x["d"]
    name = ", ".join(d.get("widgets", [])) or ", ".join(d.get("classes", [])[:3]) or x["file"]
    p = [name]
    if d.get("title"): p.append(f"title: {d['title']}")
    if d.get("strings"): p.append("texts: " + "; ".join(d["strings"][:25]))
    if d.get("sections"): p.append("sections: " + "; ".join(s.lower() for s in d["sections"][:10]))
    if d.get("actions"): p.append("actions: " + ", ".join(_human(a) for a in d["actions"][:10]))
    if d.get("opens"): p.append("opens: " + ", ".join(d["opens"]))
    if x.get("tab"): p.append(f"bottom nav tab: {x['tab']}")
    if x["reached"]: p.append("reached from: " + ", ".join(x["reached"]))
    if d.get("admin"): p.append("has admin-only parts")
    return _cut(" | ".join(p), 700)


def overview(cap=420):
    _, meta = _load()
    tabs = f"Bottom nav tabs: {', '.join(meta['tabs'])}\n" if meta["tabs"] else ""
    names = [f"{w}" + (f" ({t})" if t else "") for w, t in meta["pages"]
             if w.endswith(("Page", "Screen"))]
    head = f"{meta['app']} pages: "
    out, used = [], len(head) + len(tabs)
    for n in names:
        if used + len(n) + 2 > cap:
            out.append("...")
            break
        out.append(n)
        used += len(n) + 2
    return tabs + head + ", ".join(out)


def retrieve(query, max_chars=2400, k=3):
    """Compact context string: overview + top matching files."""
    parts = [overview()]
    used = len(parts[0])
    for x in search(query, k):
        r = _render(x)
        if used + len(r) > max_chars:
            break
        parts.append(r)
        used += len(r)
    return "\n".join(parts)


if __name__ == "__main__":
    for qu in sys.argv[1:] or ["hello"]:
        c = retrieve(qu)
        print(f"\n### {qu}  ({len(c)} chars)\n{c}")
