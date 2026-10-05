#!/bin/sh
# Checks that `ht browser-mcp` starts chrome-devtools-mcp only on the first tool call, once for
# concurrent calls, again after it exits, and fails cleanly without npx. Kuronami is replaced by a
# fake control socket; no browser runs, so tool calls end in chrome-devtools-mcp's own error.
# usage: scripts/test-browser-mcp.sh [path/to/ht]
set -e
cd "$(dirname "$0")/.."
ht=${1:-build/DerivedData/Build/Products/Debug/ht}
[ -x "$ht" ] || { echo "no ht at $ht (build first)" >&2; exit 1; }
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

HT="$ht" SOCK="$scratch/control.sock" node -e '
const { spawn, execSync } = require("child_process");
const net = require("net");
const assert = require("assert");

let controlRequests = 0;
net.createServer((socket) => socket.once("data", () => {
  controlRequests++;
  socket.end(JSON.stringify({ ok: true, text: "alpha", endpoint: "http://127.0.0.1:9" }) + "\n");
})).listen(process.env.SOCK);

const children = (pid) => {
  try { return execSync("pgrep -P " + pid).toString().trim().split("\n").map(Number); } catch { return []; }
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function start(env) {
  const proc = spawn(process.env.HT, ["browser-mcp", "9"], {
    env: { ...process.env, HT_SOCKET: process.env.SOCK, ...env }, stdio: ["pipe", "pipe", "ignore"] });
  const waiting = {};
  let buffer = "";
  proc.stdout.on("data", (chunk) => {
    buffer += chunk;
    let newline;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const message = JSON.parse(buffer.slice(0, newline));
      buffer = buffer.slice(newline + 1);
      if (message.id !== undefined && waiting[message.id]) waiting[message.id](message);
    }
  });
  const call = (id, method, params) => {
    const reply = new Promise((resolve) => { waiting[id] = resolve; });
    proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
    return reply;
  };
  const notify = (method) => proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", method }) + "\n");
  return { proc, call, notify };
}

const timeout = (promise, ms, what) =>
  Promise.race([promise, sleep(ms).then(() => { throw new Error("timed out: " + what); })]);
const snapshot = { name: "take_snapshot", arguments: {} };

(async () => {
  const { proc, call, notify } = start({});
  const init = await timeout(call(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {},
    clientInfo: { name: "test", version: "1" } }), 5000, "initialize");
  assert.equal(init.result.protocolVersion, "2025-06-18");
  assert.equal(init.result.serverInfo.name, "chrome_devtools");
  assert.match(init.result.instructions, /Kuronami/);
  notify("notifications/initialized");
  const list = await timeout(call(2, "tools/list", {}), 5000, "tools/list");
  const tools = list.result.tools;
  assert.ok(tools.length > 20, "tools listed");
  assert.ok(!tools.some((t) => t.name === "new_page" || t.name === "close_page"), "new_page/close_page hidden");
  const click = tools.find((t) => t.name === "click");
  assert.ok(!(click.inputSchema.required || []).includes("pageId"), "pageId optional");
  assert.equal((await timeout(call(3, "ping", {}), 5000, "ping")).result !== undefined, true);
  await sleep(500);
  assert.deepEqual(children(proc.pid), [], "no server before the first tool call");
  assert.equal(controlRequests, 0, "no browser before the first tool call");
  console.log("ok: handshake and tools/list without a server");

  // Two calls at once: one server, and both answered.
  const [a, b] = await timeout(Promise.all([call(4, "tools/call", snapshot), call(5, "tools/call", snapshot)]),
    180000, "first tool calls");
  assert.ok(a.result || a.error, "first call answered");
  assert.ok(b.result || b.error, "second call answered");
  const first = children(proc.pid);
  assert.equal(first.length, 1, "exactly one server: " + first);
  console.log("ok: concurrent first calls start one server (pid " + first[0] + ")");

  // The server exits: the next call starts another.
  execSync("pkill -TERM -P " + first[0] + " || true; kill " + first[0]);
  await sleep(1000);
  assert.deepEqual(children(proc.pid), [], "server gone");
  const again = await timeout(call(6, "tools/call", snapshot), 60000, "call after exit");
  assert.ok(again.result || again.error, "call after exit answered");
  const second = children(proc.pid);
  assert.equal(second.length, 1, "one new server");
  assert.notEqual(second[0], first[0], "a new server");
  console.log("ok: a call after the server exits restarts it (pid " + second[0] + ")");
  proc.stdin.end();
  await timeout(new Promise((r) => proc.on("exit", r)), 10000, "exit on EOF");

  // No npx: a JSON-RPC error, not a hang or a crash.
  const broken = start({ PATH: "/var/empty" });
  await timeout(broken.call(1, "initialize", { protocolVersion: "2025-06-18", capabilities: {},
    clientInfo: { name: "test", version: "1" } }), 5000, "initialize");
  broken.notify("notifications/initialized");
  const failed = await timeout(broken.call(2, "tools/call", snapshot), 10000, "call without npx");
  assert.equal(failed.error.code, -32603);
  console.log("ok: without npx the call fails with a JSON-RPC error");
  broken.proc.kill();
  process.exit(0);
})().catch((error) => { console.error("FAIL:", error.message); process.exit(1); });
'
