import os
import time
from collections import OrderedDict, defaultdict, deque

from dotenv import load_dotenv

load_dotenv()  # must run before the imports below read env vars

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel, Field

from app_context import build_system_prompt
from knowledge.api import router as knowledge_router
from knowledge.sync import start_autosync
from services.openrouter_service import ChatError, complete

app = FastAPI(title="Nexus Assistant")

# Web builds need CORS. Production: ALLOWED_ORIGINS=https://your-web-domain.com
_origins = [o.strip() for o in os.getenv("ALLOWED_ORIGINS", "*").split(",") if o.strip()]
app.add_middleware(
    CORSMiddleware,
    allow_origins=_origins,
    allow_methods=["GET", "POST"],
    allow_headers=["Content-Type", "X-Admin-Token"],
)

app.include_router(knowledge_router)
start_autosync()  # keeps data/app_knowledge.json in sync with ../lib

# tiny per-IP rate limit to protect the API key
_LIMIT = int(os.getenv("CHAT_RATE_LIMIT", "30"))  # requests per minute
_hits = defaultdict(deque)

# repeated questions are answered from memory -> zero model tokens (0 = off)
_TTL = int(os.getenv("CHAT_CACHE_TTL", "1800"))
_cache = OrderedDict()


def _rate_limit(request: Request):
    ip = request.client.host if request.client else "?"
    if ip in ("127.0.0.1", "::1"):  # behind the Node gateway -> real client IP
        ip = request.headers.get("x-forwarded-for", ip).split(",")[0].strip() or ip
    q, now = _hits[ip], time.time()
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= _LIMIT:
        raise HTTPException(status_code=429, detail="Too many requests.")
    q.append(now)


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)


@app.get("/health")
def health():
    return {"ok": True}


@app.post("/chat")
async def chat(req: ChatRequest, request: Request):
    _rate_limit(request)
    msg = req.message.strip()
    if not msg:
        raise HTTPException(status_code=400, detail="Message is empty.")
    key = " ".join(msg.lower().split())
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < _TTL:
        return {"response": hit[1]}
    try:
        text = await complete(build_system_prompt(msg), msg)
    except ChatError as e:
        raise HTTPException(status_code=e.status, detail=e.detail)
    if _TTL > 0:
        _cache[key] = (time.time(), text)
        if len(_cache) > 300:
            _cache.popitem(last=False)
    return {"response": text}
