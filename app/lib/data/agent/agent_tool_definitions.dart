part of 'agent_tools.dart';

/// MCP schemas and descriptions, separate from execution and validation.
extension _AgentToolDefinitions on AgentTools {
  List<AgentTool> _createTools() => [
    AgentTool(
      name: 'list_accounts',
      title: 'List accounts',
      description:
          'The user\'s accounts (bank, credit card, cash) with id, currency, '
          'balance, transaction count, icon, bank, credit limits and the '
          'last digits of the account number when known. Change them with '
          'suggest_account_changes.',
      inputSchema: AgentTools._schema({
        'include_archived': {'type': 'boolean', 'default': false},
      }),
      handler: _listAccounts,
    ),
    AgentTool(
      name: 'list_categories',
      title: 'List categories',
      description:
          'The user\'s categories with id, type and parent. Categories nest '
          'one level deep. debt_loan categories belong to debts and loans '
          'and can\'t be chosen for ordinary transactions.',
      inputSchema: AgentTools._schema({
        'type': {
          'type': 'string',
          'enum': ['expense', 'income', 'debt_loan'],
        },
      }),
      handler: _listCategories,
    ),
    AgentTool(
      name: 'search_transactions',
      title: 'Search transactions',
      description:
          'Saved transactions in a date range, newest first, optionally '
          'filtered by text (title, note or category), category, account or '
          'type. A category filter includes its subcategories. Notes often '
          'hold the original bank SMS; ask for them only when needed.',
      inputSchema: AgentTools._schema(
        {
          'from': AgentTools._date,
          'to': AgentTools._date,
          'query': {'type': 'string'},
          'category_id': {'type': 'integer'},
          'account_id': {'type': 'integer'},
          'type': {
            'type': 'string',
            'enum': ['expense', 'income', 'transfer'],
          },
          'include_notes': {'type': 'boolean', 'default': false},
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 200,
            'default': 50,
          },
          'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
        },
        required: ['from', 'to'],
      ),
      handler: _searchTransactions,
    ),
    AgentTool(
      name: 'find_by_phone',
      title: 'Find by phone number',
      description:
          'Everything that mentions a phone number: saved transactions '
          '(from bank SMS, UPI scans or entered by hand), bank SMS waiting '
          'for review and unparsed bank SMS. Finds UPI IDs built on the '
          'number (9876543210@ybl) and SMS quoting it, with exact totals. It '
          'can\'t see payments through a UPI ID based on an email or name: '
          'always tell the user the accuracy it returns.',
      inputSchema: AgentTools._schema(
        {
          'phone': {
            'type': 'string',
            'description': 'e.g. 9876543210 or +91 98765 43210',
          },
          'from': AgentTools._date,
          'to': AgentTools._date,
          'include_unparsed': {
            'type': 'boolean',
            'default': true,
            'description':
                'Also read the inbox for bank SMS no rule reads (last 180 days '
                'unless from is given)',
          },
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 200,
            'default': 50,
            'description': 'Per list; totals always count everything',
          },
        },
        required: ['phone'],
      ),
      handler: _findByPhone,
    ),
    AgentTool(
      name: 'spending_summary',
      title: 'Spending summary',
      description:
          'Exact totals for a date range grouped by top-level category, '
          'subcategory, month, account or payee (who was paid), largest '
          'first. query narrows it to transactions whose title or category '
          'contains the text. Debt and loan movements are left out, as '
          'everywhere in the app. Each total is for one currency.',
      inputSchema: AgentTools._schema(
        {
          'from': AgentTools._date,
          'to': AgentTools._date,
          'group_by': {
            'type': 'string',
            'enum': ['category', 'subcategory', 'month', 'account', 'payee'],
            'default': 'category',
          },
          'query': {'type': 'string'},
          'limit': {
            'type': 'integer',
            'minimum': 1,
            'maximum': 100,
            'default': 25,
          },
          'type': {
            'type': 'string',
            'enum': ['expense', 'income'],
            'default': 'expense',
          },
        },
        required: ['from', 'to'],
      ),
      handler: _spendingSummary,
    ),
    AgentTool(
      name: 'list_pending_sms',
      title: 'List bank SMS waiting for review',
      description:
          'Bank messages the app parsed but hasn\'t saved yet, with the full '
          'SMS text, what the parser read from it, and the account (names in '
          '"accounts") and category currently chosen. "needs" says what is '
          'still missing. A message with a sender_type (a shop, biller…) '
          'never names an account: pick the one the money went to or came '
          'from, or leave it to the user. Use suggest_sms_corrections to fix '
          'them.',
      inputSchema: AgentTools._schema({
        'ready': {
          'type': 'boolean',
          'description':
              'Only messages that are (true) or aren\'t (false) '
              'ready to save. Leave out for all.',
        },
        'search': {'type': 'string'},
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 100,
          'default': 25,
        },
        'offset': {'type': 'integer', 'minimum': 0, 'default': 0},
      }),
      handler: _listPendingSms,
    ),
    AgentTool(
      name: 'list_suggestions',
      title: 'List suggestions',
      description:
          'Suggestions made earlier and what the user decided. A pending one '
          'with an error failed to apply and says why.',
      inputSchema: AgentTools._schema({
        'status': {
          'type': 'string',
          'enum': ['pending', 'applied', 'rejected', 'undone'],
          'default': 'pending',
        },
      }),
      handler: _listSuggestions,
    ),
    AgentTool(
      name: 'suggest_new_categories',
      title: 'Suggest new categories',
      description:
          'Proposes categories for the user to approve. A subcategory names '
          'a top-level parent of the same type. Changes nothing until '
          'approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'name': {'type': 'string', 'maxLength': 40},
          'type': {
            'type': 'string',
            'enum': ['expense', 'income'],
          },
          'parent_id': {'type': 'integer'},
          'parent_name': {'type': 'string'},
          'reason': AgentTools._reasonField,
        },
        required: ['name', 'type'],
      ),
      handler: _suggestNewCategories,
    ),
    AgentTool(
      name: 'suggest_sms_corrections',
      title: 'Suggest SMS corrections',
      description:
          'Proposes an account and/or category for bank messages waiting for '
          'review (ids from list_pending_sms), or dismisses ones that aren\'t '
          'transactions. A category is given by id, or by name ("Swiggy" or '
          '"Food › Swiggy"). When the bank\'s wording misleads ("Rs 5,000 '
          'credited to your loan a/c" is the user paying the loan), give '
          'loan_id (list_loans) or direction, with same_layout to fix every '
          'message like it, now and later. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'sms_id': {'type': 'string'},
          'account_id': {'type': 'integer'},
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'dismiss': {'type': 'boolean'},
          'direction': {
            'type': 'string',
            'enum': ['debit', 'credit'],
            'description':
                'Where the user\'s money really went, when the SMS says the '
                'opposite. debit: it left the user.',
          },
          'loan_id': {
            'type': 'integer',
            'description':
                'The loan this message pays. It becomes that loan\'s next '
                'payment, from the loan\'s paying account.',
          },
          'same_layout': {
            'type': 'boolean',
            'default': false,
            'description':
                'Also every waiting message of the same layout from this '
                'sender, and the ones to come. Only with direction or '
                'loan_id.',
          },
          'reason': AgentTools._reasonField,
        },
        required: ['sms_id'],
      ),
      handler: _suggestSmsCorrections,
    ),
    AgentTool(
      name: 'suggest_transaction_edits',
      title: 'Suggest transaction edits',
      description:
          'Proposes changes to saved transactions (ids from '
          'search_transactions or find_duplicates): category, account, '
          'title, note, amount, date, or type: an expense or income that was '
          'really money moved between the user\'s own accounts becomes a '
          'transfer (type transfer, account_id the one it left, '
          'to_account_id the one it reached), and back (give a category). '
          'delete removes one, such as a duplicate. transaction_ids gives '
          'many the same change in one item. loan_id makes one a payment to '
          'that loan (list_loans). What a loan, debt or recurring payment '
          'owns is changed from there. Changes nothing until approved; each '
          'can be undone.',
      readOnly: false,
      inputSchema: AgentTools._items({
        'transaction_id': {'type': 'integer'},
        'transaction_ids': {
          'type': 'array',
          'items': {'type': 'integer'},
          'description': 'The same change for each of these.',
        },
        'type': {
          'type': 'string',
          'enum': ['expense', 'income', 'transfer'],
        },
        'category_id': {'type': 'integer'},
        'category_name': {'type': 'string'},
        'account_id': {
          'type': 'integer',
          'description': 'Its account; for a transfer, where it left from.',
        },
        'to_account_id': {
          'type': 'integer',
          'description': 'For a transfer: where the money went.',
        },
        'amount': {'type': 'string', 'description': 'e.g. 250.00'},
        'date': AgentTools._date,
        'title': {'type': 'string', 'maxLength': 80},
        'note': {'type': 'string'},
        'delete': {
          'type': 'boolean',
          'description': 'Remove it. Give nothing else with it.',
        },
        'loan_id': {
          'type': 'integer',
          'description':
              'The loan this transaction pays. Leave out other fields.',
        },
        'reason': AgentTools._reasonField,
      }, required: const []),
      handler: _suggestTransactionEdits,
    ),
    AgentTool(
      name: 'suggest_transactions',
      title: 'Suggest new transactions',
      description:
          'Proposes new expenses, income or transfers to add (from a '
          'receipt, a statement line, or what the user tells you). Give the '
          'account (list_accounts), the amount in that account\'s currency, '
          'and a category by id or name. A transfer (money moved between the '
          'user\'s own accounts, such as a bank to a broker) has no category: '
          'give to_account_id, and received_amount when that account uses '
          'another currency. The date defaults to today. Refuses one '
          'that looks already saved. Changes nothing until approved. Leave '
          'reason out unless something needs the user\'s attention (a guessed '
          'category, an unclear date or amount): with several transactions '
          'the app hides routine reasons, so never restate what the entry '
          'already shows.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'type': {
            'type': 'string',
            'enum': ['expense', 'income', 'transfer'],
            'default': 'expense',
          },
          'amount': {
            'type': 'string',
            'description': 'Decimal amount, e.g. 250.00',
          },
          'account_id': {
            'type': 'integer',
            'description': 'Its account; for a transfer, where it left from.',
          },
          'to_account_id': {
            'type': 'integer',
            'description': 'For a transfer: where the money went.',
          },
          'received_amount': {
            'type': 'string',
            'description':
                'For a transfer into another currency: what arrived.',
          },
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'title': {'type': 'string', 'maxLength': 80},
          'note': {'type': 'string'},
          'date': AgentTools._date,
          'ignore_duplicates': {'type': 'boolean', 'default': false},
          'reason': {
            'type': 'string',
            'maxLength': 280,
            'description':
                'Only when this entry needs attention, in a few words. '
                'Omit otherwise.',
          },
        },
        required: ['amount', 'account_id'],
      ),
      handler: _suggestTransactions,
    ),

    AgentTool(
      name: 'find_duplicates',
      title: 'Find duplicate transactions',
      description:
          'Transactions saved twice (the same kind, account and amount, a '
          'day or so apart), with whether they quote the same UPI '
          'reference, and transfers saved as an expense in one account and '
          'an income in another. Fix them with suggest_transaction_edits.',
      inputSchema: AgentTools._schema({
        'from': {
          ...AgentTools._date,
          'description': 'Default: 90 days before to',
        },
        'to': {...AgentTools._date, 'description': 'Default: today'},
        'account_id': {'type': 'integer'},
        'days': {
          'type': 'integer',
          'minimum': 0,
          'maximum': 7,
          'default': 1,
          'description': 'How many days apart copies may be.',
        },
      }),
      handler: _findDuplicates,
    ),
    AgentTool(
      name: 'list_budgets',
      title: 'List budgets',
      description:
          'The month\'s budgets: the total and each category budget, with '
          'what is set, spent and left, per currency.',
      inputSchema: AgentTools._schema({
        'month': {
          'type': 'string',
          'description': 'YYYY-MM. Default: this month',
        },
      }),
      handler: _listBudgets,
    ),
    AgentTool(
      name: 'list_payees_to_categorize',
      title: 'List payees to categorize',
      description:
          'Who was paid (or paid the user) in transactions left as '
          '"Personal" or with no category, largest total first, with a '
          'bank SMS for each. All dates unless from/to are given. Sort '
          'them with categorize_payee.',
      inputSchema: AgentTools._schema({
        'from': AgentTools._date,
        'to': AgentTools._date,
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 100,
          'default': 10,
        },
      }),
      handler: _listPayeesToCategorize,
    ),
    AgentTool(
      name: 'categorize_payee',
      title: 'Categorize a payee',
      description:
          'Suggests one category for every "Personal" or uncategorized '
          'transaction with a payee from list_payees_to_categorize. Give the '
          'category by name ("Fuel", or "Food & Beverage › Groceries") or '
          'id. Changes nothing until the user approves.',
      readOnly: false,
      inputSchema: AgentTools._schema(
        {
          'payee': {'type': 'string'},
          'category_name': {'type': 'string'},
          'category_id': {'type': 'integer'},
          'from': AgentTools._date,
          'to': AgentTools._date,
          'reason': AgentTools._reasonField,
        },
        required: ['payee'],
      ),
      handler: _categorizePayee,
    ),
    AgentTool(
      name: 'account_activity',
      title: 'Account activity',
      description:
          'Explains an account’s balance: money in and out by kind '
          '(spent, received, transfers in and out), the largest movements, '
          'and notes on what looks wrong. All dates unless from/to are '
          'given. Use it when a balance doesn\'t make sense.',
      inputSchema: AgentTools._schema(
        {
          'account_id': {'type': 'integer'},
          'from': AgentTools._date,
          'to': AgentTools._date,
        },
        required: ['account_id'],
      ),
      handler: _accountActivity,
    ),
    AgentTool(
      name: 'list_missed_sms',
      title: 'List missed bank SMS',
      description:
          'Messages from banks and payment apps that look like transactions '
          'but no rule could read, newest first, with how many come from '
          'each sender. These are what new SMS rules are for.',
      inputSchema: AgentTools._schema({
        'days': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 180,
          'default': 60,
        },
        'sender': {'type': 'string'},
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 100,
          'default': 30,
        },
      }),
      handler: _listMissedSms,
    ),
    AgentTool(
      name: 'get_parser_rules',
      title: 'Get SMS rules',
      description:
          'The bundled formats for a sender (its bank\'s name and up to '
          'limit formats, as examples to copy), and the user\'s own rules. '
          'Without a sender, only the user\'s rules.',
      inputSchema: AgentTools._schema({
        'sender': {'type': 'string'},
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 40,
          'default': 12,
        },
      }),
      handler: _getParserRules,
    ),
    AgentTool(
      name: 'test_parser_rule',
      title: 'Test an SMS rule',
      description:
          'Tries a format on sample messages in the app\'s own parser, with '
          'the bundled rules and the user\'s rules, and says what it read '
          'from each. Saves nothing. bank_name is needed only for a sender '
          'no bundled bank uses. $agentRuleGuide',
      inputSchema: AgentTools._ruleSchema(),
      handler: _testParserRule,
    ),
    AgentTool(
      name: 'suggest_parser_rule',
      title: 'Suggest an SMS rule',
      description:
          'Proposes a format that test_parser_rule showed reads every '
          'sample. Once the user approves it, the app reads the inbox again '
          'and the messages it reads join the SMS review queue. Suggest one '
          'only when the SMS carries an account number or a clear category '
          '(refund, salary…). The user picks the other in SMS review; tell '
          'them which. Same input as test_parser_rule, plus a reason.',
      readOnly: false,
      inputSchema: AgentTools._ruleSchema(reason: true),
      handler: _suggestParserRule,
    ),
    AgentTool(
      name: 'label_sms',
      title: 'Teach a missed SMS',
      description:
          'Teaches the app a missed SMS. Give its id from list_missed_sms and '
          'copy values exactly as they appear in it: amount (required), and '
          'account, payee, reference when present. Only teach an SMS with an '
          'account number or a clear category (refund, salary…). A shop\'s, '
          'biller\'s or lender\'s SMS never gives the account: the app matches '
          'it to the bank\'s SMS for the same money. Never guess what it '
          'leaves out: the user picks it in SMS review, and the reply says '
          'what that is. The app builds the rule, tests it on the other '
          'missed messages from that sender, and suggests it for the user to '
          'approve.',
      readOnly: false,
      inputSchema: AgentTools._schema(
        {
          'sms_id': {'type': 'string'},
          'amount': {
            'type': 'string',
            'description':
                'Exactly as in the SMS, without the currency, e.g. 1,250.00 '
                'or 1.250,00',
          },
          'direction': {
            'type': 'string',
            'enum': ['debit', 'credit'],
            'description': 'debit: money left the user\'s account',
          },
          'channel': {
            'type': 'string',
            'enum': ['upi', 'card', 'bankTransfer', 'atm', 'wallet', 'other'],
          },
          'account': {
            'type': 'string',
            'description': 'Masked account or card, e.g. XX1234',
          },
          'payee': {
            'type': 'string',
            'description': 'Who was paid or who paid, e.g. SWIGGY',
          },
          'reference': {
            'type': 'string',
            'description': 'Reference or UPI number',
          },
          'bank_name': {
            'type': 'string',
            'maxLength': 40,
            'description':
                'The bank\'s or shop\'s name, e.g. Fincare SFB or Meesho. For '
                'a shop, biller or lender, always give it: it is the payee.',
          },
          'sender_type': {
            'type': 'string',
            'enum': [for (final r in SmsSenderRole.values) r.name],
            'description':
                'Who sent it. bank, card or wallet: the SMS reports the '
                'user\'s own account there. merchant (shop, app), biller, '
                'lender, government, other: it only says money moved, so it '
                'is never an account, even when it quotes one.',
          },
          'stage': {
            'type': 'string',
            'enum': ['done', 'pending', 'failed', 'scheduled'],
            'default': 'done',
            'description':
                'pending: "refund initiated", "will be credited". scheduled: '
                '"will be debited on". failed: declined or reversed.',
          },
          'country': {
            'type': 'string',
            'pattern': '^[A-Za-z]{2}\$',
            'description':
                'Where the bank or shop is, as ISO 3166 code: IN, AE, US, '
                'GB, KE… Tell from the currency, language and bank. One '
                'person can bank in several countries.',
          },
          'currency': {
            'type': 'string',
            'pattern': '^[A-Za-z]{3}\$',
            'description':
                'ISO 4217 code of the amount: INR, AED, USD, EUR… ("Rs" is '
                'INR, "Dhs" AED, "Ksh" KES).',
          },
        },
        required: [
          'sms_id',
          'amount',
          'direction',
          'channel',
          'sender_type',
          'country',
          'currency',
        ],
      ),
      handler: _labelSms,
    ),
    AgentTool(
      name: 'list_statements_to_map',
      title: 'List statement layouts to map',
      description:
          'Statement files the app couldn\'t read by itself: each one\'s id, '
          'column names and a few rows. Map one with map_statement. When '
          'has_page_pictures is true, look at the pages first with '
          'view_statement_pages.',
      inputSchema: AgentTools._schema({}),
      handler: _listStatementsToMap,
    ),
    AgentTool(
      name: 'view_statement_pages',
      title: 'View statement pages',
      description:
          'Pictures of the first pages of a PDF statement from '
          'list_statements_to_map, as the user sees it, with the columns the '
          'app split it into. Compare the two: where the app split one real '
          'column in two, join them with map_statement’s join.',
      inputSchema: AgentTools._schema(
        {
          'statement_id': {'type': 'string'},
        },
        required: ['statement_id'],
      ),
      handler: _viewStatementPages,
    ),
    AgentTool(
      name: 'map_statement',
      title: 'Map a statement layout',
      description:
          'Says which column is which in a statement from '
          'list_statements_to_map. Use names from column_names. Give date, '
          'description, and either amount or debit and credit. Each call '
          'adds to the one before ("none" clears a field). The app previews '
          'the rows and suggests the layout for the user to approve. A PDF’s '
          'columns can come split: join puts the pieces back together.',
      readOnly: false,
      inputSchema: AgentTools._schema(
        {
          'statement_id': {'type': 'string'},
          'date': {'type': 'string'},
          'description': {'type': 'string'},
          'amount': {
            'type': 'string',
            'description': 'One column for every amount',
          },
          'debit': {
            'type': 'string',
            'description': 'Money out, when out and in are separate columns',
          },
          'credit': {'type': 'string', 'description': 'Money in'},
          'direction': {
            'type': 'string',
            'description': 'A Dr/Cr column, with amount',
          },
          'reference': {'type': 'string'},
          'balance': {'type': 'string'},
          'date_order': {
            'type': 'string',
            'enum': ['auto', 'day_first', 'month_first', 'year_first'],
            'default': 'auto',
          },
          'join': {
            'type': 'object',
            'description':
                'Columns that are part of another, as column name → the '
                'column it belongs to, e.g. {"Column 3": "Description", '
                '"Amount": "Credit"}. Text reads together, left to right; '
                'an amount from whichever has one. Replaces earlier joins.',
            'additionalProperties': {'type': 'string'},
          },
        },
        required: ['statement_id', 'date'],
      ),
      handler: _mapStatement,
    ),
    AgentTool(
      name: 'list_loans',
      title: 'List loans',
      description:
          'The loans the user tracks: what is left, the instalment, the next '
          'due date and the account that pays. Check here before suggesting '
          'a loan.',
      inputSchema: AgentTools._schema({
        'include_closed': {'type': 'boolean', 'default': false},
      }),
      handler: _listLoans,
    ),
    AgentTool(
      name: 'list_debts',
      title: 'List debts',
      description:
          'People the user has lent to or borrowed from, with each person\'s '
          'id and what is outstanding. owes_you is money they owe the user; '
          'you_owe is money the user owes them.',
      inputSchema: AgentTools._schema({
        'include_settled': {'type': 'boolean', 'default': false},
      }),
      handler: _listDebts,
    ),
    AgentTool(
      name: 'list_recurring_payments',
      title: 'List recurring payments',
      description:
          'The recurring payments the user tracks: subscriptions, rent, '
          'premiums and money that comes in on a schedule, such as rent '
          'received. Each has its amount, cycle, next due date and account. '
          'Check here before suggesting one.',
      inputSchema: AgentTools._schema({
        'include_paused': {'type': 'boolean', 'default': true},
      }),
      handler: _listRecurringPayments,
    ),
    AgentTool(
      name: 'suggest_recurring_payments',
      title: 'Suggest recurring payments',
      description:
          'Sets up recurring payments for the user to approve: Netflix, '
          'rent, insurance, a SIP, or money that comes in, such as rent '
          'received (incoming true). Give the account (list_accounts), the '
          'amount in its currency, the cycle and the next due date. The icon '
          'and category follow the name unless you give them. Refuses one '
          'that is already set up. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'name': {'type': 'string', 'maxLength': 40},
          'amount': {
            'type': 'string',
            'description': 'Decimal amount for one payment, e.g. 649.00',
          },
          'account_id': {'type': 'integer'},
          'cycle': {
            'type': 'string',
            'enum': ['weekly', 'monthly', 'quarterly', 'yearly'],
            'default': 'monthly',
          },
          'next_due': {
            ...AgentTools._date,
            'description': 'The next due date. Defaults to today.',
          },
          'incoming': {
            'type': 'boolean',
            'default': false,
            'description': 'True for money coming in, such as rent received.',
          },
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'icon': {
            'type': 'string',
            'description': 'An icon key from list_icons. Optional.',
          },
          'remind': {'type': 'boolean', 'default': true},
          'transaction_ids': {
            'type': 'array',
            'items': {'type': 'integer'},
            'maxItems': 60,
            'description':
                'Past payments of it (from find_recurring_payments or '
                'search_transactions), linked as its payment history.',
          },
          'sms_ids': {
            'type': 'array',
            'items': {'type': 'string'},
            'maxItems': 60,
            'description':
                'Bank SMS of its past payments from find_recurring_payments, '
                'waiting for review or unparsed. Approving saves each into '
                'the account and links it as history, so none is left in SMS '
                'review or unread.',
          },
          'reason': AgentTools._reasonField,
        },
        required: ['name', 'amount', 'account_id'],
      ),
      handler: _suggestRecurringPayments,
    ),
    AgentTool(
      name: 'find_recurring_payments',
      title: 'Find recurring payments',
      description:
          'Looks through saved transactions, bank SMS waiting for review and '
          'unparsed bank SMS for payments that repeat: the same payee, about '
          'the same amount, weekly, monthly, quarterly or yearly. Finds '
          'subscriptions, bills, rent paid to a person and money that comes '
          'in on a schedule, with each one\'s past transaction_ids and '
          'sms_ids and where each was seen. Leaves out what is already '
          'tracked. Changes nothing.',
      inputSchema: AgentTools._schema({
        'include_unparsed': {
          'type': 'boolean',
          'default': true,
          'description': 'Also read the inbox for bank SMS no rule reads',
        },
        'months': {
          'type': 'integer',
          'minimum': 3,
          'maximum': 24,
          'default': 12,
        },
        'include_income': {'type': 'boolean', 'default': true},
        'limit': {
          'type': 'integer',
          'minimum': 1,
          'maximum': 60,
          'default': 25,
        },
      }),
      handler: _findRecurringPayments,
    ),
    AgentTool(
      name: 'suggest_account_changes',
      title: 'Suggest account changes',
      description:
          'Adds, edits or tidies the user\'s accounts, for them to approve. '
          'action: create (name, type, currency, last_digits, institution, '
          'balance as the opening balance, credit_limit and available_credit '
          'for a card); update (account_id and only the fields to change); '
          'adjust_balance (account_id and balance: what it holds now, e.g. '
          'from a bank SMS or statement; no transaction is logged); archive '
          'or restore (account_id); merge (account_id is removed, its '
          'transactions, balance and SMS links move into merge_into_id: for '
          'one real account SMS scanning split in two, such as a bank '
          'account and its debit card; same currency only); delete '
          '(account_id and every transaction in it; prefer archive or merge). '
          'For a new investment account give place: broker (a broker, '
          'exchange or app that holds cash: balance is its funds) or '
          'in_hand (gold at home, a locker, a crypto wallet: no cash); its '
          'holdings are then added with suggest_portfolio_changes. '
          'Check list_accounts first. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'action': {
            'type': 'string',
            'enum': [for (final a in AgentAccountAction.values) a.toolName],
          },
          'account_id': {
            'type': 'integer',
            'description': 'The account to change; not for create',
          },
          'merge_into_id': {
            'type': 'integer',
            'description': 'For merge: the account to keep',
          },
          'name': {'type': 'string', 'maxLength': 40},
          'type': {
            'type': 'string',
            'enum': [for (final t in AccountType.values) t.name],
          },
          'currency': {
            'type': 'string',
            'description': 'ISO code, e.g. INR. Defaults to the main account',
          },
          'last_digits': {
            'type': 'string',
            'description': 'Last 2–4 digits of the account or card number',
          },
          'institution': {
            'type': 'string',
            'description': 'The bank, e.g. HDFC Bank',
          },
          'icon': {
            'type': 'string',
            'description': 'An icon key from list_icons. Optional.',
          },
          'balance': {
            'type': 'string',
            'description':
                'Decimal, e.g. 12500.00; negative for a card that is owed',
          },
          'credit_limit': {'type': 'string'},
          'available_credit': {'type': 'string'},
          'place': {
            'type': 'string',
            'enum': [for (final p in AccountPlace.selectable) p.toolName],
            'description': 'For create: makes an investment account',
          },
          'reason': AgentTools._reasonField,
        },
        required: ['action'],
      ),
      handler: _suggestAccountChanges,
    ),
    AgentTool(
      name: 'list_portfolio',
      title: 'List portfolio',
      description:
          'The user\'s investments: each broker, exchange, wallet or in-hand '
          'place (gold at home, a locker) with its funds, and the holdings in '
          'it (stocks, ETFs, mutual funds, crypto, metals) with units, '
          'average price, last price and its date, value, gain and where the '
          'price comes from. Metal units are grams. Give holding_id for one '
          'holding with its trades (trade_id for remove_trade), or '
          'include_trades for all. Change things with '
          'suggest_portfolio_changes.',
      inputSchema: AgentTools._schema({
        'account_id': {
          'type': 'integer',
          'description': 'Only this broker or place',
        },
        'holding_id': {
          'type': 'integer',
          'description': 'Only this holding, with its trades',
        },
        'include_trades': {'type': 'boolean', 'default': false},
        'include_archived': {'type': 'boolean', 'default': false},
      }),
      handler: _listPortfolio,
    ),
    AgentTool(
      name: 'find_security',
      title: 'Find a stock, fund or coin',
      description:
          'Searches the price sources the app uses (Yahoo Finance for '
          'stocks, ETFs and funds worldwide, AMFI for Indian mutual funds, '
          'CoinGecko for crypto) and returns the name, symbol, exchange and '
          'price_source to give add_holding. For kind metal it lists the '
          'metals (gold, silver, platinum, palladium) and their usual '
          'purities. Search by name or ticker; funds outside India are found '
          'by their exact name (e.g. "Vanguard 500 Index"). Reads the '
          'internet through the phone; nothing is saved.',
      inputSchema: AgentTools._schema(
        {
          'query': {'type': 'string'},
          'kind': {
            'type': 'string',
            'enum': [for (final k in HoldingKind.selectable) k.name],
            'default': 'stock',
          },
          'account_id': {
            'type': 'integer',
            'description':
                'The broker it is for; its currency decides which funds '
                'are offered',
          },
          'currency': {
            'type': 'string',
            'description': 'Instead of account_id: ISO code, e.g. INR',
          },
        },
        required: ['query'],
      ),
      handler: _findSecurity,
    ),
    AgentTool(
      name: 'suggest_portfolio_changes',
      title: 'Suggest portfolio changes',
      description:
          'Adds, records or fixes investments, for the user to approve. '
          'Holdings sit under a broker or in-hand place from list_portfolio '
          '(add those with suggest_account_changes, place). action: '
          'add_holding (account_id, kind, name, symbol and exchange and '
          'price_source from find_security; for a metal: metal and purity '
          'instead of symbol; optionally units, price and date to record '
          'what is owned as its first buy); edit_holding (holding_id and '
          'only the fields to change); buy or sell (holding_id, units, '
          'price per unit in the holding\'s currency, date, fees; buy may '
          'name pay_from_account_id, a bank, otherwise it is paid from the '
          'broker\'s funds; give amount when the holding is priced in '
          'another currency than the account); dividend (holding_id, amount '
          'received, date); set_price (holding_id, price: for a holding '
          'priced by hand); remove_trade (trade_id from list_portfolio); '
          'archive_holding or restore_holding; delete_holding (and every '
          'trade; prefer archive). A buy or sell moves the broker\'s funds '
          'like it does in the app, so check list_portfolio funds first and '
          'suggest the deposit (a transfer, suggest_transactions) if short. '
          'Metal units are grams. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'action': {
            'type': 'string',
            'enum': [for (final a in AgentPortfolioAction.values) a.toolName],
          },
          'account_id': {
            'type': 'integer',
            'description': 'For add_holding: the broker or place',
          },
          'holding_id': {'type': 'integer'},
          'trade_id': {'type': 'integer'},
          'kind': {
            'type': 'string',
            'enum': [for (final k in HoldingKind.selectable) k.name],
          },
          'name': {'type': 'string', 'maxLength': 60},
          'symbol': {
            'type': 'string',
            'description':
                'Ticker, AMFI scheme code or CoinGecko id, as find_security '
                'gives it',
          },
          'exchange': {'type': 'string'},
          'price_source': {
            'type': 'string',
            'enum': [
              PriceSourceId.yahoo,
              PriceSourceId.amfi,
              PriceSourceId.coingecko,
              PriceSourceId.metalWorld,
              PriceSourceId.forexRate,
              PriceSourceId.manual,
            ],
            'description': 'Left out, it follows from kind and symbol',
          },
          'currency': {
            'type': 'string',
            'description':
                'The currency of its price when not the account\'s, e.g. USD '
                'for a US stock in a rupee account',
          },
          'metal': {
            'type': 'string',
            'enum': [for (final m in MetalType.values) m.id],
          },
          'purity': {
            'type': 'string',
            'description':
                'Carats (22K) or parts per thousand (916), for any metal',
          },
          'icon': {
            'type': 'string',
            'description': 'An icon key from list_icons. Optional.',
          },
          'units': {
            'type': 'string',
            'description': 'Up to 6 decimals; grams for a metal',
          },
          'price': {
            'type': 'string',
            'description': 'Per unit (per gram for a metal), up to 4 decimals',
          },
          'amount': {
            'type': 'string',
            'description':
                'What it came to in the account\'s currency, if not units × '
                'price; the dividend received',
          },
          'fees': {'type': 'string'},
          'date': AgentTools._date,
          'pay_from_account_id': {
            'type': 'integer',
            'description': 'For buy: a bank, card or cash account to pay from',
          },
          'note': {'type': 'string'},
          'reason': AgentTools._reasonField,
        },
        required: ['action'],
      ),
      handler: _suggestPortfolioChanges,
    ),
    AgentTool(
      name: 'list_icons',
      title: 'List icons',
      description:
          'Icon keys for lender_icon and asset_icon: the app\'s own icons and '
          'bank and brand logos whose name contains query.',
      inputSchema: AgentTools._schema({
        'query': {'type': 'string'},
      }),
      handler: _listIcons,
    ),
    AgentTool(
      name: 'suggest_loan',
      title: 'Suggest a loan',
      description:
          'Sets up a loan from a statement or sanction letter, for the user '
          'to approve. Copy what it says; the app checks the sums and finds '
          'each payment in the ledger, so nothing is recorded twice. It also '
          'returns related_sms: bank SMS (saved, waiting for review or '
          'unparsed) that look like this loan\'s repayments but aren\'t in '
          'it. Ask the user which are, then call again adding those as '
          'payments. Calling again replaces the suggestion.',
      readOnly: false,
      inputSchema: AgentTools._schema(
        {
          'lender': {
            'type': 'string',
            'maxLength': 40,
            'description': 'Who lent it, e.g. Bajaj Finance',
          },
          'asset': {
            'type': 'string',
            'maxLength': 40,
            'description':
                'What it paid for, e.g. Phone. Leave out for a cash loan.',
          },
          'asset_icon': {
            'type': 'string',
            'description': 'From list_icons. The app picks one if left out.',
          },
          'lender_icon': {
            'type': 'string',
            'description': 'From list_icons. The app picks one if left out.',
          },
          'kind': {
            'type': 'string',
            'enum': [for (final k in LoanKind.values) k.name],
            'default': 'other',
            'description': 'other for a consumer or phone EMI',
          },
          'amount': {
            'type': 'string',
            'description': 'The loan amount, e.g. 25801.00',
          },
          'rate': {
            'type': 'number',
            'description':
                'Percent a year. 0 for no-cost EMI. Leave out if not stated.',
          },
          'months': {'type': 'integer', 'description': 'The tenure'},
          'emi': {
            'type': 'string',
            'description':
                'The regular instalment, without one-time charges. Leave out '
                'if there is no fixed instalment.',
          },
          'start_date': {
            ...AgentTools._date,
            'description': 'Loan creation or disbursal date, YYYY-MM-DD',
          },
          'first_due': {
            ...AgentTools._date,
            'description': 'First instalment due date, YYYY-MM-DD',
          },
          'end_date': {
            ...AgentTools._date,
            'description': 'Last instalment date, YYYY-MM-DD',
          },
          'outstanding': {
            'type': 'string',
            'description':
                'Principal still owed, from the statement. It checks the '
                'payments add up. With no payments, the loan starts from it.',
          },
          'unpaid_interest': {
            'type': 'string',
            'description': 'Interest due but unpaid, if the statement says',
          },
          'as_of': {
            ...AgentTools._date,
            'description': 'The statement date, YYYY-MM-DD',
          },
          'paid_from_account_id': {
            'type': 'integer',
            'description': 'From list_accounts',
          },
          'paid_from_last_digits': {
            'type': 'string',
            'description':
                'The repayment bank account number as the statement masks '
                'it, when you can\'t tell the account id.',
          },
          'received_in_account_id': {
            'type': 'integer',
            'description':
                'Where the money landed, for a cash loan. Leave out when the '
                'lender paid a seller.',
          },
          'charges': {
            'type': 'string',
            'description':
                'Fees at the start that are not inside a payment. Fees taken '
                'with an instalment go in that payment\'s fee instead.',
          },
          'charges_deducted': {
            'type': 'boolean',
            'description': 'The charges were taken off the money paid out',
          },
          'payments': {
            'type': 'array',
            'maxItems': 600,
            'description':
                'Every payment received, oldest first. Leave out bounced '
                'ones and dues.',
            'items': AgentTools._schema(
              {
                'date': AgentTools._date,
                'amount': {
                  'type': 'string',
                  'description': 'All that was paid, with any fee and interest',
                },
                'fee': {
                  'type': 'string',
                  'description': 'Fees inside amount, e.g. 569.00',
                },
                'interest': {
                  'type': 'string',
                  'description':
                      'Interest inside amount, if the statement says',
                },
                'part_payment': {
                  'type': 'boolean',
                  'description': 'Extra money, not an instalment',
                },
                'transaction_id': {
                  'type': 'integer',
                  'description':
                      'To correct the app\'s match, or a saved one from '
                      'related_sms the user confirmed',
                },
                'sms_id': {
                  'type': 'string',
                  'description':
                      'A needs_review or unparsed message from related_sms '
                      'the user confirmed is this payment. Approving saves it.',
                },
                'not_in_ledger': {
                  'type': 'boolean',
                  'description': 'Only to undo a wrong match',
                },
              },
              required: ['date', 'amount'],
            ),
          },
          'add_missing_to_account': {
            'type': 'boolean',
            'default': false,
            'description':
                'Add payments not found in the ledger to the paying account, '
                'changing its balance. Off, they count towards the loan only.',
          },
          'reason': AgentTools._reasonField,
        },
        required: ['lender', 'amount', 'start_date'],
      ),
      handler: _suggestLoan,
    ),
    AgentTool(
      name: 'suggest_debt_entries',
      title: 'Suggest debt entries',
      description:
          'Records money lent to or borrowed from a person, or paid back. '
          'lend: the user gave money. borrow: the user got money. collect: '
          'they paid the user back. repay: the user paid them back. With '
          'account_id the money moves through that account; without, it is '
          'only a record. The app looks for the payment in the ledger first '
          'and says if it may already be saved. Changes nothing until '
          'approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'person': {
            'type': 'string',
            'maxLength': 40,
            'description': 'Their name. A new name adds a person.',
          },
          'person_id': {
            'type': 'integer',
            'description': 'From list_debts, instead of person',
          },
          'kind': {
            'type': 'string',
            'enum': [for (final k in DebtKind.values) k.name],
          },
          'amount': {'type': 'string'},
          'date': AgentTools._date,
          'due_date': {
            ...AgentTools._date,
            'description': 'For lend and borrow, YYYY-MM-DD',
          },
          'account_id': {'type': 'integer'},
          'currency': {
            'type': 'string',
            'description': 'Only without an account',
          },
          'transaction_id': {
            'type': 'integer',
            'description': 'The saved transaction this entry is',
          },
          'ignore_matches': {
            'type': 'boolean',
            'description': 'It is a different payment from those the app found',
          },
          'note': {'type': 'string'},
          'reason': AgentTools._reasonField,
        },
        required: ['kind', 'amount', 'date'],
      ),
      handler: _suggestDebtEntries,
    ),
  ];
}
