// Builds the body of WebDoc/index.html. The <head> (SEO tags and structured
// data) is kept as it is. Run: node tool/webdoc_home.cjs
const fs = require('fs');
const f = require('path').resolve(__dirname, '..', 'WebDoc', 'index.html');
let s = fs.readFileSync(f, 'utf8');
const head = s.slice(0, s.indexOf('<body'));
const PLAY = 'https://play.google.com/store/apps/details?id=com.aash591.SimpleMoney';
const svg = '<svg viewBox="0 0 40 40" aria-hidden="true"><path fill="#00d7fe" d="M7 5.6v28.8c0 .9.5 1.6 1.100 2L24.300 20 8.100 3.600C7.500 4 7 4.700 7 5.600z"/><path fill="#00f076" d="M29.700 14.600 11.400 4.100c-1.200-.7-2.400-.8-3.300-.5L24.300 20z"/><path fill="#ff3a44" d="M8.100 36.400c.9.300 2.100.2 3.300-.5l18.300-10.500L24.300 20z"/><path fill="#ffd500" d="m29.700 25.400 5.500-3.200c1.900-1.100 1.900-3.300 0-4.400l-5.500-3.200-5.400 5.400z"/></svg>';
const play = `<a class="btn btn-play" href="${PLAY}" rel="noopener">${svg}<span><small>Get it on</small><span>Google Play</span></span></a>`;

const row = (eyebrow, h, p, items, more, imgs, alts) => `
  <section class="row">
    <div class="copy">
      <div class="eyebrow">${eyebrow}</div>
      <h2>${h}</h2>
      <p>${p}</p>
      <ul>${items.map((i) => `<li>${i}</li>`).join('')}</ul>
      <a class="more" href="${more[0]}">${more[1]} →</a>
    </div>
    <div class="shots">${imgs.map((m, i) => `<img src="/assets/app/${m}.webp" alt="${alts[i]}" width="540" height="1200" loading="lazy">`).join('')}</div>
  </section>`;

const tour = (img, t, p) => `<figure><img src="/assets/app/${img}.webp" alt="${t}" width="540" height="1200" loading="lazy"><figcaption><b>${t}</b>${p}</figcaption></figure>`;

const way = (n, img, t, p, href) => `<a class="way" href="${href}"><img src="/assets/app/${img}.webp" alt="${t}" width="540" height="1200" loading="lazy"><span class="num">${n}</span><b>${t}</b><span>${p}</span></a>`;

