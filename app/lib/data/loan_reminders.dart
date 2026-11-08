import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../domain/account.dart';
import '../domain/loan.dart';
import 'reminder_sync.dart';

/// Separate notification namespace: rescheduling loans must not cancel debts.
class LoanReminders {
  final _plugin = FlutterLocalNotificationsPlugin();
  Future<void> _queue = Future.value();
  Future<void>? _ready;
  static const _prefix = 'loan:';
  Future<void> _run(Future<void> Function() work) =>
      _queue = _queue.then((_) async {
        if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
        try {
          await work();
        } catch (_) {
          _ready = null;
        }
      });
  Future<void> _init() async {
    await _plugin.initialize(
      settings: const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_app_art'),
      ),
    );
  }

  Future<void> requestPermission() => _run(() async {
    await (_ready ??= _init());
    await _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >()
        ?.requestNotificationsPermission();
  });

  /// Loads come in bursts (startup, every ledger change); only the newest
  /// list is worth applying.
  int _requested = 0;

  Future<void> reschedule(List<Loan> loans) {
    final request = ++_requested;
    return _run(() async {
      await afterLaunch();
      if (request != _requested) return;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      await syncReminders(
        _plugin,
        namespace: 'loan',
        ensureReady: () => _ready ??= _init(),
        owns: (payload) => payload?.startsWith(_prefix) ?? false,
        details: _details,
        planned: [
          for (final loan in loans.where((l) => !l.closed && l.terms.remind))
            // Schedule a year ahead, including later EMIs if the oldest is
            // overdue. Payment and term changes replace all these.
            for (final row in reminderDates(loan, today))
              for (final days in [2, 0])
                if (DateTime(row.due.year, row.due.month, row.due.day - days, 9)
                    case final at when at.isAfter(now))
                  PlannedReminder(
                    id:
                        100000000 +
                        loan.id * 4096 +
                        row.number * 2 +
                        (days == 0 ? 1 : 0),
                    owner: '$_prefix${loan.id}',
                    at: at,
                    title:
                        '${loan.terms.lender} payment ${days == 0 ? 'due today' : 'in 2 days'}',
                    body: row.amount == 0
                        ? 'Check your lender statement for the amount due.'
                        : formatAccountMoney(
                            row.amount,
                            digits: loan.terms.digits,
                            currency: loan.terms.currency,
                          ),
                  ),
        ],
      );
    });
  }

  /// Reminders do not invent an allocation or a payoff schedule. Flexible
  /// loans can have a maturity reminder and an independent interest reminder.
  static List<LoanInstallment> reminderDates(Loan loan, DateTime today) {
    if (loan.schedule.isNotEmpty) {
      return loan.schedule
          .where((r) => !r.due.isBefore(today))
          .take(12)
          .toList();
    }
    final dates = <LoanInstallment>[];
    if (loan.terms.mode.amortises) {
      for (var i = 0; i < 600 && dates.length < 12; i++) {
        final due = loanMonth(loan.nextDue, i, loan.terms.day);
        if (!due.isBefore(today)) {
          dates.add(
            LoanInstallment(
              loan.paid + i + 1,
              due,
              0,
              loan.emi,
              loan.outstanding,
            ),
          );
        }
      }
    } else {
      final maturity = loan.terms.maturityDate;
      if (maturity != null && !maturity.isBefore(today)) {
        dates.add(LoanInstallment(1, maturity, 0, 0, loan.outstanding));
      }
      final reminder = loan.terms.interestReminderDate;
      if (reminder != null) {
        for (var i = 0; i < 600 && dates.length < 13; i++) {
          final due = loanMonth(reminder, i, reminder.day);
          if (maturity != null && due.isAfter(maturity)) break;
          if (!due.isBefore(today) && due != maturity) {
            dates.add(LoanInstallment(i + 2, due, 0, 0, loan.outstanding));
          }
        }
      }
    }
    return dates;
  }

  static const _details = NotificationDetails(
    android: AndroidNotificationDetails(
      'loan_due',
      'Loan reminders',
      channelDescription: 'Two days before a loan payment and on its due date',
    ),
  );
}
