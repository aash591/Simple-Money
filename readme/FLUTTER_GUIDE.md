# SimpleMoney — UI/UX Guide

A plain-language walkthrough of how the app looks, feels, and behaves — screen by screen, popup by popup — so it can be rebuilt with the same experience. No code, just structure and behavior.

---

## 1. The overall feel

Clean, flat, rounded, lots of white space, one blue accent color, big readable numbers. Cards have soft shadows instead of borders. Every circular icon badge is the same shape and size wherever it appears (accounts, categories, transactions all reuse the same "icon in a colored circle" look). Green means money in / good, red means money out / over-budget. Dark mode mirrors light mode with the same layout, just inverted colors.

**Colors at a glance:**
- Accent blue for buttons, links, selected states, expense charts
- Green for income and "under budget"
- Red for expenses and "over budget"
- Soft off-white background in light mode, near-black background in dark mode
- Category charts use a small rotating set of colors (blue, teal, orange, purple, pink)

---

## 2. Reusable building blocks

These same pieces show up again and again across the app. Build each one once.

### Page header
Every full screen has a simple header: a title on the left (bold, largish), sometimes a small back arrow before it, and sometimes 1-2 small icon buttons on the right (search, menu, etc.). No colored bar behind it — it just sits on the page background. A thin line sometimes separates it from the content below.

### Cards
Rounded-corner white (or dark-slate) boxes with a very soft shadow. Almost everything on a screen lives inside a card. Padding inside is generous and consistent.

### List rows
A row = a small circular icon on the left, a title and (optional) smaller gray subtitle stacked in the middle, and on the right an optional value/amount plus a small arrow (›) if tapping goes somewhere. Rows inside the same card are separated by a thin line that starts after the icon (not full width), so it lines up with the text, not the icon.

### The "+" add button
A round blue floating button in the bottom-right corner, sitting above the bottom tab bar. It's visible on Home, Transactions, and Budgets — not on the More tab. What it does depends on which tab you're on:
- Home / Transactions → opens the **Add Transaction** popup
- Budgets → opens a **new budget** page

### Search bar
A pill-shaped light gray field with a search icon on the left and (in one place) a microphone icon on the right for voice search. Typing filters the list live. It only appears when you tap a search icon in the header — the rest of the time it's hidden, and it slides in/out smoothly.

### Bottom popup (sheet)
A full-width card attached to the bottom of the screen, exactly as tall as its content — up to the space below the status bar, after which its content scrolls. When its content changes height (moving between steps, say) the card smoothly grows or shrinks. Rounded top corners (28dp) and a small handle bar at the top; behind it the rest of the screen dims (28% black). The main transaction popup has 30dp corners on all sides, a 12dp inset, and a soft shadow. It fades in while rising only a little (24dp, 280ms) so it feels like it settles into place; the smaller pickers stacked on top of it slide up from below instead. You can:
- drag it down to close it — past a short distance, or with a quick flick; otherwise it eases back
- tap the darkened area to close it, for read-only or picker popups (never for a half-filled form)
This is used for: choosing from a list (account, category, filter, time range), the add/view/edit transaction flow, transfer money, adjust balance, and date/month pickers. In code: `showAdaptiveSheet` in `ui/components/adaptive_sheet.dart`, which also holds the shared header, card, and bottom-button pieces.

### Center popup (modal)
A card that fades in and gently rises into the middle-ish of the screen, for bigger one-off moments. Transactions don't use it: viewing and editing one happens in the same bottom popup as adding it (§5).

