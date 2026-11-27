import type { OAuthHelpers } from "@cloudflare/workers-oauth-provider";
import type { PairCode } from "./pairing";
import type { Phone } from "./phone";

/** The Workers rate limiting binding. */
export interface RateLimit {
	limit(options: { key: string }): Promise<{ success: boolean }>;
}

export interface Env {
	/** OAuth grants and tokens, hashed by the OAuth library. */
	OAUTH_KV: KVNamespace;
	PHONE: DurableObjectNamespace<Phone>;
	PAIR_CODE: DurableObjectNamespace<PairCode>;
	PAIR_LIMIT: RateLimit;
	REGISTER_LIMIT: RateLimit;
	MCP_LIMIT: RateLimit;
	/** This relay's public https origin, without a trailing slash. */
	BASE_URL: string;
}

/** What the OAuth library adds to the environment for the non-API routes. */
export type HelperEnv = Env & { OAUTH_PROVIDER: OAuthHelpers };

/** What a signed-in AI app's token carries. */
export type Props = { deviceId: string; clientName?: string };
