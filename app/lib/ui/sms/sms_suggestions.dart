export '../../domain/sms_matching.dart';
import '../../domain/bank_institution_icon.dart';
import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../state/sms_import_store.dart';

Account? smsAccount(
  PendingSmsImport sms,
  SmsImportStore store,
  List<Account> accounts,
) {
  final id =
      sms.data['assignedAccountId'] ??
      (sms.holdsMoney ? store.accountLinks[sms.bankKey] : null);
  return accounts
      .where(
        (a) =>
            a.id == id &&
            a.currency == sms.currency &&
            a.digits == sms.digits &&
            a.archivedAt == null,
      )
      .firstOrNull;
}

String smsBankIcon(PendingSmsImport sms) =>
    bankInstitutionIcon(sms.bankName, creditCard: sms.creditCard);
