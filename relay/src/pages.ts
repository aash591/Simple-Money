const escape = (s: string) =>
	s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]!);

const page = (title: string, body: string) => `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="referrer" content="no-referrer">
<title>${escape(title)} · SimpleMoney</title>
<style>
  :root { color-scheme: light dark; --accent: #2f6fde; }
  body { font: 16px/1.5 system-ui, -apple-system, Segoe UI, Roboto, sans-serif; margin: 0;
         display: grid; place-items: center; min-height: 100vh; background: Canvas; color: CanvasText; }
  main { width: min(420px, calc(100vw - 40px)); padding: 28px 0; }
  h1 { font-size: 22px; margin: 0 0 8px; }
  p { margin: 0 0 16px; opacity: .8; }
  input[type=text] { box-sizing: border-box; width: 100%; font-size: 28px; letter-spacing: .3em; text-align: center;
         padding: 12px; border-radius: 12px; border: 1px solid color-mix(in srgb, CanvasText 25%, transparent);
         background: transparent; color: inherit; }
  label.check { display: flex; gap: 10px; align-items: flex-start; margin: 16px 0; font-size: 15px; }
  .buttons { display: flex; gap: 10px; margin-top: 8px; }
  button { flex: 1; font: inherit; padding: 12px; border-radius: 12px; border: 0; cursor: pointer; }
  button.primary { background: var(--accent); color: white; font-weight: 600; }
  button.secondary { background: color-mix(in srgb, CanvasText 10%, transparent); color: inherit; }
  .error { color: #d33; margin: 12px 0 0; opacity: 1; }
  small { display: block; margin-top: 20px; opacity: .6; }
</style></head>
<body><main>${body}</main></body></html>`;

export function authorizePage(clientName: string, handle: string, nonce: string, error?: string): string {
	return page(
		"Connect",
		`<h1>Connect ${escape(clientName)} to SimpleMoney</h1>
<p>Switch to SimpleMoney now: <b>More › AI assistant › Get pairing code</b>. It’s copied for you. Come back and paste it here.</p>
<form method="post" action="/authorize">
  <input type="hidden" name="handle" value="${escape(handle)}">
  <input type="hidden" name="client" value="${escape(clientName)}">
  <input type="text" name="code" inputmode="numeric" autocomplete="one-time-code" pattern="[0-9]{6}"
         maxlength="6" placeholder="000000" aria-label="Pairing code" required autofocus>
  ${error ? `<p class="error" role="alert">${escape(error)}</p>` : ""}
  <label class="check"><input type="checkbox" name="write" value="on" checked>
    <span>Allow suggestions: new categories, corrections and SMS rules. Each one still waits for your approval in the app.</span></label>
  <div class="buttons">
    <button class="secondary" type="submit" name="decision" value="deny" formnovalidate>Cancel</button>
    <button class="primary" type="submit" name="decision" value="approve">Connect</button>
  </div>
</form>
<small>${escape(clientName)} can read your accounts, categories and transactions while an AI session is on in the app.</small>
<script nonce="${escape(nonce)}">
  // One tap is enough: answering can take a few seconds.
  document.querySelector("form").addEventListener("submit", (e) => {
    const tapped = e.submitter;
    if (!tapped || tapped.value !== "approve") return;
    // After this tick, so the tapped button's value is still sent.
    setTimeout(() => {
      for (const b of document.querySelectorAll("button")) b.disabled = true;
      tapped.textContent = "Connecting…";
    });
  });
</script>`,
	);
}

export function messagePage(title: string, message: string, status = 400): Response {
	return new Response(page(title, `<h1>${escape(title)}</h1><p>${escape(message)}</p>`), {
		status,
		headers: { "Content-Type": "text/html; charset=utf-8" },
	});
}
