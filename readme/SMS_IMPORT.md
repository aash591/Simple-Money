# Bank SMS import

On Android, Home ? **Read bank SMS** explains the feature and requests `READ_SMS`.
After enabling it, the inbox is scanned when the app opens or resumes, and with
**Scan inbox**. No SMS is sent, deleted, or uploaded by the inbox reader.

Home shows up to six completed transactions waiting to be categorized.
**View all** / **Show all** opens the full queue and offers a full inbox rescan
or **Stop reading SMS**. Pending items remain reviewable after stopping reads.

Tap a message, choose an expense/income category or a transfer between your own
accounts, and select the account(s). **Review details** opens the existing
transaction or transfer confirmation/edit flow. Amount, title/note, category,
accounts and date can be reviewed before saving. SMS does not show the UPI
completion question. UPI's existing completion flow remains separate.

## Implementation

- Native Android reads the inbox on a worker thread, returning at most 200 rows
  per page over `simple_money/sms_inbox`. Permission requests only follow a user
  action; no `RECEIVE_SMS` permission or background receiver is used.
- The universal Dart engine loads the bundled Indian runtime packs from the
  distribution manifest, verifies their sizes and SHA-256 hashes, then prepares
  the engine in an isolate. Parsing works offline. This integration does not
  fetch new rule packs from a CDN yet.
- The local `sms_imports` queue is outside the ledger's sync/backup tables.
  Unknown/rejected messages are discarded. Sender, body, timestamp and parsed
  fields are stored only for matching transactions; the body is cleared when
  imported or dismissed. Fingerprints prevent the same inbox message from
  reappearing on later scans.
- Schema v21 adds this queue and the opt-in/checkpoint state. Ledger creation and
  queue consumption commit in one database transaction. A retry cannot post the
  same queue item twice. Account currency and category type are validated.
- Each successful incremental scan overlaps the previous scan by one day.
  Interrupted scans retain their previous checkpoint; a full rescan is available
  if older messages were restored into the system inbox.

## Current scope

Inbox access is Android only. Indian rules are bundled. SMS dates currently use
message receipt time; the date is editable before saving. Accounts are chosen by
users, with the SMS account suffix displayed as a hint. This flow requires
accounts in the SMS currency with two decimal places, including both sides of
transfers. Separate SMS notifications for the two sides of a transfer remain
separate queue items; dismiss the second after recording the transfer once.

Tests: `flutter test test/sms_import_test.dart` covers bundled rules, migration,
permissions, pagination, interrupted scans, deduplication, atomic saves and
category/transfer review UI.

## Physical Android verification

`integration_test/sms_inbox_test.dart` runs against the installed app package
with an in-memory ledger. The test checks denied inbox access, then (in a
separate granted run) scans the native inbox, reviews one parsed item, saves a
transaction, and verifies a full rescan does not requeue it. If the phone has no
matching bank message, the test uses a local SBI fixture for the review steps;
it does not insert a message into the phone inbox. The run reports only inbox
and parsed-item counts, never message content.

On the Android 16 test phone, the permission-denied read passed. After
adding three sanitized rule formats for SBI, Kotak, and Union Bank, the granted
read returned 45 inbox rows on its first page and parsed three real INR
transactions. One real message completed the on-device review, save, and full
rescan test using an in-memory ledger. No live SMS body or financial detail was
printed during diagnosis or testing.

On a second Android 16 phone, a read-only local check decoded 5,327 inbox
rows and passed them directly to the Dart engine in memory. The existing packs
recognized 97 completed transactions. Six additional HDFC and Federal Bank
rules first raised that to 1,047 completed transaction candidates. A second
pass over the remaining formats raised the total to 1,144 and classified
additional statements, due reminders, security messages, and carrier data
alerts as ignored. The remaining 195 messages from registered senders have
unknown formats; they are not all completed transactions, and this is not full
inbox coverage. The phone's installed app and ledger were not changed for this check;
the new rules are in the bundled development packs for the next app build.
No SMS content or financial values were saved to a diagnostic file.
