import '../../domain/bank_institution_icon.dart';
import '../components/app_icon.dart';

import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../state/account_store.dart';
import '../../state/sms_import_store.dart';
import '../components/feature_page.dart';
import '../../domain/currency_digits.dart';

String unassignedSmsGroup(PendingSmsImport sms) =>
    '${sms.bankName} \u00b7 ${sms.currency}${sms.creditCard ? ' \u00b7 Card' : ''}';

Future<List<PendingSmsImport>> loadUnassignedSms(SmsImportStore store) async {
  final result = <PendingSmsImport>[];
  for (var offset = 0; ; offset += 50) {
    final page = await store.review.page(offset: offset);
    result.addAll(
      page
          .where(
            (r) =>
                r.transaction.accountId == 0 &&
                r.transaction.toAccountId == null,
          )
          .map((r) => r.sms),
    );
    if (page.length < 50) break;
  }
  return result;
}

Future<Map<String, int>> unassignedSmsGroups(SmsImportStore store) async {
  final groups = <String, int>{};
  for (final sms in await loadUnassignedSms(store)) {
    groups.update(unassignedSmsGroup(sms), (n) => n + 1, ifAbsent: () => 1);
  }
  return groups;
}

class UnassignedSmsPage extends StatefulWidget {
  const UnassignedSmsPage({
    super.key,
    required this.store,
    required this.accounts,
    this.initialGroup,
  });
  final String? initialGroup;
  final SmsImportStore store;
  final AccountStore accounts;
  @override
  State<UnassignedSmsPage> createState() => _UnassignedSmsPageState();
}

class _UnassignedSmsPageState extends State<UnassignedSmsPage> {
  List<PendingSmsImport>? rows;
  String? group;
  String? error;
  bool saving = false;
  final selected = <String>{};
  String groupOf(PendingSmsImport sms) => unassignedSmsGroup(sms);
  @override
  void initState() {
    super.initState();
    group = widget.initialGroup;
    load();
  }

  Future<void> load() async {
    try {
      final result = await loadUnassignedSms(widget.store);
      if (mounted) {
        setState(() {
          rows = result;
          selected.clear();
          if (!result.any((s) => groupOf(s) == group)) group = null;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not load messages. Please try again.');
      }
    }
  }

  Future<void> assign() async {
    final chosen = rows!.where((s) => selected.contains(s.id)).toList();
    final accounts = widget.accounts.accounts
        .where(
          (a) =>
              !a.isArchived &&
              a.type != AccountType.cash &&
              a.digits == currencyDigits(a.currency) &&
              chosen.every(
                (s) =>
                    s.currency == a.currency &&
                    (!s.creditCard || a.type == AccountType.creditCard),
              ),
        )
        .toList();
    final id = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text('Assign ${selected.length} messages'),
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: Text(
              'Choose the account for these payments. Nothing is saved yet.',
            ),
          ),
          if (accounts.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('Create a matching bank account or card first.'),
            ),
          for (final account in accounts)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, account.id),
              child: ListTile(
                title: Text(account.name),
                subtitle: Text(
                  '${account.currency}${account.lastDigits == null ? '' : ' · ${account.lastDigits}'}',
                ),
              ),
            ),
        ],
      ),
    );
    if (id == null || !mounted) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final count = selected.length;
      await widget.store.repository.assignAccounts(Set.of(selected), id);
      await widget.store.reload();
      await load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '$count messages assigned. Review them before saving.',
            ),
          ),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not assign messages. Please try again.');
      }
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = rows?.where((s) => groupOf(s) == group).toList() ?? [];
    final groups = <String, int>{};
    for (final row in rows ?? <PendingSmsImport>[]) {
      groups.update(groupOf(row), (n) => n + 1, ifAbsent: () => 1);
    }
    return PopScope(
      canPop: !saving,
      child: FeaturePage(
        title: group ?? 'Match accounts',
        child: Column(
          children: [
            if (saving) const LinearProgressIndicator(),
            if (error != null)
              Padding(padding: const EdgeInsets.all(16), child: Text(error!)),
            Padding(
              padding: const EdgeInsets.all(18),
              child: Text(
                group == null
                    ? 'Bank found, but not the account. Messages without account digits (like **5566) need your help. Pick a bank below.'
                    : 'Bank found, but not the account. Select messages from the same account, then choose it.',
              ),
            ),
            if (group != null)
              Row(
                children: [
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => setState(() {
                            group = null;
                            selected.clear();
                          }),
                    child: const Text('Change bank / sender'),
                  ),
                  const Spacer(),
                  TextButton(
                    onPressed: saving
                        ? null
                        : () => setState(() {
                            if (selected.length == filtered.length) {
                              selected.clear();
                            } else {
                              selected.addAll(filtered.map((s) => s.id));
                            }
                          }),
                    child: Text(
                      selected.length == filtered.length
                          ? 'Deselect all'
                          : 'Select all',
                    ),
                  ),
                ],
              ),
            Expanded(
              child: rows == null
                  ? const Center(child: CircularProgressIndicator())
                  : groups.isEmpty
                  ? const Center(child: Text('No unassigned messages.'))
                  : group == null
                  ? ListView(
                      children: [
                        for (final entry in groups.entries)
                          ListTile(
                            leading: AppIcon(
                              bankInstitutionIcon(
                                entry.key.split(' \u00b7 ').first,
                                creditCard: entry.key.endsWith(' \u00b7 Card'),
                              ),
                              size: 34,
                            ),
                            title: Text(entry.key),
                            subtitle: Text('${entry.value} messages'),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => setState(() => group = entry.key),
                          ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (context, index) {
                        final sms = filtered[index];
                        return Card(
                          margin: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 5,
                          ),
                          child: Column(
                            children: [
                              CheckboxListTile(
                                value: selected.contains(sms.id),
                                onChanged: saving
                                    ? null
                                    : (value) => setState(() {
                                        if (value == true) {
                                          selected.add(sms.id);
                                        } else {
                                          selected.remove(sms.id);
                                        }
                                      }),
                                title: Text(
                                  '${sms.credit ? '+' : '-'}${formatAccountMoney(sms.amountMinor, currency: sms.currency, digits: sms.digits)}',
                                ),
                                subtitle: Text(
                                  '${sms.title}\n${sms.receivedAt.day}/${sms.receivedAt.month}/${sms.receivedAt.year} · ${sms.sender}',
                                ),
                              ),
                              ExpansionTile(
                                title: const Text('Original message'),
                                children: [
                                  Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(sms.body),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
            if (group != null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: saving || selected.isEmpty ? null : assign,
                    child: Text(
                      selected.isEmpty
                          ? 'Select messages'
                          : 'Assign ${selected.length} to account',
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
