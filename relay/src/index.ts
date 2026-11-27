import { AuthorizationError, OAuthProvider, type OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { Env, HelperEnv, Props } from "./env";
import { mcpHandler, phoneFor } from "./mcp";
import { pairCodeFor } from "./pairing";
import { authorizePage, messagePage } from "./pages";

export { PairCode } from "./pairing";
export { Phone } from "./phone";

// Long enough to switch apps and back; a code still works only once.
const PAIR_TTL_SECONDS = 600;

/** Phone registration, pairing, its WebSocket, its connections; and the sign-in page. */
const defaultHandler = {
	async fetch(request: Request, env: HelperEnv, ctx: ExecutionContext): Promise<Response> {
		const url = new URL(request.url);
		const path = url.pathname;
		const oauth = env.OAUTH_PROVIDER;

		if (path === "/authorize") return authorize(request, env, oauth, ctx);

		if (path === "/device" && request.method === "POST") {
			if (!(await env.REGISTER_LIMIT.limit({ key: clientIp(request) })).success) return json({ error: "rate_limited" }, 429);
			const deviceId = randomHex(16);
			const secret = randomBase64Url(32);
			await phoneFor(env, deviceId).init(await sha256(secret));
			return json({ deviceId, secret }, 201);
		}

		if (path.startsWith("/device")) {
			const deviceId = await authenticateDevice(request, env);
			if (!deviceId) return json({ error: "unauthorized" }, 401);
			const phone = phoneFor(env, deviceId);

			if (path === "/device" && request.method === "DELETE") {
				for (const grant of await allGrants(oauth, deviceId)) await oauth.revokeGrant(grant.id, deviceId);
				await phone.wipe();
				return new Response(null, { status: 204 });
			}
			if (path === "/device/connect") return phone.fetch(request);
			if (path === "/device/pair" && request.method === "GET") {
				// Whether the code the app shows is still live: an AI app may have used it.
				const current = await phone.currentPairCode();
				return json(current ? { code: current.code, expiresIn: secondsLeft(current.expiresAt) } : { code: null });
			}
			if (path === "/device/pair" && request.method === "POST") {
				// The phone sends its tools with the request, so a new AI app sees them before the first session.
				const refused = await phone.advertise(await request.json().catch(() => null));
				if (refused) return json({ error: refused }, 400);
				// ?keep=<code>: the code the app shows, kept while it has a minute left.
				// Replacing it would break a copy the user already pasted somewhere.
				const current = await phone.currentPairCode();
				if (current && current.code === url.searchParams.get("keep") && secondsLeft(current.expiresAt) >= 60) {
					return json({ code: current.code, expiresIn: secondsLeft(current.expiresAt) });
				}
				return json({ code: await newPairingCode(env, deviceId), expiresIn: PAIR_TTL_SECONDS });
			}
			if (path === "/device/connections" && request.method === "GET") {
				const used = await phone.lastUsed();
				return json({
					connections: (await allGrants(oauth, deviceId)).map((g) => ({
						id: g.id,
						clientName: (g.metadata as { clientName?: string } | null)?.clientName ?? "AI app",
						canSuggest: g.scope.includes("write"),
						createdAt: g.createdAt,
						lastUsedAt: used[g.clientId] ?? null,
					})),
				});
			}
			const revoke = path.match(/^\/device\/connections\/([A-Za-z0-9_-]+)$/);
			if (revoke && request.method === "DELETE") {
				await oauth.revokeGrant(revoke[1], deviceId);
				return new Response(null, { status: 204 });
			}
		}

		if (path === "/") return new Response("SimpleMoney AI relay. Passes questions to your phone; stores none of them.\n");
		return new Response("Not found", { status: 404 });
	},
};

async function authorize(request: Request, env: Env, oauth: OAuthHelpers, ctx: ExecutionContext): Promise<Response> {
	try {
		if (request.method === "GET") {
			const authRequest = await oauth.parseAuthRequest(request);
			const details = await oauth.describeConsent(authRequest);
			const consent = await oauth.beginConsent(authRequest);
			return html((nonce) => authorizePage(details.clientName, consent.handle, nonce), consent.headers);
		}
		if (request.method !== "POST") return new Response(null, { status: 405 });

		const form = await request.formData();
		const handle = String(form.get("handle") ?? "");
		if (form.get("decision") !== "approve") {
			const denied = await oauth.denyConsent(request, handle);
			return redirect(denied.redirectTo, denied.headers);
		}
		// The handle stays unused until approval, so the same page can try again.
		const retry = async (error: string, status = 400) => {
			const client = await clientNameForHandle(form);
			return html((nonce) => authorizePage(client, handle, nonce, error), new Headers(), status);
		};
		if (!(await env.PAIR_LIMIT.limit({ key: clientIp(request) })).success) {
			return retry("Too many attempts. Wait a minute, then try again.", 429);
		}
		const code = String(form.get("code") ?? "").trim();
		const badCode =
			"That code didn’t work. In SimpleMoney, tap the code to copy it, then paste it here. A code lasts 10 minutes.";
		if (!/^\d{6}$/.test(code)) return retry(badCode);
		const pairing = pairCodeFor(env, code);
		const taken = await pairing.take(handle);
		if (!taken) {
			console.log("authorize: code refused");
			return retry(badCode);
		}
		if (!taken.first) {
			// A second tap from the same page: send it where the first one went.
			const redirectTo = taken.redirectTo ?? (await waitForResult(pairing, handle));
			console.log(`authorize: repeat tap, ${redirectTo ? "redirected" : "still pending"}`);
			if (redirectTo) return redirect(redirectTo, new Headers());
			return messagePage("Almost there", "Still connecting. Wait a moment, then go back to your AI app.", 202);
		}
		// Runs to the end even if the browser gives up on this request, so the
		// sign-in is never left half done.
		const work = (async () => {
			// The phone's object decides: a newer code from the phone replaces this one.
			if (!(await phoneFor(env, taken.deviceId).consumePairCode(code))) return null;
			const scope = form.get("write") === "on" ? ["read", "write"] : ["read"];
			const approved = await oauth.approveConsent(request, handle, { scope });
			const client = await oauth.lookupClient(approved.request.clientId);
			const { redirectTo } = await oauth.completeAuthorization({
				request: approved.request,
				userId: taken.deviceId,
				metadata: { clientName: client?.clientName ?? "AI app" },
				scope,
				props: { deviceId: taken.deviceId, clientName: client?.clientName ?? "AI app" } satisfies Props,
			});
			await pairing.finish(handle, redirectTo);
			return { redirectTo, headers: approved.headers };
		})();
		ctx.waitUntil(work.catch(() => {}));
		const done = await work;
		console.log(`authorize: ${done ? "signed in" : "code replaced by a newer one"}`);
		if (!done) return retry(badCode);
		return redirect(done.redirectTo, done.headers);
	} catch (error) {
		if (error instanceof AuthorizationError && error.redirectTo) return Response.redirect(error.redirectTo, 302);
		if (error instanceof AuthorizationError) return messagePage("Can’t connect", error.description ?? "This sign-in request isn’t valid.");
		throw error;
	}
}

const secondsLeft = (expiresAt: number) => Math.max(0, Math.floor((expiresAt - Date.now()) / 1000));

/** Waits up to 8 s for the first tap's sign-in to finish. */
async function waitForResult(pairing: ReturnType<typeof pairCodeFor>, handle: string): Promise<string | null> {
	for (let i = 0; i < 16; i++) {
		await new Promise((r) => setTimeout(r, 500));
		const redirectTo = await pairing.result(handle);
		if (redirectTo) return redirectTo;
	}
	return null;
}

/** The name the page showed, for showing it again on a retry. Display only. */
async function clientNameForHandle(form: FormData): Promise<string> {
	return String(form.get("client") ?? "your AI app").slice(0, 80);
}

async function newPairingCode(env: Env, deviceId: string): Promise<string> {
	for (;;) {
		const code = (crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000).toString().padStart(6, "0");
		const expiresAt = Date.now() + PAIR_TTL_SECONDS * 1000;
		if (!(await pairCodeFor(env, code).claim(deviceId, expiresAt))) continue;
		await phoneFor(env, deviceId).issuePairCode(code, expiresAt);
		return code;
	}
}

/** `Authorization: Device <deviceId>.<secret>` */
async function authenticateDevice(request: Request, env: Env): Promise<string | null> {
	const m = (request.headers.get("Authorization") ?? "").match(/^Device ([0-9a-f]{32})\.([A-Za-z0-9_-]{43})$/);
	if (!m) return null;
	return (await phoneFor(env, m[1]).verify(await sha256(m[2]))) ? m[1] : null;
}

async function allGrants(oauth: OAuthHelpers, userId: string) {
	const out = [];
	let cursor: string | undefined;
	do {
		const page = await oauth.listUserGrants(userId, { cursor });
		out.push(...page.items);
		cursor = page.cursor;
	} while (cursor);
	return out;
}

const json = (body: unknown, status = 200) => Response.json(body, { status });
/** [page] gets a fresh nonce for its one script. */
const html = (page: (nonce: string) => string, headers: Headers, status = 200) => {
	const nonce = randomBase64Url(16);
	headers.set("Content-Type", "text/html; charset=utf-8");
	headers.set("X-Frame-Options", "DENY");
	// No form-action: after Connect the browser follows a redirect to the AI
	// app's registered callback, which may be an app link rather than https.
	headers.set(
		"Content-Security-Policy",
		`default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-${nonce}'; frame-ancestors 'none'`,
	);
	return new Response(page(nonce), { status, headers });
};
const redirect = (location: string, headers: Headers) => {
	headers.set("Location", location);
	return new Response(null, { status: 302, headers });
};
const clientIp = (r: Request) => r.headers.get("CF-Connecting-IP") ?? "local";

async function sha256(s: string): Promise<string> {
	const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s));
	return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
