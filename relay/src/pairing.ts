import { DurableObject } from "cloudflare:workers";
import type { Env } from "./env";

/** What [PairCode.take] gives the sign-in page. */
export type Taken = {
	deviceId: string;
	/** True only for the page's first submit: it must finish the sign-in. */
	first: boolean;
	/** Set once the sign-in finished: where to send the browser. */
	redirectTo: string | null;
};

/**
 * One per pairing code: which phone holds it, until it expires. A Durable
 * Object, not KV, because the code is looked up seconds after it is written,
 * often from the same place, and KV may answer that from a stale cache.
 *
 * It also remembers which sign-in page took the code and where that sign-in
 * sent the browser. Phones are slow to answer, so people tap Connect twice;
 * the second tap gets the same answer instead of "That code didn't work".
 */
export class PairCode extends DurableObject<Env> {
	constructor(ctx: DurableObjectState, env: Env) {
		super(ctx, env);
		ctx.storage.sql.exec("CREATE TABLE IF NOT EXISTS code (device_id TEXT NOT NULL, expires_at INTEGER NOT NULL)");
		ctx.storage.sql.exec(
			"CREATE TABLE IF NOT EXISTS taken (handle TEXT PRIMARY KEY, device_id TEXT NOT NULL, redirect_to TEXT)",
		);
	}

	/** Gives this code to [deviceId]. False if another phone holds it. */
	async claim(deviceId: string, expiresAt: number): Promise<boolean> {
		const holder = this.holder();
		if (holder !== null && holder !== deviceId) return false;
		this.ctx.storage.sql.exec("DELETE FROM code");
		this.ctx.storage.sql.exec("INSERT INTO code (device_id, expires_at) VALUES (?, ?)", deviceId, expiresAt);
		await this.ctx.storage.setAlarm(expiresAt);
		return true;
	}

	/** The phone holding this code, or null once it's expired or taken. */
	holder(): string | null {
		const row = this.ctx.storage.sql
			.exec<{ device_id: string }>("SELECT device_id FROM code WHERE expires_at > ?", Date.now())
			.toArray()[0];
		return row?.device_id ?? null;
	}

	/**
	 * Takes the code for the sign-in page [handle]. The first call from a page
	 * takes it; later calls from the same page see that sign-in again. Null
	 * for any other page, or once the code has expired.
	 */
	take(handle: string): Taken | null {
		const seen = this.ctx.storage.sql
			.exec<{ device_id: string; redirect_to: string | null }>(
				"SELECT device_id, redirect_to FROM taken WHERE handle = ?",
				handle,
			)
			.toArray()[0];
		if (seen) return { deviceId: seen.device_id, first: false, redirectTo: seen.redirect_to };
		const deviceId = this.holder();
		if (deviceId === null) return null;
		this.ctx.storage.sql.exec("DELETE FROM code");
		this.ctx.storage.sql.exec("INSERT INTO taken (handle, device_id) VALUES (?, ?)", handle, deviceId);
		return { deviceId, first: true, redirectTo: null };
	}

	/** The sign-in by [handle] finished: later taps go to [redirectTo]. */
	finish(handle: string, redirectTo: string): void {
		this.ctx.storage.sql.exec("UPDATE taken SET redirect_to = ? WHERE handle = ?", redirectTo, handle);
	}

	/** Where the sign-in by [handle] sent the browser, once it finished. */
	result(handle: string): string | null {
		const row = this.ctx.storage.sql
			.exec<{ redirect_to: string | null }>("SELECT redirect_to FROM taken WHERE handle = ?", handle)
			.toArray()[0];
		return row?.redirect_to ?? null;
	}

	/** Expired: forget it entirely. */
	async alarm(): Promise<void> {
		await this.ctx.storage.deleteAll();
	}
}

export const pairCodeFor = (env: Env, code: string) => env.PAIR_CODE.get(env.PAIR_CODE.idFromName(code));
