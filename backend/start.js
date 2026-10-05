// One command starts everything: npm start  (Node on :3000, AI on 127.0.0.1:8000)
try { process.loadEnvFile(); } catch (_) {}
const { spawn } = require("child_process");
const path = require("path");

if (process.env.AI_ENABLED !== "0") {
    const py = process.env.PYTHON || (process.platform === "win32" ? "python" : "python3");
    const ai = spawn(py, ["-m", "uvicorn", "main:app", "--host", "127.0.0.1", "--port", process.env.AI_PORT || "8000"],
        { cwd: path.join(__dirname, "ai"), stdio: "inherit", env: process.env });
    ai.on("error", (e) => console.warn("[ai] not started:", e.message));
    ai.on("exit", (c) => console.warn("[ai] exited:", c));
    const stop = () => { if (!ai.killed) ai.kill(); };
    process.on("exit", stop);
    ["SIGINT", "SIGTERM"].forEach((s) => process.on(s, () => { stop(); process.exit(0); }));
}
require("./server.js");
