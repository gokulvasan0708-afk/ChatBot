// Proxies the Flutter app -> Python AI assistant through the one Node port.
const AI = () => process.env.AI_URL || `http://127.0.0.1:${process.env.AI_PORT || 8000}`;

module.exports = (app) => {
    app.post("/api/assistant/chat", async (req, res) => {
        const message = req.body && req.body.message;
        if (typeof message !== "string" || !message.trim()) {
            return res.status(400).json({ error: "message required" });
        }
        try {
            const r = await fetch(AI() + "/chat", {
                method: "POST",
                headers: { "Content-Type": "application/json", "X-Forwarded-For": req.ip || "" },
                body: JSON.stringify({ message }),
                signal: AbortSignal.timeout(30000),
            });
            res.status(r.status).json(await r.json().catch(() => ({})));
        } catch (_) {
            res.status(502).json({ error: "AI service unavailable" });
        }
    });

    app.get("/api/assistant/health", async (_req, res) => {
        try {
            const r = await fetch(AI() + "/health", { signal: AbortSignal.timeout(3000) });
            res.status(r.ok ? 200 : 502).json({ ai: r.ok });
        } catch (_) {
            res.status(502).json({ ai: false });
        }
    });
};