### Small popup menu
A tiny rounded menu that pops up right under (or above, if there's no room) the button you tapped — like the "⋮" (more options) button on the Transactions screen. It pops open and shrinks closed with a quick, subtle scale + fade, not a slide. Used for short lists of actions (4 items or fewer), and for small dropdowns like the month selector.

### Choice list popup
A specific bottom popup used whenever you're picking **one thing from a list**: an account, a category, a filter, a currency. Each option is a row (icon + label, sometimes a small amount on the right); the current selection has a filled checkmark circle, everything else has an empty ring. Tapping an option closes the popup and applies your choice in one motion — it doesn't stay open after you pick.

### Date picker
A rounded calendar popup anchored beside the transaction Date row, using the same surface and calendar component as Home: day names across the top and a grid of days below. Swipe horizontally or use the header arrows to slide between months; six week rows keep the surface steady. Tapping the month or year name switches to its grid, then returns to days once you pick a month. A subtle blue Today pill at the bottom-right selects today's date from any view.

### Month picker
Home uses a compact rounded dropdown anchored beneath the month/year label, with a soft shadow and a subtle scale-in animation. It opens directly to a 12-month grid; tap the year for a grid of nearby years, then pick a year and month to apply. Header arrows change the year in month view. The year grid has no arrows: swipe horizontally between twelve-year ranges, with the range shown at the top-right. Month and year grids keep the same dimensions. The bottom-right Today pill applies the current month. Tap outside or press Back to dismiss without changing the month. It reuses the date calendar grids, with a short fade and slide when switching between month and year views; reduced-motion settings skip the animation. The separate right chevron on Home slides the screen left into Transactions for the selected month; normal tab taps remain instant.

### Number keypad
A big custom on-screen keypad (1-9, a decimal point, 0, and a backspace) used for typing money amounts — bigger, simpler buttons than a regular keyboard, made just for entering numbers. The keys are equal-width light-gray tiles; long-pressing backspace clears the whole amount. It allows one decimal point, only as many decimal places as the account's currency has, and up to nine digits before the point. Above it, the amount you're typing is shown large and centered so you always see what you've entered.

### Loading placeholder
Before a list has loaded (accounts, categories), instead of a blank screen you see a few gray rounded-rectangle "ghost" rows with a soft light band slowly sweeping across them left to right, on a loop — a shimmer effect that says "still loading" without a blank screen.

### Simple text-entry popup
A small bottom popup that lifts above the keyboard, just to type or edit one thing — a title (one line, up to 50 characters) or a note (several lines, up to 200). It has one text field (autofocused, keyboard opens right away), a character counter, and two buttons at the bottom: Cancel and Save.

---

## 3. Moving between screens (transitions)

- **Switching tabs** (Home / Transactions / Budgets / More): instant, no animation — like flipping between separate mini-apps, each remembering where you left it.
- **Opening a page from within a tab** (e.g. tapping "Manage Accounts" from More): the new page slides in smoothly from the right while the page you came from slides out to the left at the same time — both moving together, like sliding two photos side by side. Going back reverses it exactly (new page — the one you're returning to — slides in from the left, current one slides out to the right). Takes about a third of a second, with a smooth ease-in/ease-out feel (starts and ends gently, moves faster in the middle).
- **Multi-step flows inside one page** (like the category creation screens, or amount → title → category → … → confirm inside "add transaction") use that same left/right slide, just scoped to a smaller area instead of the whole screen.
- **Bottom popups** slide up from off-screen and slide back down when dismissed, a little faster than the full-page transition.
- **Center popups** fade in while gently rising a small amount, and reverse the same way when closing.
- **Small popup menus** scale up slightly from tiny while fading in, and shrink back down while fading out — quick and light.
- **Swiping through time periods** on the Transactions screen (e.g. swiping between months) works like flipping pages of a book — one whole screen of transactions slides completely off as the next one slides fully in, following your finger.

Nothing fades or cross-dissolves between full pages — it's always a directional slide, so you always sense whether you're going "deeper" or "back."

---

## 4. Screens

### Home
Top: app name and a small app-icon logo, no other buttons.

Then, scrolling down:
1. **This month's spending card** — tap the month name to change months (opens the month picker); a small arrow button beside it jumps to the full transaction list for that month. Below that: "Total spent" and a big number, then a small colored line saying how that compares to last month (green if down, red if up). Under that, a simple line chart of running spend across the month.
2. **Two side-by-side small cards**: "Net savings" (income minus spending so far) and "Budget left" (how much of your monthly budget remains) — each tappable, taking you to Transactions or Budgets.
3. **Top expense categories card** — a donut/ring chart on the left (colored slices, total spend in the middle) with a matching list of category names, amounts, and percentages on the right. Shows your top 4 categories individually and lumps the rest into "Others." If you haven't spent anything yet, it just says so.
4. **Accounts card** — a short list of your accounts with their current balance, each row tappable.

The blue "+" button floats over all of this.

### Transactions
Top: "Transactions" with a small subtitle, a search icon, and a "⋮" menu icon (opens: select time range, view by type, adjust balance, transfer money).

Below that:
- A **balance card**: a big number for the currently selected account (or "Total" across all accounts), with a small pill button to switch which account you're viewing — tapping it opens the choice-list popup of accounts.
- A **period strip**: shows the last couple of periods, the current one (bold, underlined), and the next one, so you can tap sideways through time, or just swipe the list itself left/right like turning pages.
- If the period has activity, a small **opening balance / ending balance** summary appears above the list.
- The **transaction list**, grouped by date. Each date heading shows the day, whether it's "Today," and that day's total income/expense. Under each date, a card groups that day's transactions — each one showing an icon, a title (who you paid, or the category), a subtitle, the amount (green if income), and the time.
- Nice little touch: recognized merchants like Netflix or Spotify get their real logo-style icon instead of a generic category icon, and things like "coffee," "grocery," or "taxi" in the payee name automatically get a matching icon.
- Empty periods show a friendly icon + message instead of a blank list.

Tapping any transaction opens a **detail popup**: a big amount at the top, then a clean list of details (title, account, category, date, note), with an "Edit" button if it's something you can edit (not for transfers).

### Budgets
Top: just "Budgets," then the month (tap it for the month picker) and — only if you have accounts in more than one currency — a currency switcher, since each currency keeps its own budgets.

Budgets **carry forward**: set one once and it applies to every following month until you change it. Changing or removing a budget while viewing a month applies from that month on and replaces any later changes; earlier months keep what they had, so past months stay accurate. Every budget is built from top-level expense categories (spending in a subcategory counts toward its parent): a **category budget** covers one, and a **custom budget** combines several under one limit, with an optional name. A category is in at most one budget at a time, so no spending is counted twice. On top of those there's one optional **total monthly budget** that every expense counts toward. Only expenses count — never transfers or income.

- A **total monthly budget card**: the limit large, a green dot and "₹551.50 left" (a coral dot and "₹12 over" once past it), "69% used," and a full-width bar. It shows your total budget; without one it adds up your other budgets ("Total of category budgets") and counts only the spending in their categories. A configured total can be tapped to edit it; the calculated category total is read-only.
- A **budgets card**: one row per category or custom budget, ordered by its first category in the category list — icon (a shared one for custom budgets), name (a custom budget without one reads "Food & Beverage + 1 more"), limit, the categories a custom budget combines, a thin bar, then "left"/"over" and the percentage used. Bars are blue, turning coral (and full) once over. Tap a row to edit it.
- With no budgets yet, one card invites you to set your first (or a total); with only a total, a small row invites you to add a category budget.

The "+" button here opens a dedicated **Set Budget** page (not a popup), starting on the first category without a budget:
- At the top, a card showing what the budget covers. For a custom budget there's also a **Name** row (opens the simple text popup), and always an **Add category** row that slides over (the same left/right slide as other steps) to a **Choose categories** page: tick one category or several — ones already in another budget are grayed out and say which — then Done slides back; Cancel or back slides back without changes. The total's page just says "Total spending": what it covers can't be changed.
- A note that it applies to the viewed month and every month after, the amount large in the middle, and the number keypad low down within easy thumb reach, right above iOS-style **Cancel** and **Set budget** pill buttons. Set budget only lights up once the amount is above zero and something has changed.
- Changing which categories a budget covers, or its name, from a month on leaves earlier months showing it as it was. Editing adds a delete icon to the header to remove the budget, after a confirmation.

Home's **Budget left** card shows what's left of the same total ("Over budget" in coral once past it) and taps through to this tab.

### More
No header — it starts right at a **profile card** (a placeholder for now: an icon, "Your profile," "Personalize SimpleMoney"). Below it, a menu card with four rows: **Manage Accounts**, **Backup & Sync** (not active yet), **Categories**, **About** (not active yet). No "+" button on this tab.

**Manage Accounts** (opened from More): a reorderable list of your accounts — each shows a drag handle, the account name, how many transactions it has, and its balance. You can drag to reorder them, tap one to edit it, or tap a dashed "add account" card at the end to create a new one.

**Add/Edit Account page**: a name field, a currency picker row (opens a searchable list of countries/currencies), and either an opening-balance field (new account) or read-only current balance + transaction count (existing account). A note appears if you change an existing account's currency, clarifying it won't convert old amounts. A Save button at the bottom only lights up once something's actually changed.

**Categories** (opened from More): tabs across the top for Expense / Income / Debt-Loan. A "+ New category" row, then a list of categories (with subcategories shown indented underneath their parent). Tapping "+ New" or an existing category opens a small form: an icon (tap to change it from a grid of icon choices), a name field, its type (read-only), and an optional parent category. A search icon lets you filter the list.

---

## 5. Add Transaction — the main flow

This is the heart of the app, designed to be as fast as possible. Adding, viewing, and editing a transaction are all **one** bottom popup (`ui/transactions/transaction_sheet.dart`) sharing one draft, not separate screens. Moving forward a step slides the current page out to the left as the next one comes in from the right (going back mirrors it), while the popup smoothly resizes to fit — no fading between steps. Every page has a centered title, with a back arrow on the left when there's somewhere to go back to.

**Step 1 — Choose type** *(from the + button)*: two big tinted cards, "Add expense" (red, "Record money you spent") and "Add income" (green, "Record money you received"), a small "Transfer between accounts" link, and a Cancel button. Tapping the dimmed background does nothing during adding, so a stray tap never loses what you've entered.

**Step 2 — Amount**: a bold question ("What is the amount?" / "What income did you receive?"), a softly raised white card showing a large neutral amount (₹0.00 until you type), and the number keypad below it. Cancel and Continue are gray and blue pill-shaped buttons side by side; Continue is disabled until the amount is greater than zero.

Then one question per step, each sliding in from the right:

**Step 3 — Category** ("Choose category" / "Choose source" for income): the popup grows to its full height — up to just below Home's "SimpleMoney" header, never covering it — with the category list (subcategories indented under their parent, the current choice checked, "Add category" last) and the standard search bar pinned at the bottom. The search bar doesn't raise the keyboard until you tap it; typing filters live, keeping a matching subcategory under its parent. Tapping a category picks it and moves on. Nothing is picked in advance.

**Step 4 — Pay from** ("Deposit to" for income): the same list-plus-bottom-search treatment for accounts, with "Add account", but only as tall as its rows need — growing up to that same limit, then scrolling. The first account is checked for you.

**Step 5 — Date**: the calendar right in the popup, defaulting to today. Tapping a day picks it and moves on; Continue keeps the date shown. The time of day is kept when you change the date.

**Step 6 — Confirm**: the amount large in red or green, then a summary card. Its **Title** (up to 50 characters) and **Note** (several lines, up to 200) rows are typed into right there — both optional, with muted "Add a title" / "Add a note" hints. Neither opens the keyboard on its own: tap the row, and the popup lifts smoothly with the keyboard, with nothing else moving at the same time. (A transaction without a title shows its category as the title.) Title and note deliberately aren't steps of their own: sliding to a new step while the keyboard opened made the popup lurch. Tap the amount or any other row to jump back to just that step; finishing it returns straight to Confirm, with what you typed still there. If a newly chosen account can't hold the amount's decimal places, a warning says so and Save stays disabled. The Save button reflects what you're saving ("Save expense" / "Save income") and reads "Saving…", with both buttons disabled, while it commits; then the popup closes.

Throughout, Cancel is always available and closes everything; you can also drag the popup down, which closes the whole thing from any step. Going back a step (back arrow or system back gesture) slides you to the previous step — only backing out of the first step closes the popup.

**Viewing and editing**: tapping a transaction on the Transactions screen opens the same popup on a read-only page: the signed amount (red "- ₹450" for expense, green "+ ₹56,800" for income, blue for a transfer), then its title, account, category (or "To" account for a transfer), date and time, and note. A "Delete" button sits beside "Edit transaction" (expenses and income only; transfers can't be edited, but can still be deleted). Edit opens straight on the same Confirm page, pre-filled — no sliding through Amount, Category, Account and Date first — with its fields editable right there and Cancel/Save at the bottom; tapping a field (amount, category, account or date) still drills into that field's own keypad or picker, then returns straight to Confirm. Cancel, or the header's back arrow, discards the edits and returns to the read-only page; Save updates the existing transaction in place. Delete asks you to confirm in the app's centered alert popup, then permanently removes the transaction and reverses its effect on the balance(s) it moved. The read-only page also closes by tapping the dimmed background.

### Related quick-actions (opened from the Transactions "⋮" menu)
- **Adjust balance**: pick whether you're **setting**, **adding to**, or **subtracting from** an account's balance (three buttons, only one active at a time), type the amount on the keypad, then review the before/after balance before saving.
- **Transfer money**: type the amount, then pick a "From" account and a "To" account (picking the same one on both sides automatically swaps them), an optional date and note, then confirm.

Both use the same two-step "amount, then review" pattern as the main Add Transaction flow, so the whole app feels consistent no matter which money-entry flow you're in.
