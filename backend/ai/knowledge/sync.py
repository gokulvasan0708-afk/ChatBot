"""Phase 3 - keep app_knowledge.json in sync with lib/ automatically.

Env (all optional):
  APP_LIB_DIR=../lib        folder to scan (if missing, stored JSON is used as-is)
  KNOWLEDGE_AUTOSYNC=0      turn the background watcher off
"""
import hashlib, json, os, threading, time

from scanner.scan_app import scan

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # backend/
LIB = os.environ.get("APP_LIB_DIR", os.path.join(ROOT, "..", "..", "lib"))
OUT = os.path.join(ROOT, "data", "app_knowledge.json")

_lock = threading.Lock()
_state = {"started": False, "sig": None, "last": None, "error": None}


def signature(lib=None):
    """Cheap change detector: path + mtime + size of every .dart file (no file reads)."""
    lib = lib or LIB
    h = hashlib.sha1()
    for root, dirs, names in os.walk(lib):
        dirs.sort()
        for n in sorted(names):
            if n.endswith(".dart") and n != "firebase_options.dart":
                p = os.path.join(root, n)
                st = os.stat(p)
                h.update(f"{p}|{st.st_mtime_ns}|{st.st_size}".encode())
    return h.hexdigest()


def reindex(lib=None):
    lib = lib or LIB
    if not os.path.isdir(lib):
        return {"ok": False, "error": f"lib folder not found: {os.path.abspath(lib)}"}
    with _lock:
        try:
            sig = signature(lib)
            stats = scan(lib, OUT)
            _state.update(sig=sig, last=int(time.time()), error=None)
            return {"ok": True, **stats}
        except Exception as e:                      # keep serving the old JSON
            _state["error"] = str(e)
            return {"ok": False, "error": str(e)}


def status():
    info = {"lib_found": os.path.isdir(LIB), "autosync": _state["started"],
            "last_reindex": _state["last"], "error": _state["error"]}
    try:
        kb = json.load(open(OUT, encoding="utf-8"))
        info.update(app=kb["app"], hash=kb["hash"], files=len(kb["files"]),
                    generated=kb["generated"])
    except Exception as e:
        info["knowledge_error"] = str(e)
    return info


def _loop(interval):
    while True:
        try:
            if os.path.isdir(LIB):
                s = signature()
                if s != _state["sig"]:
                    time.sleep(1.0)                 # let the editor finish writing
                    if signature() == s:
                        reindex()
                    continue
        except Exception as e:
            _state["error"] = str(e)
        time.sleep(interval)


def start_autosync(interval=5):
    """Call once at backend start. Scans immediately, then watches lib/."""
    if _state["started"] or os.environ.get("KNOWLEDGE_AUTOSYNC", "1") == "0":
        return
    _state["started"] = True
    threading.Thread(target=_loop, args=(interval,), daemon=True, name="knowledge-sync").start()
