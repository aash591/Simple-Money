import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";

export type ToolResult = {
	content: { type: "text"; text: string }[];
	isError?: boolean;
};

/** What the phone advertises: its MCP tool definitions and server instructions. */
export type Advertised = { tools: Tool[]; instructions: string };
export type Tool = {
	name: string;
	description?: string;
	inputSchema: unknown;
	annotations?: { readOnlyHint?: boolean };
	[key: string]: unknown;
};

/** Long enough for a tool that reads the whole SMS inbox. */
const CALL_TIMEOUT_MS = 45_000;
const MAX_ADVERTISED_BYTES = 256 * 1024;

export const textResult = (text: string, isError = false): ToolResult => ({
	content: [{ type: "text", text }],
	isError,
});

export const NOT_CONNECTED =
	"SimpleMoney isn't connected right now. Ask the user to open SimpleMoney → More → " +
	"AI assistant and start an AI session, then try again.";

/**
 * One per phone. Holds the phone's WebSocket during an AI session and passes
 * tool calls over it. Stores a hash of the phone's secret, its pairing code
 * and the tools it last advertised; never a question or an answer.
 */
export class Phone extends DurableObject<Env> {
	private pending = new Map<string, { resolve: (r: ToolResult) => void; timer: ReturnType<typeof setTimeout> }>();

	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.blockConcurrencyWhile(async () => {
			const sql = ctx.storage.sql;
			sql.exec("CREATE TABLE IF NOT EXISTS device (secret_hash TEXT NOT NULL, advertised TEXT)");
			sql.exec("CREATE TABLE IF NOT EXISTS pair (code TEXT NOT NULL, expires_at INTEGER NOT NULL)");
			// When each AI app last asked something: an app removed on its own side
			// never says so, so the phone shows how long it has been quiet.
			sql.exec("CREATE TABLE IF NOT EXISTS used (client_id TEXT PRIMARY KEY, at INTEGER NOT NULL)");
		});
		// Keepalives are answered without waking the object.
		ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
	}

	init(secretHash: string): void {
		this.ctx.storage.sql.exec("DELETE FROM device");
		this.ctx.storage.sql.exec("INSERT INTO device (secret_hash) VALUES (?)", secretHash);
	}

	/** False once the phone reset itself, or for an ID that was never registered. */
	exists(): boolean {
		return this.ctx.storage.sql.exec("SELECT 1 FROM device").toArray().length > 0;
	}

	verify(secretHash: string): boolean {
		const row = this.ctx.storage.sql.exec<{ secret_hash: string }>("SELECT secret_hash FROM device").toArray()[0];
		return row !== undefined && timingSafeEqual(row.secret_hash, secretHash);
	}

	async wipe(): Promise<void> {
		for (const ws of this.ctx.getWebSockets()) ws.close(4001, "reset");
		await this.ctx.storage.deleteAll();
	}

	/** Notes that [clientId] used this phone; at most one write a minute. */
	touch(clientId: string): void {
		const now = Date.now();
		const row = this.ctx.storage.sql
			.exec<{ at: number }>("SELECT at FROM used WHERE client_id = ?", clientId)
			.toArray()[0];
		if (row && now - row.at < 60_000) return;
		this.ctx.storage.sql.exec(
			"INSERT INTO used (client_id, at) VALUES (?, ?) ON CONFLICT(client_id) DO UPDATE SET at = excluded.at",
			clientId,
			now,
		);
	}

	/** When each AI app last used this phone, by client ID. */
	lastUsed(): Record<string, number> {
		const out: Record<string, number> = {};
		for (const row of this.ctx.storage.sql.exec<{ client_id: string; at: number }>("SELECT client_id, at FROM used")) {
			out[row.client_id] = row.at;
		}
		return out;
	}

	/** One live code per phone; a new one replaces the old. */
	issuePairCode(code: string, expiresAt: number): void {
		this.ctx.storage.sql.exec("DELETE FROM pair");
		this.ctx.storage.sql.exec("INSERT INTO pair (code, expires_at) VALUES (?, ?)", code, expiresAt);
	}

	/** The phone's code while unused and unexpired, so the app shows a live one. */
	currentPairCode(): { code: string; expiresAt: number } | null {
		const row = this.ctx.storage.sql
			.exec<{ code: string; expires_at: number }>("SELECT code, expires_at FROM pair WHERE expires_at > ?", Date.now())
			.toArray()[0];
		return row ? { code: row.code, expiresAt: row.expires_at } : null;
	}

	/** True for exactly one caller: the object runs one call at a time and the delete is the check. */
	consumePairCode(code: string): boolean {
		return (
			this.ctx.storage.sql
				.exec("DELETE FROM pair WHERE code = ? AND expires_at > ? RETURNING code", code, Date.now())
				.toArray().length > 0
		);
	}

	/** Stores what the phone advertised. Returns why it was refused, or null. */
	advertise(advertised: unknown): string | null {
		const json = JSON.stringify(advertised ?? null);
		if (json.length > MAX_ADVERTISED_BYTES) return "Tool list too large";
		if (!isAdvertised(advertised)) return "Invalid tool list";
		this.ctx.storage.sql.exec("UPDATE device SET advertised = ?", json);
		return null;
	}

	/** As JSON: RPC can't carry the tools' free-form schemas as typed values. */
	advertised(): string | null {
		const row = this.ctx.storage.sql.exec<{ advertised: string | null }>("SELECT advertised FROM device").toArray()[0];
		return row?.advertised ?? null;
	}

	online(): boolean {
		return this.ctx.getWebSockets().some((s) => s.readyState === WebSocket.READY_STATE_OPEN);
	}

	/** The phone's WebSocket upgrade; the Worker has already checked its secret. */
	async fetch(request: Request): Promise<Response> {
		if (request.headers.get("Upgrade") !== "websocket") return new Response("Expected WebSocket", { status: 426 });
		for (const old of this.ctx.getWebSockets()) old.close(4000, "replaced by a newer connection");
		const { 0: client, 1: server } = new WebSocketPair();
		this.ctx.acceptWebSocket(server);
		return new Response(null, { status: 101, webSocket: client });
	}

	async callTool(name: string, args: unknown, client?: string): Promise<ToolResult> {
		// The newest open connection: one being replaced, or closed without the
		// phone saying so, can linger in the list after a reconnect.
		const ws = this.ctx
			.getWebSockets()
			.filter((s) => s.readyState === WebSocket.READY_STATE_OPEN)
			.at(-1);
		const started = Date.now();
		// The tool's name and how it went, never what was asked or answered.
		const log = (outcome: string) => console.log(`call ${name}: ${outcome} in ${Date.now() - started} ms`);
		if (!ws) {
			log("phone offline");
			return textResult(NOT_CONNECTED, true);
		}
		const id = crypto.randomUUID();
		return new Promise<ToolResult>((resolve) => {
			const timer = setTimeout(() => {
				this.pending.delete(id);
				log("no answer");
				// A connection that swallows calls is dead without knowing it: close
				// it, so the phone reconnects and the next try reaches it.
				try {
					ws.close(4100, "no answer");
				} catch {
					// Already closed.
				}
				resolve(
					textResult(
						"SimpleMoney didn't answer in time, so the connection was reset. Try the same call again in a few seconds. If it fails again, ask the user to open SimpleMoney → More → AI assistant and check the session is on.",
						true,
					),
				);
			}, CALL_TIMEOUT_MS);
			this.pending.set(id, {
				resolve: (result) => {
					log(result.isError ? "error" : "ok");
					resolve(result);
				},
				timer,
			});
			try {
				ws.send(JSON.stringify({ type: "call", id, name, arguments: args ?? {}, client }));
			} catch {
				clearTimeout(timer);
				this.pending.delete(id);
				log("send failed");
				resolve(textResult(NOT_CONNECTED, true));
			}
		});
	}

	async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
		if (typeof message !== "string") return;
		let msg: { type?: string; id?: string; result?: unknown; tools?: unknown; instructions?: unknown };
		try {
			msg = JSON.parse(message);
		} catch {
			return;
		}
		if (msg.type === "hello") {
			const refused = this.advertise({ tools: msg.tools, instructions: msg.instructions });
			if (refused) ws.close(4002, refused);
			return;
		}
		if (msg.type !== "result" || !msg.id) return;
		const pending = this.pending.get(msg.id);
		if (!pending) return;
		clearTimeout(pending.timer);
		this.pending.delete(msg.id);
		pending.resolve(isToolResult(msg.result) ? msg.result : textResult("SimpleMoney sent an answer the relay couldn't read.", true));
	}

	async webSocketClose(ws: WebSocket, code: number): Promise<void> {
		try {
			ws.close(code === 1005 ? 1000 : code, "closing");
		} catch {
			// Already closed.
		}
	}
}

function isAdvertised(value: unknown): value is Advertised {
	if (typeof value !== "object" || value === null) return false;
	const { tools, instructions } = value as Advertised;
	return (
		typeof instructions === "string" &&
		Array.isArray(tools) &&
		tools.length <= 64 &&
		tools.every((t) => typeof t === "object" && t !== null && typeof t.name === "string" && typeof t.inputSchema === "object")
	);
}

function isToolResult(value: unknown): value is ToolResult {
	return typeof value === "object" && value !== null && Array.isArray((value as ToolResult).content);
}

function timingSafeEqual(a: string, b: string): boolean {
	if (a.length !== b.length) return false;
	let diff = 0;
	for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
	return diff === 0;
}
