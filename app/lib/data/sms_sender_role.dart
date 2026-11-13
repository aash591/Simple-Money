/// Who sends an SMS, which decides whether it can name one of the user's
/// accounts. A bank, card issuer or wallet holds the money it reports on; a
/// shop, biller, lender or government office only says money moved, and the
/// account is the one the bank's own SMS names (or the user picks).
///
/// The role lives on each rule (bundled, the user's or shared), never in a
/// list of sender IDs, so it works in every country the rule packs cover.
library;

enum SmsSenderRole {
  bank,
  card,
  wallet,
  merchant,
  biller,
  lender,
  government,
  other;

  /// Whether the SMS speaks for an account of the user's at this sender.
  bool get holdsMoney => this == bank || this == card || this == wallet;

  static SmsSenderRole? tryParse(Object? value) =>
      value is String ? values.where((r) => r.name == value).firstOrNull : null;
}

/// The key a rule's format keeps its sender's role under. It is the app's,
/// not the rule spec's, so it is taken out before a format is compiled.
const smsSenderRoleKey = 'senderRole';

/// A rule's sender role. A rule saved before roles existed holds money only
/// if it reads an account number: one that reads none was most likely taught
/// from a shop's or biller's SMS, and an account named after it is wrong.
SmsSenderRole ruleSenderRole(Map<String, dynamic> format) =>
    SmsSenderRole.tryParse(format[smsSenderRoleKey]) ??
    switch (format['output']) {
      {'accountLast4': _} => SmsSenderRole.bank,
      _ => SmsSenderRole.other,
    };

/// [format] as the rule compiler takes it.
/// The app keeps who sends it and the country (`country`) there.
Map<String, dynamic> compilableFormat(Map<String, dynamic> format) =>
    format.containsKey(smsSenderRoleKey) || format.containsKey('country')
    ? ({...format}
        ..remove(smsSenderRoleKey)
        ..remove('country'))
    : format;

/// Marks a parsed message from a sender that holds no money of the user's.
/// An account number in it belongs to some bank, not to the sender: it is
/// kept apart as [otherAccountKey] (to find that account by) so the message
/// is never filed, or an account created, under the sender's name. Until an
/// account is given, it waits in review for the user to pick one.
void applySenderRole(Map<String, dynamic> data, SmsSenderRole role) {
  if (role.holdsMoney) return;
  data[smsSenderRoleKey] = role.name;
  // The shop or biller is who was paid (or who paid back): "Refund of
  // Rs.499 … -Meesho" names no payee because the sender is the payee.
  if (data['counterparty'] == null && data['bankName'] is String) {
    data['counterparty'] = data['bankName'];
  }
  if (data.remove('accountLast4') case final String last4) {
    data[otherAccountKey] = last4;
  }
  data['ambiguousAccount'] = true;
}

/// The account number a shop's or biller's SMS gave, e.g. "refunded to your
/// a/c XX1234": the bank's account, matched by its last digits.
const otherAccountKey = 'otherAccountLast4';

/// Whether parsed [data] came from a sender that holds the money.
bool dataHoldsMoney(Map<String, dynamic> data) =>
    SmsSenderRole.tryParse(data[smsSenderRoleKey])?.holdsMoney ?? true;
