"""Admin endpoints:  POST /knowledge/reindex   GET /knowledge/status

Auth: set REINDEX_TOKEN in .env and send header  X-Admin-Token: <token>.
If REINDEX_TOKEN is not set, only localhost can call these.
"""
import os
from typing import Optional

from fastapi import APIRouter, Header, HTTPException, Request

from . import sync

router = APIRouter(prefix="/knowledge", tags=["knowledge"])


def _auth(request: Request, token: Optional[str]):
    want = os.environ.get("REINDEX_TOKEN")
    if want:
        if token != want:
            raise HTTPException(status_code=403, detail="Forbidden")
    elif not request.client or request.client.host not in ("127.0.0.1", "::1", "localhost", "testclient"):
        raise HTTPException(status_code=403, detail="Forbidden")


@router.post("/reindex")
def reindex(request: Request, x_admin_token: Optional[str] = Header(default=None)):
    _auth(request, x_admin_token)
    res = sync.reindex()
    if not res.get("ok"):
        raise HTTPException(status_code=400, detail=res.get("error", "reindex failed"))
    return res


@router.get("/status")
def status(request: Request, x_admin_token: Optional[str] = Header(default=None)):
    _auth(request, x_admin_token)
    return sync.status()
