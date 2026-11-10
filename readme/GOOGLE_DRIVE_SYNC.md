# Google Drive sync

The Android app continuously uploads changes from this device to the user's
hidden Google Drive application-data folder, and can restore the newest backup
after a reinstall or on a new phone. Everyday money tracking stays
offline-first. Snapshots and merging edits between devices are not
implemented in this release.

## Google setup

1. Create a Google Cloud project and enable **Google Drive API**.
2. Configure Google Auth Platform branding, audience, contact details and
   consent. Add your Google account as a test user while the project is in testing.
3. Register an **Android OAuth client** with the exact package name
   `com.aash591.SimpleMoney` and the SHA-1 of the certificate signing the APK.
   Register production/Play App Signing certificates before distributing it.
4. To test the seeded profile build, also register
   `com.aash591.SimpleMoney.profile` with its debug signing certificate.
   Each installation creates its own mirror, so profile data does not replace
   a release installation's cloud data.
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
- While the app is active, pending edits are checked every three seconds.
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

Changing protection starts a new complete mirror. Existing Drive files are
preserved, so enabling encryption does not retroactively protect older
unencrypted copies. Disabling encryption requires the current PIN; older
encrypted copies still require their original PIN. Legacy backups remain
readable. This setting does not encrypt the local SQLite database or exports.

### Selecting data to restore

When a device links to a Google account for the first time (fresh install,
cleared data, new phone), or turns sync on with nothing entered yet, uploads
are held and Drive is checked for synced data before anything is sent. If the
phone has no accounts, transactions or budgets, that data is restored straight
away after any required backup PIN is entered. A phone with entries of its own is asked once whether to
use the synced data or keep its own. There is no manual restore button.

- Drive files are listed by `appProperties`, grouped by mirror ID and ordered by
  their newest file. This device's own mirror is skipped.
- Each mirror is rebuilt from its unbroken chain starting at sequence 1 (batches
  after a gap are ignored). The first mirror holding accounts, transactions or
  budgets is offered; mirrors with only default categories come from fresh
  installs and are skipped.
- On restore, the six ledger tables are replaced in one transaction
  (columns missing from older backups take their defaults) and the device starts
  a **new** mirror whose sequence 1 is the restored data. It never appends to the
  mirror it restored from, so two phones cannot write to the same chain.
- A backup written by a newer schema version is refused until the app is updated.
- Keeping the phone's own data uploads it as usual.

## Your data (More → Your data)

- **Export all data** saves every synced table as readable JSON
  (`format: simple-money-export`) wherever the user picks, via Android's file
  picker. **Export transactions** saves a UTF-8 CSV (with a BOM for Excel);
  text cells that start with `= + - @` are prefixed with `'` so spreadsheets
  don't run them as formulas.
- **Import from file** reads only that export format, keeps known tables and
  columns, and replaces the ledger after a confirmation. It goes through the
  same replace-and-new-mirror step as a restore, so imported data syncs up as
  the phone's new copy.
- **Delete data on this phone** clears the ledger and restores the default
  categories. The Drive copy is untouched; the phone continues on a new mirror.
- **Delete data from Google Drive** turns sync off first (so nothing uploads
  mid-wipe), deletes every SimpleMoney file in the app folder, and resets the
  mirror so turning sync on again uploads a full fresh copy.
- All of these take the upload lease first, waiting out an upload already in
  flight.

## Persistence and cloud format

Schema version 8 adds `sync_state`, `sync_outbox`, `sync_batch` and triggers for
accounts, categories, transactions, budgets, budget-category links and monthly
budget amounts. Triggers capture each insert/update/delete in the same database
transaction as the ledger. Repeated offline changes to a record are coalesced;
deletions retain tombstones. Preferences such as temporary transaction filters
are not part of the database mirror.

Each upload freezes the whole committed outbox into an immutable gzip JSON batch,
wrapped in an authenticated encrypted envelope when encryption is enabled.
Its Drive file ID and exact bytes are saved before network upload. A successful
upload is acknowledged only after checking its file ID, byte count and MD5
against Drive metadata. A lost response retries the same ID; HTTP 409 is checked
against the existing file. Acknowledgement clears only revisions included in the
batch, leaving edits made during upload pending.

The foreground app and background isolates share the Drift database connection.
A persisted, renewable two-minute lease serializes uploaders and recovers after
process death. Every installation uses a random `mirrorId`; an installation marker
in Android's no-backup directory also detects OS-restored database copies and
starts a separate, paused mirror on the new installation.

Files are named `simple-money-<mirrorId>-<12-digit sequence>.json.gz`. Drive
`appProperties` include format, mirror ID and sequence. Payloads contain:

```json
{
  "format": "simple-money-mirror",
  "formatVersion": 1,
  "schemaVersion": 8,
  "mirrorId": "random-installation-mirror-id",
  "sequence": 2,
  "previousSequence": 1,
  "createdAt": "2026-09-11T10:00:00.000Z",
  "changes": [
    {"table": "accounts", "key": [1], "row": {"id": 1, "name": "Cash"}},
    {"table": "budget_categories", "key": [4, 12], "row": null}
  ]
}
```

The abbreviated account row above illustrates the structure; real payloads
contain every column, including balances as exact integer minor units. The
recovery reader (`lib/data/backup/sync_restore.dart`) requires a continuous
sequence starting at 1, upserts complete rows by key and deletes null-row keys. It must
not sum account balances or replay transaction balance effects on top of the
stored balances. Local integer IDs are scoped by mirror ID, not globally shared
across phones.

This is an incremental journal representing the current cloud mirror, not a
single uploaded SQLite file. All batches are currently retained because recovery
requires the chain. Compaction and snapshot retention belong to the later backup
and restore implementation; deleting earlier batches now would break recovery.

## Validation

`flutter test test/drive_sync_test.dart` exercises offline coalescing, tombstones,
rollback, concurrent edits during upload, response loss, persistent retry after
database reopen, uploader ownership, account separation, migration from v7 and
Drive checksum verification. It also reconstructs all six ledger tables from
uploaded batches and compares them with the local database.

Live validation requires Google Cloud registration and a Google-enabled Android
device: connect, edit online, edit offline, restart, reconnect the network, and
check that pending changes clear only after upload. Repeat with the app closed
and inspect WorkManager if Android delays the job. Test revoked consent and a
full Drive account before release. Automated tests use a fake Drive transport;
they do not grant account access or upload any personal data.
