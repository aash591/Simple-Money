// An MCP client's side of the relay: OAuth sign-in with a pairing code
// (dynamic registration, PKCE) and JSON-RPC calls to /mcp.
import assert from "node:assert/strict";
import { createHash, randomBytes } from "node:crypto";

const REDIRECT = "http://localhost:9999/callback";
const b64url = (buf) => buf.toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");

/** Signs in like an MCP client and returns its access token. */
export async function signIn(BASE, code, { write = true, name = "E2E client" } = {}) {
	const resource = await (await fetch(`${BASE}/.well-known/oauth-protected-resource/mcp`)).json();
	const server = await (await fetch(`${resource.authorization_servers[0]}/.well-known/oauth-authorization-server`)).json();
	const client = await (
		await fetch(server.registration_endpoint, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({ redirect_uris: [REDIRECT], client_name: name, token_endpoint_auth_method: "none" }),
		})
	).json();
	const verifier = b64url(randomBytes(32));
	const challenge = b64url(createHash("sha256").update(verifier).digest());
	const authorizeUrl = new URL(server.authorization_endpoint);
	for (const [k, v] of Object.entries({
		response_type: "code",
		client_id: client.client_id,
		redirect_uri: REDIRECT,
		code_challenge: challenge,
		code_challenge_method: "S256",
		state: "s1",
		scope: "read write",
		resource: resource.resource,
	}))
		authorizeUrl.searchParams.set(k, v);
	const pageRes = await fetch(authorizeUrl, { redirect: "manual" });
	assert.equal(pageRes.status, 200, await pageRes.clone().text());
	// Phone apps get the result through an app link, which form-action would block.
	assert.doesNotMatch(pageRes.headers.get("Content-Security-Policy") ?? "", /form-action/);
	const page = await pageRes.text();
	assert.match(page, new RegExp(`Connect ${name} to SimpleMoney`));
	const handle = page.match(/name="handle" value="([^"]+)"/)[1];
	const cookie = pageRes.headers.getSetCookie().map((c) => c.split(";")[0]).join("; ");

	const submit = (pairing) =>
		fetch(`${BASE}/authorize`, {
			method: "POST",
			redirect: "manual",
			headers: { "Content-Type": "application/x-www-form-urlencoded", Cookie: cookie },
			body: new URLSearchParams({ handle, code: pairing, decision: "approve", client: name, ...(write ? { write: "on" } : {}) }),
		});
	const wrong = await submit(code === "000000" ? "111111" : "000000");
	assert.equal(wrong.status, 400);
	assert.match(await wrong.text(), /didn’t work/);
	const ok = await submit(code);
	assert.equal(ok.status, 302, await ok.clone().text());
	const back = new URL(ok.headers.get("Location"));
	assert.equal(back.searchParams.get("state"), "s1");
	// A second tap on Connect goes where the first one did.
	const again = await submit(code);
	assert.equal(again.status, 302);
	assert.equal(again.headers.get("Location"), ok.headers.get("Location"));

	const token = await (
		await fetch(server.token_endpoint, {
			method: "POST",
			headers: { "Content-Type": "application/x-www-form-urlencoded" },
			body: new URLSearchParams({
				grant_type: "authorization_code",
				code: back.searchParams.get("code"),
				redirect_uri: REDIRECT,
				client_id: client.client_id,
				code_verifier: verifier,
				resource: resource.resource,
			}),
		})
	).json();
	assert.ok(token.access_token, JSON.stringify(token));
	return token.access_token;
}

let rpcId = 0;
export async function rpc(BASE, token, method, params = {}) {
	const res = await fetch(`${BASE}/mcp`, {
		method: "POST",
		headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
		body: JSON.stringify({ jsonrpc: "2.0", id: ++rpcId, method, params }),
	});
	return { status: res.status, body: res.status === 200 ? await res.json() : await res.text() };
}
