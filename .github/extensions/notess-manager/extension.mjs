import { createServer } from "node:http";
import { randomUUID } from "node:crypto";
import { readFile } from "node:fs/promises";
import { createCanvas, CanvasError, joinSession } from "@github/copilot-sdk/extension";
import { createManager } from "./manager.mjs";

const servers = new Map();
const managers = new Map();
const html = await readFile(new URL("./index.html", import.meta.url), "utf8");
const emptyInput = { type: "object", properties: {}, additionalProperties: false };

async function managerFor(repoPath) {
    let manager = managers.get(repoPath);
    if (!manager) {
        manager = await createManager(repoPath);
        managers.set(repoPath, manager);
    }
    return manager;
}

function instanceManager(instanceId) {
    const entry = servers.get(instanceId);
    if (!entry) throw new CanvasError("not_open", "Open the Notess manager first.");
    return entry.manager;
}

async function startServer(manager) {
    const prefix = `/${randomUUID()}/`;
    const server = createServer(async (req, res) => {
        res.setHeader("Cache-Control", "no-store");
        res.setHeader("X-Content-Type-Options", "nosniff");
        res.setHeader("Referrer-Policy", "no-referrer");
        const origin = `http://127.0.0.1:${server.address().port}`;
        if (req.headers.host !== new URL(origin).host ||
            (req.headers.origin && req.headers.origin !== origin)) {
            res.writeHead(403).end("This endpoint is local to the Notess canvas.");
            return;
        }
        const route = req.url?.split("?")[0];
        if (req.method === "GET" && route === prefix) {
            res.setHeader("Content-Type", "text/html; charset=utf-8");
            res.setHeader("Content-Security-Policy",
                "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; base-uri 'none'; form-action 'none'");
            res.end(html);
            return;
        }
        res.setHeader("Content-Type", "application/json; charset=utf-8");
        try {
            if (req.method === "GET" && route === `${prefix}api/status`) {
                res.end(JSON.stringify(await manager.refresh()));
                return;
            }
            if (req.method === "POST" &&
                [ `${prefix}api/build`, `${prefix}api/open` ].includes(route)) {
                if (req.headers["content-type"] !== "application/json") {
                    res.writeHead(415).end(JSON.stringify({ error: "Expected application/json." }));
                    return;
                }
                let body = "";
                for await (const chunk of req) {
                    body += chunk;
                    if (body.length > 1024) throw new Error("Request body is too large.");
                }
                if (body !== "{}") throw new Error("This action takes no parameters.");
                if (route === `${prefix}api/build`) {
                    res.writeHead(202).end(JSON.stringify(await manager.startBuild()));
                } else {
                    res.end(JSON.stringify(await manager.openApp()));
                }
                return;
            }
            res.writeHead(404).end(JSON.stringify({ error: "Not found." }));
        } catch (error) {
            res.writeHead(409).end(JSON.stringify({ error: error.message }));
        }
    });
    await new Promise((resolve, reject) => {
        server.once("error", reject);
        server.listen(0, "127.0.0.1", resolve);
    });
    return { server, manager, url: `http://127.0.0.1:${server.address().port}${prefix}` };
}

await joinSession({
    canvases: [
        createCanvas({
            id: "notess-manager",
            displayName: "Notess app manager",
            description: "Check the installed Notess build, build and install origin/main, and open the local app.",
            inputSchema: {
                type: "object",
                properties: { repoPath: { type: "string", minLength: 1, pattern: "^/" } },
                required: ["repoPath"],
                additionalProperties: false,
            },
            actions: [
                {
                    name: "get_status",
                    description: "Read the installed build, main revision, build progress, and any errors.",
                    inputSchema: emptyInput,
                    handler: (ctx) => instanceManager(ctx.instanceId).refresh(),
                },
                {
                    name: "refresh",
                    description: "Check origin/main now without modifying the checkout or installing anything.",
                    inputSchema: emptyInput,
                    handler: (ctx) => instanceManager(ctx.instanceId).refresh(true),
                },
                {
                    name: "build_install",
                    description: "On explicit user request, build main and replace ~/Applications/Notess.app.",
                    inputSchema: emptyInput,
                    handler: (ctx) => instanceManager(ctx.instanceId).startBuild(),
                },
                {
                    name: "open_app",
                    description: "On user request, open ~/Applications/Notess.app.",
                    inputSchema: emptyInput,
                    handler: (ctx) => instanceManager(ctx.instanceId).openApp(),
                },
            ],
            open: async (ctx) => {
                let entry = servers.get(ctx.instanceId);
                if (!entry) {
                    entry = await startServer(await managerFor(ctx.input.repoPath));
                    servers.set(ctx.instanceId, entry);
                }
                return { title: "Notess app manager", url: entry.url };
            },
            onClose: async (ctx) => {
                const entry = servers.get(ctx.instanceId);
                if (entry) {
                    servers.delete(ctx.instanceId);
                    entry.server.closeAllConnections();
                    await new Promise((resolve) => entry.server.close(resolve));
                }
            },
        }),
    ],
});

process.once("SIGTERM", async () => {
    await Promise.all([...managers.values()].map((manager) => manager.shutdown()));
    for (const { server } of servers.values()) server.closeAllConnections();
    process.exit(0);
});
