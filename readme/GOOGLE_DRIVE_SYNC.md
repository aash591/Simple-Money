# Google Drive sync

The Android app keeps every phone signed in to the same Google account in
sync through the user's hidden Google Drive application-data folder, in both
directions, and can restore after a reinstall or on a new phone. Everyday
money tracking stays offline-first.

The design follows Cashew's Drive sync: each phone writes only its own files,
so two phones never overwrite each other, and each phone merges the others'
files record by record, the newest version winning. Unlike Cashew, a phone's
data is split into small **section files** (per small table, per month for
transactions and SMS, today on its own), so an upload replaces only what
changed, however big the ledger grows. Versions come from a hybrid logical
clock, not wall-clock modified times, and balances are rebuilt from each
account's base.

## Google setup

1. Create a Google Cloud project and enable **Google Drive API**.
2. Configure Google Auth Platform branding, audience, contact details and
   consent. Add your Google account as a test user while the project is in testing.
3. Register an **Android OAuth client** with the exact package name
   `com.aash591.SimpleMoney` and the SHA-1 of the certificate signing the APK.
   Register production/Play App Signing certificates before distributing it.
4. Debug, profile and release builds all use that package name, and are signed
   with the upload key in `secrets/android` when it is present, so the one
   OAuth client covers them. Register the upload key's SHA-1 too (`keytool -list
   -v -keystore secrets/android/upload-keystore.jks`). Without that key a build
   falls back to the debug key, whose SHA-1 differs on each machine. An app
   installed from Play is signed by Play App Signing instead, so a local build
   can't be installed over it: uninstall it first. The profile build seeds a
   sample ledger on a fresh install only.
5. Include these scopes in the project's data-access configuration:
   `https://www.googleapis.com/auth/drive.appdata`,
   `https://www.googleapis.com/auth/userinfo.email`,
   `https://www.googleapis.com/auth/userinfo.profile`, and `openid`.
6. Build/install the Android app. Tap **Sign in with Google** on the first-launch
   welcome screen (or **More → Sync**) and grant access. Add or edit a record,
   then check the last-sync time.

Run `./gradlew signingReport` from `app/android` to obtain development signing
fingerprints. The app currently uses debug signing for its release build;
production signing must be configured separately before distribution.

### Account picker closes after selecting an account

The authorization result must be parsed even when Android returns
`RESULT_CANCELED`: Google can put a failure status in that result. Only a real
cancellation should be hidden. The app now shows the Google status code for
other failures.

For Google error 8, inspect `adb logcat -d -s Auth.Api.Credentials
DriveAuthorization`. Error 8 alone is an internal error, not a specific diagnosis.
If the log includes `UNREGISTERED_ON_API_CONSOLE`, create or correct the Android
OAuth client in Google Auth Platform → Clients using the installed build's exact
package name and signing SHA-1. Obtain the fingerprint with `signingReport` as
described above; another developer machine or signing key can have a different
fingerprint. A Web OAuth client does not replace this Android registration.

This implementation uses native Google Identity **AuthorizationClient**, rather
than the Flutter Google Sign-In flow discussed during planning. Android package
and signing-certificate registration identify this client. It does not request
an ID token or a server authorization code, so **no Web client ID, client secret,
API key, Firebase configuration, or custom backend is embedded in the app**.

