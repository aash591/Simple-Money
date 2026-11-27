// End-to-end check of a running relay (`npm run dev`, then `npm test`).
// Plays both sides: a phone on the WebSocket, and an MCP client that signs in
// with OAuth (dynamic registration, PKCE, pairing code) and calls tools.
import assert from "node:assert/strict";
import WebSocket from "ws";
import { rpc as call, signIn as login } from "./client.mjs";

const BASE = process.argv[2] ?? "http://localhost:8787";

const tools = [
	{ name: "list_accounts", description: "Accounts", inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: true } },
	{ name: "suggest_transaction_edits", description: "Suggest", inputSchema: { type: "object", properties: {} }, annotations: { readOnlyHint: false } },
];

const step = (name) => console.log(`✓ ${name}`);

async function registerPhone() {
	const res = await fetch(`${BASE}/device`, { method: "POST" });
	assert.equal(res.status, 201);
	const { deviceId, secret } = await res.json();
	return { deviceId, auth: `Device ${deviceId}.${secret}` };
}

async function pair(phone) {
	const res = await fetch(`${BASE}/device/pair`, {
		method: "POST",
		headers: { Authorization: phone.auth, "Content-Type": "application/json" },
		body: JSON.stringify({ tools, instructions: "Test instructions" }),
	});
	assert.equal(res.status, 200, await res.clone().text());
	return (await res.json()).code;
}

/** A phone answering every call with the tool's name and arguments. */
function connectPhone(phone) {
	return new Promise((resolve, reject) => {
		const ws = new WebSocket(`${BASE.replace(/^http/, "ws")}/device/connect`, { headers: { Authorization: phone.auth } });
		ws.on("open", () => {
			ws.send(JSON.stringify({ type: "hello", tools, instructions: "Test instructions" }));
			resolve(ws);
		});
		ws.on("message", (data) => {
			const msg = JSON.parse(String(data));
			if (msg.type !== "call") return;
			ws.send(
				JSON.stringify({
					type: "result",
					id: msg.id,
					result: { content: [{ type: "text", text: JSON.stringify({ tool: msg.name, args: msg.arguments }) }], isError: false },
				}),
			);
		});
		ws.on("error", reject);
	});
}

const signIn = (code, options) => login(BASE, code, options);
const rpc = (token, method, params) => call(BASE, token, method, params);
const text = (r) => r.body.result.content[0].text;

const phone = await registerPhone();
step("phone registers");

const unauthorized = await fetch(`${BASE}/device/pair`, { method: "POST", headers: { Authorization: `Device ${"0".repeat(32)}.${"A".repeat(43)}` } });
assert.equal(unauthorized.status, 401);
step("an unknown phone is refused");

const code = await pair(phone);
const live = () => fetch(`${BASE}/device/pair`, { headers: { Authorization: phone.auth } }).then((r) => r.json());
assert.equal((await live()).code, code);
const kept = await fetch(`${BASE}/device/pair?keep=${code}`, {
	method: "POST",
	headers: { Authorization: phone.auth, "Content-Type": "application/json" },
	body: JSON.stringify({ tools, instructions: "Test instructions" }),
});
assert.equal((await kept.json()).code, code);
step("the phone can check its code, and keep it while it's live");

const token = await signIn(code);
assert.equal((await live()).code, null);
step("an AI app signs in with a pairing code (a wrong code is refused, a second tap is fine)");

const init = await rpc(token, "initialize", { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "e2e", version: "1" } });
assert.equal(init.body.result.protocolVersion, "2025-06-18");
assert.equal(init.body.result.instructions, "Test instructions");
const listed = await rpc(token, "tools/list");
assert.deepEqual(listed.body.result.tools.map((t) => t.name), ["list_accounts", "suggest_transaction_edits"]);
step("initialize and tools/list use what the phone advertised");

const offline = await rpc(token, "tools/call", { name: "list_accounts", arguments: {} });
assert.equal(offline.body.result.isError, true);
assert.match(text(offline), /isn't connected/);
step("with no AI session, a tool says how to start one");

const ws = await connectPhone(phone);
const answered = await rpc(token, "tools/call", { name: "list_accounts", arguments: { include_archived: true } });
assert.deepEqual(JSON.parse(text(answered)), { tool: "list_accounts", args: { include_archived: true } });
step("during a session, the phone answers tool calls");

const unknown = await rpc(token, "tools/call", { name: "drop_tables", arguments: {} });
assert.equal(unknown.body.error.code, -32602);
step("a tool the phone didn't advertise is refused");

const readOnly = await signIn(await pair(phone), { write: false, name: "Read only" });
const readTools = await rpc(readOnly, "tools/list");
assert.deepEqual(readTools.body.result.tools.map((t) => t.name), ["list_accounts"]);
const refused = await rpc(readOnly, "tools/call", { name: "suggest_transaction_edits", arguments: {} });
assert.equal(refused.body.result.isError, true);
step("a read-only connection can't see or call suggestion tools");

const connections = await (await fetch(`${BASE}/device/connections`, { headers: { Authorization: phone.auth } })).json();
assert.equal(connections.connections.length, 2);
const readGrant = connections.connections.find((c) => c.clientName === "Read only");
// It answered tool calls, so it shows when; the read-only one only listed tools.
assert.equal(typeof connections.connections.find((c) => c.clientName === "E2E client").lastUsedAt, "number");
assert.equal(readGrant.canSuggest, false);
await fetch(`${BASE}/device/connections/${readGrant.id}`, { method: "DELETE", headers: { Authorization: phone.auth } });
assert.equal((await rpc(readOnly, "tools/list")).status, 401);
step("the phone lists its connections and can disconnect one");

ws.close();
await fetch(`${BASE}/device`, { method: "DELETE", headers: { Authorization: phone.auth } });
assert.equal((await rpc(token, "tools/list")).status, 401);
step("resetting the phone signs every AI app out");

console.log("\nAll relay checks passed.");
process.exit(0);