const randomHex = (n: number) =>
	[...crypto.getRandomValues(new Uint8Array(n))].map((b) => b.toString(16).padStart(2, "0")).join("");
const randomBase64Url = (n: number) =>
	btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(n))))
		.replace(/\+/g, "-")
		.replace(/\//g, "_")
		.replace(/=+$/, "");

// Built on the first request, because the public origin comes from env.
let provider: OAuthProvider<Env> | undefined;
export default {
	fetch(request: Request, env: Env, ctx: ExecutionContext): Promise<Response> {
		provider ??= new OAuthProvider<Env>({
			apiRoute: "/mcp",
			apiHandler: mcpHandler as never,
			defaultHandler: defaultHandler as never,
			authorizeEndpoint: "/authorize",
			tokenEndpoint: "/oauth/token",
			clientRegistrationEndpoint: "/oauth/register",
			clientIdMetadataDocumentEnabled: true,
			scopesSupported: ["read", "write", "offline_access"],
			requiredScopes: ["read"],
			resourceMetadata: { resource: `${env.BASE_URL}/mcp`, authorization_servers: [env.BASE_URL], resource_name: "SimpleMoney" },
			accessTokenTTL: 60 * 60,
			refreshTokenTTL: 365 * 24 * 60 * 60,
			// An app removed on its own side stops refreshing, and drops off a month later.
			refreshTokenIdleTTL: 30 * 24 * 60 * 60,
		});
		return provider.fetch(request, env, ctx);
	},
} satisfies ExportedHandler<Env>;
