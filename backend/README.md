# Nexus backend (merged)
- `server.js` + `package.json` : Node/Express (Firebase, Cloudinary) - `npm i && npm start` (port 3000)
- `ai/` : Python FastAPI AI assistant (auto-started by `npm start`; app calls `POST /api/assistant/chat` on port 3000)
- One command: `npm i && pip install -r ai/requirements.txt && npm start`. One root `.env` (copy `.env.example`) + `serviceAccountKey.json` next to server.js.
Optimized: repeat-question cache (CHAT_CACHE_TTL), shared HTTP pool, no file paths in AI context, minified knowledge JSON, max tokens 400.
