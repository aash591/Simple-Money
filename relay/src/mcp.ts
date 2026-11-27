import type { Env, Props } from "./env";
import { textResult, type Advertised, type Tool } from "./phone";

/** Newest first; an unknown requested version gets the newest. */
const PROTOCOL_VERSIONS = ["2025-11-25", "2025-06-18", "2025-03-26"];

const FALLBACK_INSTRUCTIONS =
	"SimpleMoney is the user's money manager, answered live by their phone. " +
	"If a tool says SimpleMoney isn't connected, tell the user how to connect and stop.";

type Auth = { scope: string[]; clientId?: string };
type Ctx = ExecutionContext & { props: Props; auth?: Auth };

export const phoneFor = (env: Env, deviceId: string) => env.PHONE.get(env.PHONE.idFromName(deviceId));

/** The tools and instructions the phone last advertised. */
async function advertised(phone: ReturnType<typeof phoneFor>): Promise<Advertised | null> {
	const json = await phone.advertised();
	return json ? (JSON.parse(json) as Advertised) : null;
}

/** Suggestion tools need the write scope; reading tools need only read. */
const allowed = (tool: Tool, auth: Auth | undefined) =>
	tool.annotations?.readOnlyHint === true || (auth?.scope ?? []).includes("write");

/**
 * MCP over Streamable HTTP, stateless, JSON responses only. Every request
 * here carries a valid OAuth token; the OAuth library checked it.
 */
export const mcpHandler = {
	async fetch(request: Request, env: Env, ctx: Ctx): Promise<Response> {
		// No server-initiated stream: GET is refused so clients don't wait on one.
		if (request.method !== "POST") return new Response(null, { status: 405, headers: { Allow: "POST" } });
		const { deviceId } = ctx.props;
		if (!(await env.MCP_LIMIT.limit({ key: deviceId })).success) {
			return rpcError(null, -32000, "Too many requests. Wait a moment.", 429);
		}
		const phone = phoneFor(env, deviceId);
		// A phone that reset itself never answers again: send the AI app back to sign-in.
		if (!(await phone.exists())) return signInAgain(request);
		if (ctx.auth?.clientId) ctx.waitUntil(phone.touch(ctx.auth.clientId));

		let msg: { id?: string | number | null; method?: string; params?: Record<string, unknown> };
		try {
			msg = await request.json();
		} catch {
			return rpcError(null, -32700, "Parse error");
		}
		if (Array.isArray(msg) || typeof msg !== "object" || msg === null) return rpcError(null, -32600, "Invalid request");
		const { id, method, params = {} } = msg;
		if (id === undefined) return new Response(null, { status: 202 }); // A notification.

		switch (method) {
			case "initialize": {
				const asked = String(params.protocolVersion ?? "");
				return rpcResult(id, {
					protocolVersion: PROTOCOL_VERSIONS.includes(asked) ? asked : PROTOCOL_VERSIONS[0],
					capabilities: { tools: { listChanged: false } },
					serverInfo: { name: "simplemoney", title: "SimpleMoney", version: "1.0.0" },
					instructions: (await advertised(phone))?.instructions ?? FALLBACK_INSTRUCTIONS,
				});
			}
			case "ping":
				return rpcResult(id, {});
			case "tools/list": {
				const tools = (await advertised(phone))?.tools ?? [];
				return rpcResult(id, { tools: tools.filter((t) => allowed(t, ctx.auth)) });
			}
			case "tools/call": {
				const name = String(params.name ?? "");
				const tool = (await advertised(phone))?.tools.find((t) => t.name === name);
				if (!tool) return rpcError(id, -32602, `Unknown tool: ${name}`);
				if (!allowed(tool, ctx.auth)) {
					return rpcResult(
						id,
						textResult(
							"This connection may only read. To let it suggest changes, remove the SimpleMoney connector and add it again, leaving “Allow suggestions” on.",
							true,
						),
					);
				}
				return rpcResult(id, await phone.callTool(name, params.arguments ?? {}, ctx.props.clientName));
			}
			default:
				return rpcError(id, -32601, `Method not found: ${method}`);
		}
	},
};

/** The 401 an expired token gets, which makes an MCP client sign in again. */
function signInAgain(request: Request): Response {
	const metadata = `${new URL(request.url).origin}/.well-known/oauth-protected-resource/mcp`;
	return new Response(
		JSON.stringify({ error: "invalid_token", error_description: "This phone is no longer linked. Sign in again with a pairing code." }),
		{
			status: 401,
			headers: {
				"Content-Type": "application/json",
				"Cache-Control": "no-store",
				"WWW-Authenticate": `Bearer realm="OAuth", resource_metadata="${metadata}", error="invalid_token"`,
			},
		},
	);
}

const rpcResult = (id: string | number | null, result: unknown) => Response.json({ jsonrpc: "2.0", id, result });
const rpcError = (id: string | number | null, code: number, message: string, status = 200) =>
	Response.json({ jsonrpc: "2.0", id, error: { code, message } }, { status });
