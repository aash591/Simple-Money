part of 'app_database.dart';

const _createBudgetsTable = '''
CREATE TABLE budgets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('total', 'categories')),
  name TEXT CHECK(name IS NULL OR length(trim(name)) BETWEEN 1 AND 40),
  currency TEXT NOT NULL CHECK(length(currency) = 3),
  digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
  icon TEXT
)
''';

const _createBudgetsTotalIndex = '''
CREATE UNIQUE INDEX budgets_total ON budgets(currency, digits)
WHERE kind = 'total'
''';

const _createBudgetCategoriesTable = '''
CREATE TABLE budget_categories (
  budget_id INTEGER NOT NULL,
  category_id INTEGER NOT NULL,
  PRIMARY KEY (budget_id, category_id)
)
''';

const _createBudgetAmountsTable = '''
CREATE TABLE budget_amounts (
  budget_id INTEGER NOT NULL,
  start_month INTEGER NOT NULL,
  amount_minor INTEGER CHECK(amount_minor IS NULL OR amount_minor > 0),
  PRIMARY KEY (budget_id, start_month)
)
''';

const _createDebtPeopleTable = '''
CREATE TABLE IF NOT EXISTS debt_people (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
  phone TEXT,
  created_at INTEGER NOT NULL
)
''';

const _createDebtEntriesTable = '''
CREATE TABLE IF NOT EXISTS debt_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('lend', 'borrow', 'collect', 'repay')),
  amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
  currency TEXT NOT NULL CHECK(length(currency) = 3),
  digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
  account_id INTEGER,
  transaction_id INTEGER,
  note TEXT,
  date INTEGER NOT NULL,
  due_date INTEGER,
  created_at INTEGER NOT NULL
)
''';

const _createCategoriesTable = '''
CREATE TABLE categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
  type TEXT NOT NULL CHECK(type IN ('expense', 'income', 'debt_loan')),
  icon TEXT,
  parent_id INTEGER,
  sort_order INTEGER NOT NULL
)
''';

const _createTransactionsTable = '''
CREATE TABLE transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL CHECK(type IN ('expense', 'income', 'transfer')),
  amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
  account_id INTEGER NOT NULL,
  to_account_id INTEGER,
  -- What actually landed in to_account_id, when that differs from the amount
  -- sent: a transfer across currencies, or one a charge was taken from.
  -- Null means the destination received amount_minor unchanged.
  to_amount_minor INTEGER CHECK(to_amount_minor IS NULL OR to_amount_minor > 0),
  category_id INTEGER,
  title TEXT,
  note TEXT,
  date INTEGER NOT NULL,
  created_at INTEGER NOT NULL
)
''';

// Changes an AI app proposed, waiting for the user to approve them (see
// data/agent/agent_suggestion_repository.dart). Device-local like the SMS
// review index: targets are local IDs, so it is excluded from syncTables and
// cleared by a restore.
const _createAgentSuggestionsTable = '''
CREATE TABLE IF NOT EXISTS agent_suggestions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id TEXT NOT NULL,
  kind TEXT NOT NULL
    CHECK(kind IN ('new_category', 'sms_correction', 'transaction_edit',
      'parser_rule', 'statement_layout', 'new_loan', 'debt_entry',
      'transaction_add', 'recurring_payment')),
  target TEXT NOT NULL,
  payload TEXT NOT NULL,
  before TEXT,
  summary TEXT NOT NULL,
  detail TEXT NOT NULL,
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending', 'applied', 'rejected', 'undone')),
  error TEXT,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
)
''';

// Merchant -> category the user chose on a notification, reused for the next
// message from that merchant. Synced. `owner` is the undo token of the change.
const _createSmsCategoryMemoryTable = '''
CREATE TABLE IF NOT EXISTS sms_category_memory (
  merchant TEXT PRIMARY KEY,
  category_id INTEGER NOT NULL,
  owner TEXT NOT NULL
)
''';

// SMS formats the user approved, added to the bundled rule packs (see
// data/user_sms_rules.dart). One row is one format of the portable rule
// spec. Synced, so a restored phone keeps the formats it learned.
const _createUserSmsRulesTable = '''
CREATE TABLE IF NOT EXISTS user_sms_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_name TEXT NOT NULL,
  senders TEXT NOT NULL,
  format TEXT NOT NULL,
  samples TEXT NOT NULL,
  created_at INTEGER NOT NULL
)
''';

// Shared fixes from other users (see data/community/community_fixes.dart):
// SMS formats and statement layouts, as last downloaded. Device-local,
// rebuildable cache, excluded from syncTables. `off` marks one the user
// turned off, kept so a new download doesn't bring it back.
const _createCommunityFixesTable = '''
CREATE TABLE IF NOT EXISTS community_fixes (
  hash TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('sms_rule', 'statement_layout')),
  payload TEXT NOT NULL,
  off INTEGER NOT NULL DEFAULT 0
)
''';

// Device-local, rebuildable cache. Deliberately excluded from syncTables.
const _createExchangeRatesTable = '''
CREATE TABLE IF NOT EXISTS exchange_rates (
  base TEXT NOT NULL,
  quote TEXT NOT NULL,
  rate REAL NOT NULL CHECK(rate > 0),
  fetched_on TEXT NOT NULL,
  rate_date TEXT NOT NULL,
  PRIMARY KEY(base, quote)
)
''';
