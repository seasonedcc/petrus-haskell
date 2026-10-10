#!/usr/bin/env node
/**
 * Node's best case for the viewer backend: a bare http server with the
 * upstream open-file / resolve-ref endpoint (server/openFileEndpoint.mjs,
 * unchanged) and the agent relay as upstream tests extract it from
 * vite.config.ts (tests/bridgeVitePlugin.test.mjs: same routing, no
 * relay-perf logging, no Vite middleware stack in front).
 *
 * Usage: node bench/node-baseline.mjs <petrus-viewer dir> <port>
 */
import http from "node:http";
import path from "node:path";
import { createRequire } from "node:module";
import { pathToFileURL } from "node:url";

const [viewer, portArg] = process.argv.slice(2);
const require = createRequire(path.join(viewer, "package.json"));
const { WebSocketServer } = require("ws");
const { attachOpenFileEndpoint } = await import(pathToFileURL(path.join(viewer, "server/openFileEndpoint.mjs")).href);

function attachBridgeRelay(httpServer) {
  const wss = new WebSocketServer({ noServer: true });
  let nextId = 1;
  const clients = new Map();
  function broadcastClientCount() {
    const msg = JSON.stringify({ type: "client_count", count: clients.size });
    for (const [client] of clients) if (client.readyState === 1) client.send(msg);
  }
  wss.on("connection", (ws) => {
    const clientId = String(nextId++);
    clients.set(ws, clientId);
    ws.send(JSON.stringify({ type: "welcome", clientId }));
    broadcastClientCount();
    ws.on("message", (raw) => {
      let msg;
      try { msg = JSON.parse(String(raw)); } catch { return; }
      if (typeof msg !== "object" || msg === null || Array.isArray(msg)) return;
      msg.clientId = clientId;
      const out = JSON.stringify(msg);
      if (msg.targetClientId) {
        for (const [client, id] of clients) {
          if (id === msg.targetClientId && client.readyState === 1) { client.send(out); break; }
        }
        return;
      }
      for (const [client] of clients) if (client !== ws && client.readyState === 1) client.send(out);
    });
    ws.on("error", () => {});
    ws.on("close", () => {
      clients.delete(ws);
      const out = JSON.stringify({ type: "leave", clientId });
      for (const [client] of clients) if (client.readyState === 1) client.send(out);
      broadcastClientCount();
    });
  });
  httpServer.on("upgrade", (req, socket, head) => {
    if (req.url === "/ws/agent") wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
    else socket.destroy();
  });
}

const server = http.createServer((req, res) => {
  // the endpoint middleware handles its routes first, like under Vite
  res.statusCode = 404;
  res.end("Not Found");
});
attachOpenFileEndpoint(server, null, null);
attachBridgeRelay(server);
server.listen(Number(portArg), "127.0.0.1", () => console.log(`node-baseline listening on ${portArg}`));