Sources: [Android authorization](https://developer.android.com/identity/authorization),
[Drive application data](https://developers.google.com/workspace/drive/api/guides/appdata),
[pre-generated file IDs](https://developers.google.com/workspace/drive/api/reference/rest/v3/files/generateIds).

## Behavior

- After connecting, the first upload contains all existing ledger records.
- While the app is open, edits go up within about a second (pending edits are checked every second), and the other phones' changes are checked every minute, in the app and after leaving it while Android keeps it running (then by the 15-minute background job). Opening the app, Sync now and pulling down History or the transactions list sync at once.
- **Uploads finish after leaving the app.** Each upload is also queued as a WorkManager job, expedited from Android 12 (it starts at once, even after the app is swiped from Recents) and a normal job before that. A lease left by an app process that's gone is taken over at once (leases carry the process ID).
- **A notification shows uploads worth seeing** (`SyncNotifications`):
  - "Saving to Google Drive" with progress, for an upload that takes over two seconds or is still running after leaving the app. It goes away when done.
  - "Changes waiting to upload", when one can't finish. It can be swiped away, and clears once they go up.
  - A quick upload in the app shows nothing. The channel is silent and low priority.
  Connection changes and app resume also trigger a retry.
- Android WorkManager schedules network-constrained one-off uploads and a
  periodic safety check with a 15-minute minimum interval. Android decides when
  background jobs run; battery restrictions, force-stop and lack of internet
  can delay them. Reopening the app triggers another attempt.
- Failed uploads use exponential backoff with jitter. Offline data survives
  process termination and restarts. Access tokens exist only in memory; Google
  Play services supplies fresh authorization in background without opening UI.
  Revoked access requires reconnecting from the screen.
- The Sync screen is one card: a status (Up to date / Syncing… with a progress
  ring / N changes waiting / error), the connected account, Sync now and Turn
  off sync. Turning sync off stops new uploads; a request already in flight may
  finish. It preserves local data, queued edits and cloud files, and does not
  revoke Google's account grant.
- A skippable welcome screen introduces sync once, on launch, to installs that
  never connected an account.
- Only verified uploads are protected against device loss.

## Restore

### Optional backup encryption

The Sync screen has an **Encrypt Drive backups** switch, off by default.
Enabling it asks for exactly six ASCII letters or digits, confirmation, and
acknowledgement that the PIN must be saved. Letters are case-sensitive.
Signing in again to restore an encrypted backup asks for its PIN. An incorrect
PIN, cancellation, or failed download leaves phone data unchanged and uploads
paused; **Continue restore** resumes the flow, including after an app restart.

Payloads use AES-256-GCM with fresh nonces and authenticated mirror/sequence
identifiers. PBKDF2-HMAC-SHA256 derives the key with a random 16-byte salt and
600,000 iterations. Only public recovery parameters accompany the backup;
the PIN is never saved and the derived key stays in platform secure storage,
excluded from Android backup. A six-character PIN has less guessing resistance
than a long password. There is no forgotten-PIN recovery for encrypted copies.

Changing protection uploads all of the phone's sections again, replacing the
copies on Drive, so enabling encryption also protects what was uploaded
before. Disabling encryption requires the current PIN. This setting does not
encrypt the local SQLite database or exports.

**Encryption is one setting for all of an account's phones.** Each section
file's metadata carries the uploading phone's choice: `enc` is `off` or a
short hash of the public key settings (`encryptionFingerprint`), and `encAt`
is when it was chosen. On each check a phone looks for the newest choice
among the other phones, compared by time, then on over off, then by hash, so
every phone settles on the same choice. Then:

- **The others turned it off.** This phone turns it off too, without a PIN
  (one was needed on the phone that turned it off).
- **They turned it on with a key this phone has.** It switches to that key.
- **They turned it on with a key it doesn't have.** The choice waits in
  `peer_encryption`, and the Sync screen shows **PIN needed** with
  *Enter PIN*. Until then this phone keeps uploading its own changes, and the
  other phones' locked files are skipped (and read once the PIN is in).
  Entering the PIN (`joinEncryption`) saves that key, switches to it and
  uploads everything again with it.
- **Turning encryption on while the others already use a PIN** asks for
  their PIN and reuses their key. A new key would lock the phones out of each
  other.
- **Two phones that turned it on separately** (each makes its own random
  salt, so the same PIN gives different keys) settle on the newer choice:
  the other phone asks for the PIN once.

The choice made here is kept in `encryption_at`, and following another
phone copies its time, so phones never bounce between choices. Section files
from before this carry time 0: on that tie encryption wins, so a phone whose
partner already had encryption on is asked for the PIN.

### Selecting data to restore

When a device links to a Google account for the first time (fresh install,
cleared data, new phone), or turns sync on with nothing entered yet, uploads
are held and Drive is checked for synced data before anything is sent. If the
phone has no accounts, transactions or budgets, that data is restored straight
away after any required backup PIN is entered. A phone with entries of its own
is asked once whether to use the synced data or keep its own.

- **Use the synced data**: the ledger is replaced by the most recently
  updated phone's file (one holding more than default categories), keeping
  each record's version. The next pull merges every other phone's file too.
- **Keep my data**: nothing is replaced. The phone uploads its own file and
  merges every other phone's file into its data, and they merge its file into
  theirs. Both sides end up with both sets of data.
- A file written by a newer schema version is refused until the app is
  updated.

## Your data (More → Your data)

- **Export all data** saves every synced table as readable JSON
  (`format: simple-money-export`) wherever the user picks, via Android's file
  picker. **Export transactions** saves a UTF-8 CSV (with a BOM for Excel);
  text cells that start with `= + - @` are prefixed with `'` so spreadsheets
  don't run them as formulas.
- **Import from file** reads only that export format, keeps known tables and
  columns, and replaces the ledger after a confirmation. If sync is on, it
  turns off: left on, the next merge would bring the other phones' records
  straight back. Turning it on again offers to keep the imported data, which
  then merges both ways.
- **Delete data on this phone** clears the ledger and restores the default
  categories. For the same reason, sync turns off; the Drive copy is untouched.
- **Delete data from Google Drive** turns sync off first (so nothing uploads
  mid-wipe), deletes every SimpleMoney file in the app folder, and forgets this
  phone's file, so turning sync on again creates it afresh. Another phone that
  is still syncing finds its file gone and creates it again on its next upload.
- All of these take the upload lease first, waiting out an upload already in
  flight.

## Persistence and cloud format

Triggers on every synced table record each insert, update and delete in the
same database transaction as the ledger:

- `sync_row_meta` keeps the version (HLC) of each record's latest change,
  deletions included. That is how a deletion reaches the other phones and
  can't come back.
- `sync_outbox` only says that something changed since the last upload; its
  count is the "changes waiting" on the Sync screen. A row with an empty table
  name asks for an upload with no edit (a new account, a restore, changed
  encryption).
- Changes merged in from another phone (`sync_state.applying = 1`) are
  neither queued nor restamped.

New rows get IDs from `newRowId`: milliseconds since 2025, shifted, plus an
11-bit device slot. Two phones can't create the same ID, even offline.

### Section files

Each phone's data is split into **sections**, one Drive file each, so an
upload only replaces the few small files whose records changed
(`lib/data/backup/sync_sections.dart`):

| Section | Holds |
|---|---|
| `accounts`, `categories`, `budgets`, … | one file per small table: all its records and deletions; `accounts` also carries each account's base |
| `transactions/2026-11`, `sms_history/2026-11` | records made in that UTC month (by `created_at` / `received_at`, never a date the user can edit, so a record stays in one file for good) |
| `transactions/2026-11-19` | records made today; the frequent uploads replace only this. Once the day is over it is folded into its month and deleted |
| `transactions/deleted/2026-11` | deletions made that month (a deleted record's own month is gone with it). Kept for good: a deletion never comes back |

Sizes, measured on 2 years of 20 transactions a day with their SMS:

- The whole ledger is about 2 MB compressed.
- One month's file is under ~80 KB, and today's file is a few KB.
- A normal sync uploads a few KB. Editing a two-year-old record uploads only its month.
- Nothing grows with years of history except the count of month files, about 12 a year.

**Uploading.** The queue says which records changed, and from that, which
sections (`uploadPlan`). Each is rebuilt from the database (`buildSection`),
one at a time, so a large ledger never has to fit in memory at once. Each file
gets the phone's next upload number (`sequence`), which only grows.

A file's ID is saved in `sync_files` before it is created. A create whose
response was lost returns 409 and is replaced instead, so there's never a
second copy. Each upload is checked against Drive's MD5 and size. The queue is
cleared, up to the revision the plan was made at, only after every section is
up; edits made meanwhile go up next. Empty sections never get a file. A file
deleted from Drive is made again.

`appProperties`: `format = simple-money-section-v3`, `mirrorId`, `section`,
`sequence`, and `rows` (so a restore can be offered from the listing alone).
The file is named `simple-money-<mirror>-<section>.json.gz`, or `.json.enc`
when encrypted; the encryption AAD binds the mirror ID and sequence. Payload:

```json
{
  "format": "simple-money-section",
  "formatVersion": 3,
  "schemaVersion": 50,
  "mirrorId": "random-installation-id",
  "section": "transactions/2026-11",
  "sequence": 412,
  "device": "Pixel 8",
  "createdAt": "2026-11-19T10:00:00.000Z",
  "tables": {"transactions": [{"id": 9, "amount_minor": 25000}]},
  "versions": {"transactions": {"[9]": 117146830340718600}},
  "bases": {}
}
```

### Merging (pull)

A check reads Drive's change log (`changes.list`) from where the previous one
stopped (`sync_state.changes_token`). The log shows a file the moment it's
uploaded, and an idle check returns nothing. A search (`files.list` with a
query) can lag several seconds behind an upload, so it isn't used for that.

The full list is read on resume, on Sync now and pulling a list down, and
hourly as a safety net. That pass also adds the change log's entries, so a
file the search hasn't caught up with is still seen, and it deletes this
phone's leftovers (its single file or batches from an older version, a stale
day file). An expired or unknown position (another account, a restore) starts
over with a full listing.

A forced check that comes while one is running waits for it, then runs, so
Sync now always fetches what is on Drive by then.

A file is downloaded only when its `sequence` is higher than the last merged
from that phone's section (`sync_peers`, keyed `<mirror>/<section>`). Small
tables go first, so accounts and categories arrive before the transactions
that use them. For each record:

- If this phone knows a version, the incoming one applies only when it is newer.
- If this phone never saw the record, it is added, whatever its version. That
  is what makes "keep my data" two-way.
- Deletions apply the same way; equal versions are skipped.

Account balances are recomputed from the newer base plus the merged
transactions. Each file is one database transaction. A record can sit in two
of a phone's files for a while (a deleted row still in its month, yesterday's
day file not yet removed); the newest version wins either way. A file replaced
or deleted mid-read is skipped and read on the next check.

### Restore

"Use the synced data" picks the most recently updated phone whose listing
shows data, reading just one small file to learn its encryption. It then
clears this phone and merges that phone's sections one by one, without
filling History. The next pull merges every other phone. Uploads stay held
until it finishes, so a restore cut short is simply run again.

### Older versions

Phones on the previous version keep one file (`simple-money-device-v2`), and
older ones a chain of batches (`simple-money-mirror-v1`). Both are still read
and merged. Once this phone's sections are up, it deletes its own old files.

## History (More › History)

Every add, edit and delete of a transaction is kept in `record_history`, with
the row before and after, by triggers on `transactions` (`historyTables`).
That covers changes made here, from SMS and UPI imports, and merged from
another phone; `device` names the other phone. Restores and imports don't
fill the log (`sync_state.history_off`). The newest 5,000 changes are kept.

The screen shows each change as its transaction row:

- **Tabs:** All, Added, Edited and Deleted, switched by swiping left and right or by tapping.
- **Sort (⋯):** newest change first (the default), oldest change first, transaction date, or amount. The first three group rows by day.
- **Look:** deleted and undone changes are faded.
- **Sync events:** turned on, restored, problems. They appear between the changes on All, when sorted by change time.

Tapping a change shows what changed and offers **Undo**:

- An addition is deleted.
- A deletion comes back.
- An edit goes back to how it was before.

The undo is saved as an edit made on this phone, so it syncs to the other
phones and shows in the log itself. Account balances move with the
transaction. If the record changed again since, the newer change has to be
undone first.

## Validation

`flutter test test/multi_device_merge_test.dart test/drive_sync_test.dart
test/activity_log_test.dart test/multi_device_sync_test.dart
test/backup_encryption_test.dart` covers:

- two-way merging, including a phone that kept its own data
- concurrent spending
- the newest edit winning
- deletions beating older edits
- hand-set balances
- transfers between new accounts
- only changed sections uploaded (an old edit replaces only its month; a new expense only today and accounts)
- yesterday's day file folded into its month
- one file per section, replaced in place
- recreating a deleted file
- idle checks downloading nothing
- edits during upload
- lost responses
- encryption
- reading older chains up to their first gap
- History: changes, undo, swipeable tabs and sorting

Live validation needs two Google-enabled Android phones on one account:

1. Add, edit and delete on each phone, online and offline, including an old record.
2. Check that both converge and that History names the other phone.
3. Undo a change on one phone and check that the other follows.
