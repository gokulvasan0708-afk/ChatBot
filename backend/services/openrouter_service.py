import os

import httpx

URL = "https://openrouter.ai/api/v1/chat/completions"
_client = None


def _http():
    global _client
    if _client is None:  # reuse one connection pool (faster, no TLS per call)
        _client = httpx.AsyncClient(timeout=httpx.Timeout(60.0, connect=10.0))
    return _client


class ChatError(Exception):
    def __init__(self, status: int, detail: str):
        super().__init__(detail)
        self.status = status
        self.detail = detail


async def complete(system: str, user: str, max_tokens: int | None = None, temperature: float = 0.4) -> str:
    """One OpenRouter chat completion. Key + model come only from backend .env."""
    key = os.getenv("OPENROUTER_API_KEY")
    model = os.getenv("OPENROUTER_MODEL")
    if not key or not model:
        raise ChatError(500, "AI service is not configured.")

    body = {
        "model": model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        "max_tokens": max_tokens or int(os.getenv("OPENROUTER_MAX_TOKENS", "600")),
        "temperature": temperature,
    }
    headers = {"Authorization": f"Bearer {key}", "X-Title": "Nexus"}

    try:
        r = await _http().post(URL, headers=headers, json=body)
    except httpx.TimeoutException:
        raise ChatError(504, "The AI model timed out. Please try again.")
    except httpx.HTTPError:
        raise ChatError(502, "Cannot reach the AI provider.")

    if r.status_code == 429:
        raise ChatError(429, "AI provider is busy. Try again shortly.")
    if r.status_code in (401, 403):      # our key problem, not the user's
        raise ChatError(502, "AI provider rejected the API key.")
    if r.status_code >= 400:
        raise ChatError(502, "AI provider error.")

    try:
        text = r.json()["choices"][0]["message"]["content"]
    except (ValueError, KeyError, IndexError, TypeError):
        text = None
    if not isinstance(text, str) or not text.strip():
        raise ChatError(502, "Empty response from AI.")
    return text.strip()
