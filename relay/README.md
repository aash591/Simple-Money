# SimpleMoney AI relay

A Cloudflare Worker that lets Claude, ChatGPT and other MCP apps ask a
user's phone about their SimpleMoney data. Their data stays on the phone.

```
Claude / ChatGPT ──https + OAuth──▶ this Worker (/mcp) ──WebSocket──▶ phone
```

- During an **AI session** (started by the user, 15–60 minutes), the phone
  keeps a WebSocket open to the relay. The Worker passes each tool call to the
  phone and returns its answer. It stores and logs neither.
- An AI app signs in with a **6-digit pairing code** from the app (More → AI
  assistant). Codes last 10 minutes and work once. The user decides whether
  the app may only read or may also make suggestions (OAuth scopes `read` and
  `write`).
- The **phone advertises its own tools**, when it pairs and each time it
  connects. A new app version can add tools without redeploying the relay.
- What the relay stores: a random ID per phone, a hash of the phone's secret,
  the phone's current pairing code and tool list, and OAuth grants (hashed
  tokens and the AI app's name). Nothing about the user's money.

## Deploy (free plan is enough)

You need a Cloudflare account and Node 22+.

1. `npm ci`
2. `npx wrangler login`
3. `npx wrangler kv namespace create OAUTH_KV`, and put the printed id in
   `wrangler.jsonc` under `kv_namespaces`.
4. In `wrangler.jsonc`, set `vars.BASE_URL` to the relay's public address:
   `https://simplemoney-ai-relay.<your-subdomain>.workers.dev`, or your own
   domain (add a `routes` entry for it). **It must be exactly the address
   people use.** Tokens are issued for that address, so an AI app using
   another name for the same Worker can't sign in.
5. The rate-limit `namespace_id`s must be unique in your account. Change them
   if they clash with another Worker's.
6. `npm run deploy`

Then point the app at it: either build with
`--dart-define=AI_RELAY_URL=https://…` (add `AI_RELAY_URL=` to `secrets/.env`),
or enter the address in More → AI assistant → Relay.

A newly connected AI app can take up to a minute to appear in the app's
connected-apps list (Workers KV listings are eventually consistent). Signing
in and tool calls are not affected. For the same reason, `npm test` is meant
for the local relay; its connection-list check can fail against a deployed one.

Your Cloudflare credentials stay on the computer you deploy from. The app
holds only the relay's address and its own device credential.

## Connect an AI app

- **Claude** (claude.ai, which also covers the desktop and phone apps):
  Settings → Connectors → Add custom connector, with address
  `https://<relay>/mcp`.
- **ChatGPT**: Settings → Apps & Connectors → Create (developer mode), with
  the same address.

When it asks you to sign in, get a pairing code in SimpleMoney and enter it.
Then start an AI session in the app and ask away.

## Develop

- `npm run dev` runs the relay on http://localhost:8787 with local storage.
- `npm test` runs `scripts/e2e.mjs` against it. The script plays a phone and
  an MCP client: registration, pairing, OAuth sign-in with PKCE, tool calls,
  read-only connections, disconnecting and reset.
- `npm run check` type-checks.
- The app's live test runs its real session and tools against the local relay:
  `RELAY_URL=http://localhost:8787 flutter test test/ai_relay_live_test.dart`
  (from `app/`).

## Phone API

All but registration need `Authorization: Device <deviceId>.<secret>`.

| Route | Purpose |
|---|---|
| `POST /device` | Register a phone → `{deviceId, secret}` |
| `POST /device/pair` | Body `{tools, instructions}` → a 6-digit code, valid 10 minutes. `?keep=<code>` keeps the current code while it has a minute left |
| `GET /device/pair` | The phone's live code, or `{code: null}` once it's used or expired |
| `GET /device/connect` | The session WebSocket. The phone sends `{type:"hello",tools,instructions}`, receives `{type:"call",id,name,arguments}`, answers `{type:"result",id,result}`. `ping` → `pong` |
| `GET /device/connections` | Connected AI apps |
| `DELETE /device/connections/:id` | Disconnect one |
| `DELETE /device` | Reset: sign every AI app out and forget the phone |
