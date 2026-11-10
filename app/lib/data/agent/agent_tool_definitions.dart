part of 'agent_tools.dart';

/// MCP schemas and descriptions, separate from execution and validation.
extension _AgentToolDefinitions on AgentTools {
  List<AgentTool> _createTools() => [
    AgentTool(
      name: 'list_accounts',
      title: 'List accounts',
      description:
          'The user\'s accounts (bank, credit card, cash) with id, currency, '
          'balance and the last digits of the account number when known.',
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
          'SMS text, what the parser read from it, and the account and '
          'category currently chosen. ready=false means it still needs an '
          'account or category. Use suggest_sms_corrections to fix them.',
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
          '"Food › Swiggy"). Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'sms_id': {'type': 'string'},
          'account_id': {'type': 'integer'},
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'dismiss': {'type': 'boolean'},
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
          'Proposes a new category, account, title or note for saved '
          'transactions (ids from search_transactions). Amounts and dates '
          'can\'t be changed this way. A new account must use the same '
          'currency. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'transaction_id': {'type': 'integer'},
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'account_id': {'type': 'integer'},
          'title': {'type': 'string', 'maxLength': 80},
          'note': {'type': 'string'},
          'reason': AgentTools._reasonField,
        },
        required: ['transaction_id'],
      ),
      handler: _suggestTransactionEdits,
    ),
    AgentTool(
      name: 'suggest_transactions',
      title: 'Suggest new transactions',
      description:
          'Proposes new expenses or income to add (from a receipt, a '
          'statement line, or what the user tells you). Give the account '
          '(list_accounts), the amount in that account\'s currency, and a '
          'category by id or name. The date defaults to today. Refuses one '
          'that looks already saved. Changes nothing until approved.',
      readOnly: false,
      inputSchema: AgentTools._items(
        {
          'type': {
            'type': 'string',
            'enum': ['expense', 'income'],
            'default': 'expense',
          },
          'amount': {
            'type': 'string',
            'description': 'Decimal amount, e.g. 250.00',
          },
          'account_id': {'type': 'integer'},
          'category_id': {'type': 'integer'},
          'category_name': {'type': 'string'},
          'title': {'type': 'string', 'maxLength': 80},
          'note': {'type': 'string'},
          'date': AgentTools._date,
          'ignore_duplicates': {'type': 'boolean', 'default': false},
          'reason': AgentTools._reasonField,
        },
        required: ['amount', 'account_id'],
      ),
      handler: _suggestTransactions,
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
          'and the messages it reads join the SMS review queue. Same input '
          'as test_parser_rule, plus a reason.',
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
          'account, payee, reference when present. The app builds the rule, '
          'tests it on the other missed messages from that sender, and '
          'suggests it for the user to approve.',
      readOnly: false,
      inputSchema: AgentTools._schema(
        {
          'sms_id': {'type': 'string'},
          'amount': {
            'type': 'string',
            'description': 'Exactly as in the SMS, e.g. 1,250.00',
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
                'The bank\'s name as the SMS signs it, e.g. Fincare SFB. '
                'Only if asked for.',
          },
        },
        required: ['sms_id', 'amount', 'direction', 'channel'],
      ),
      handler: _labelSms,
    ),
    AgentTool(
      name: 'list_statements_to_map',
      title: 'List statement layouts to map',
      description:
          'Statement files the app couldn\'t read by itself: each one\'s id, '
          'column names and a few rows. Map one with map_statement.',
      inputSchema: AgentTools._schema({}),
      handler: _listStatementsToMap,
    ),
    AgentTool(
      name: 'map_statement',
      title: 'Map a statement layout',
      description:
          'Says which column is which in a statement from '
          'list_statements_to_map. Use names from column_names. Give date, '
          'description, and either amount or debit and credit. Each call '
          'adds to the one before ("none" clears a field). The app previews '
          'the rows and suggests the layout for the user to approve.',
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
          'reason': AgentTools._reasonField,
        },
        required: ['name', 'amount', 'account_id'],
      ),
      handler: _suggestRecurringPayments,
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
          'each payment in the ledger, so nothing is recorded twice. Calling '
          'again replaces the suggestion.',
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
                  'description': 'Only to correct the app\'s match',
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