const body = `<body class="home">
<header class="bar"><div class="wrap">
  <a class="brand" href="/"><img src="/assets/img/app-icon-512.png" alt="" width="34" height="34">SimpleMoney</a>
  <button class="menu-toggle" type="button" aria-label="Toggle navigation" aria-expanded="false">
    <span class="bar-line"></span>
    <span class="bar-line"></span>
    <span class="bar-line"></span>
  </button>
  <nav class="menu" aria-label="Main">
    <a href="/best-expense-manager-app">Why SimpleMoney</a>
    <a href="/ai-expense-tracker">AI &amp; MCP</a>
    <a href="/guides">Guides &amp; FAQ</a>
    <a class="btn-sm" href="${PLAY}" rel="noopener">Get the app</a>
  </nav>
</div></header>

<main>
<section class="hero"><div class="wrap">
  <div>
    <span class="pill">Free · Offline · No account</span>
    <h1><span class="fixed">Track your money</span><span class="typed" id="typed" data-lines='["in a few seconds.","from your bank SMS.","without an account.","without the internet.","down to the last EMI.","in every currency.","and keep it yours."]'>in a few seconds.</span><span class="caret" aria-hidden="true"></span></h1>
    <p class="lead">The free expense manager and budget planner for Android. Add a transaction in seconds by hand, from your bank SMS, from a statement, or with AI. Loans, EMIs and subscriptions stay in order, and your money data never leaves your phone.</p>
    <div class="cta-row">${play}<a class="btn btn-ghost" href="/guides">See how it works</a></div>
  </div>
  <div class="stage" aria-hidden="true">
    <div class="phone a"><img src="/assets/app/bud-list.webp" alt="" width="540" height="1170"></div>
    <div class="phone b"><img src="/assets/app/home-top.webp" alt="" width="540" height="1170"></div>
  </div>
</div></section>

<section class="trust"><div class="wrap"><ul>
  <li><b>Add in seconds</b>SMS, by hand, import or AI</li>
  <li><b>Works offline</b>No internet needed</li>
  <li><b>No account</b>No sign-up, no email</li>
  <li><b>AI-ready</b>Claude and ChatGPT over MCP</li>
</ul></div></section>

<section class="ways"><div class="wrap">
  <div class="eyebrow">Add transactions</div>
  <h2>Four ways to add a transaction. Pick whichever is comfortable for you.</h2>
  <div class="way-grid">
    ${way(1, 'sms-preview', 'From your bank SMS', 'Bank and UPI alerts are read on your phone and added for you.', '/bank-sms-expense-tracker')}
    ${way(2, 'add-category', 'By hand, in seconds', 'Amount, category, account, save. One question per screen, no forms.', '/guides#first-expense')}
    ${way(3, 'statement-review', 'From a statement', 'Import an Excel, PDF or CSV file. Duplicates are caught, and the layout is remembered.', '/guides#import-statement')}
    ${way(4, 'ai-suggestion-sms', 'With your AI', 'Tell Claude or ChatGPT, or show it a bill. You approve what it adds.', '/ai-expense-tracker')}
  </div>
</div></section>

<div class="wrap rows">
${row('Bank SMS', 'Your bank texts you. SimpleMoney does the rest.', 'Bank and UPI alerts are read on your phone and turned into transactions, with the right account and amount. No bank login, and nothing is uploaded.', ['Works for banks and wallets in many countries', 'Pick the category with one tap from the notification', 'Teach it a new bank format with AI in minutes'], ['/bank-sms-expense-tracker', 'How SMS tracking works'], ['sms-rule-result', 'ob-sms'], ['Transactions the rule added', 'Allow SMS once, then it runs by itself'])}
${row('Budgets', 'Know what is left before you spend it.', 'Set a limit for a category or the whole month and see your pace. The home screen shows what is coming up, so there are no surprises.', ['Budgets with what is left and a pace line', 'Spending by category and by month', 'Upcoming EMIs and bills on the home screen'], ['/best-expense-manager-app', 'Everything in the app'], ['bud-list', 'home-spending'], ['Budgets with what is left', 'Where your money went'])}
${row('Loans &amp; EMIs', 'Loans, debts and EMIs, finally in one place.', 'See every loan with its progress and due dates. Keep money you lent or borrowed separate from daily spending, and get reminders before payments are due.', ['Loan progress, remaining balance and payoff date', 'Who owes you and whom you owe', 'Subscriptions and recurring payments with a six-month forecast'], ['/guides#loans', 'Read the loan guide'], ['loan-list', 'rec-list'], ['Loan progress and EMIs', 'Recurring payments and a forecast'])}
${row('AI assistant', 'Ask Claude or ChatGPT about your money.', 'Connect your own AI over MCP and ask in plain words. It can sort transactions, explain your spending and teach the app a new bank SMS. It only suggests. You approve every change.', ['Pairing code and time-limited sessions', 'Exact totals from the app, not guesses', 'Works with Claude and ChatGPT'], ['/ai-expense-tracker', 'AI expense tracker with MCP'], ['ai-top', 'ai-suggestion-sms'], ['Connect an AI assistant', 'A suggestion waiting for your approval'])}
</div>

<section class="tour"><div class="wrap">
  <h2>And the rest of what you use every day</h2>
  <p class="sub">Real screens from the app. Swipe along.</p>
</div>
  <div class="tour-track">
    ${tour('set-currency', 'More than one currency', 'Each account in its own currency, with a combined total in your main one.')}
    ${tour('import-start', 'Import statements', 'PDF, CSV and Excel, including Google Pay, PhonePe and Paytm.')}
    ${tour('sync-encrypt-pin', 'Encrypted backup', 'To your own Google Drive, locked with a PIN that is never stored.')}
    ${tour('set-security', 'App lock', 'Fingerprint, face or PIN. Your data stays on the phone.')}
    ${tour('customization', 'Make it yours', 'Looks, accent colours and searchable bank icons.')}
  </div>
</section>

<section class="band"><div class="wrap">
  <div>
    <h2>Your money stays on your phone.</h2>
    <p>SimpleMoney has no accounts and no servers that hold your records. Your SMS are read on the device, and you decide what ever leaves it.</p>
    <a class="more" href="/privacy">Read the privacy policy →</a>
  </div>
  <ul>
    <li><b>Offline first</b><span>Everything works without internet.</span></li>
    <li><b>You approve AI changes</b><span>The assistant only makes suggestions.</span></li>
    <li><b>Backups you control</b><span>Your Google Drive, encrypted with AES-256.</span></li>
  </ul>
</div></section>

<section class="center"><div class="wrap">
  <h2>Try the best expense manager for yourself.</h2>
  <p class="sub">Free on Google Play. Set up in a minute, with no account.</p>
  <div class="cta-row">${play}<a class="btn btn-ghost" href="/guides">Read the guides</a></div>
</div></section>
</main>

<footer class="foot2">
  <div class="wrap">
    <nav aria-label="Explore"><b>Explore</b>
      <a href="/best-expense-manager-app">Best expense manager app</a>
      <a href="/bank-sms-expense-tracker">Bank SMS expense tracker</a>
      <a href="/ai-expense-tracker">AI &amp; MCP</a>
      <a href="/cashew-alternative">Cashew alternative</a>
      <a href="/money-lover-alternative">Money Lover alternative</a>
    </nav>
    <nav aria-label="Help"><b>Help</b>
      <a href="/guides">Guides &amp; FAQ</a>
      <a href="/privacy">Privacy policy</a>
      <a href="/terms">Terms</a>
    </nav>
    <nav aria-label="SimpleMoney"><b>SimpleMoney</b>
      <a href="${PLAY}" rel="noopener">Google Play</a>
      <a href="https://aashglobal.in">Aash Global</a>
    </nav>
  </div>
  <p class="fine">No account needed. The free version has a few quiet ads, never while you add or browse; Pro removes them. Made with care by Aash Global.</p>
</footer>
<script src="/assets/site.js" defer></script>
</body>
</html>
`;
let h = head.replace('style.css?v=2', 'style.css?v=3').replace('home.css?v=1', 'home.css?v=2');
if (!h.includes('home.css')) h = h.replace(/(<link rel="stylesheet" href="\/assets\/style\.css[^"]*">)/, '$1\n<link rel="stylesheet" href="/assets/home.css?v=2">');
fs.writeFileSync(f, h + body);
console.log('index.html rebuilt');
