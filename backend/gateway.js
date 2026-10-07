// Proxies the Flutter app -> Python AI assistant through the one Node port.
const AI = () => process.env.AI_URL || `http://127.0.0.1:${process.env.AI_PORT || 8000}`;

module.exports = (app) => {
    // Forwards a JSON body to the Python service and relays status + JSON back.
    const forward = (pyPath, timeoutMs, validate) => async (req, res) => {
        const body = req.body || {};
        const bad = validate && validate(body);
        if (bad) return res.status(400).json({ error: bad });
        try {
            const r = await fetch(AI() + pyPath, {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-Forwarded-For": req.ip || "" },
                body: JSON.stringify(body),
                signal: AbortSignal.timeout(timeoutMs),
            });
            res.status(r.status).json(await r.json().catch(() => ({})));
        } catch (_) {
            res.status(502).json({ error: "AI service unavailable" });
        }
    };

    const needMessage = (b) =>
        typeof b.message !== "string" || !b.message.trim() ? "message required" : null;
    const needTexts = (b) =>
        !Array.isArray(b.texts) || !b.texts.length ? "texts required" : null;

    // AI assistant chat (original route + /chat alias used by the Flutter app)
    app.post("/api/assistant/chat", forward("/chat", 30000, needMessage));
    app.post("/chat", forward("/chat", 30000, needMessage));

    // Translator (max 5 texts per request, handled by the Python service)
    app.post("/translate", forward("/translate", 35000, needTexts));
    app.post("/api/assistant/translate", forward("/translate", 35000, needTexts));

    app.get("/api/assistant/health", async (_req, res) => {
        try {
            const r = await fetch(AI() + "/health", { signal: AbortSignal.timeout(3000) });
            res.status(r.ok ? 200 : 502).json({ ai: r.ok });
        } catch (_) {
            res.status(502).json({ ai: false });
        }
    });
};