# UPI payments

**Pay with UPI** is in the **Add transaction** menu by default. Turn it off
under **More › Settings › Google Pay option**; the choice persists on this
device. Turning it off hides the entry without deleting pending drafts.

The Android flow is:

1. Scan the recipient's UPI QR in the tall sheet below the SimpleMoney header.
2. Enter or confirm the prefilled amount, then select an expense category and
   an INR account for the expense record.
3. On **Share QR to pay**, choose Google Pay. A four-second toast says
   **Maximum ₹2,000 for QR-image payments in Google Pay**.
4. Generate a temporary black-on-white QR PNG from the scanned payment data and
   selected amount. Share that image directly to Google Pay.
5. Return and confirm payment success. Yes saves the expense; No offers
   **Keep pending** or **Delete**.

There is no phone/contact entry and no payment-link launch. Previously saved
phone drafts remain readable for confirmation or deletion. Other installed
UPI apps remain available under the fallback to open an app and scan the
original QR there.

## Image handoff

`upi_qr_image.dart` renders the QR locally with integer-sized modules and a
four-module quiet zone. All original QR fields and their encoding are retained
except an entered/changed amount and a missing INR currency. Signed QR amounts
are fixed. No merchant codes or transaction references are fabricated.

`UpiBridge.kt` writes the PNG to a private `cache/upi_qr` file. A narrowly scoped,
non-exported FileProvider shares its content URI with Google Pay using
`ACTION_SEND`, `image/png`, `EXTRA_STREAM`, `ClipData` and temporary read access.
It requires no gallery/storage/contact permission and uses no image-generation
service. Old cached images are removed on a subsequent share after 24 hours or
by Android. A successful share is never treated as payment confirmation.

Google Pay documents [gallery QR payments and a ₹2,000 limit](https://support.google.com/pay/india/answer/7296045?hl=en-IN).
Its public docs do not guarantee this third-party image-sharing integration.
Confirm acceptance on the installed Google Pay version. This flow does not
establish or bypass the cause of the previously reported payment-limit error.

## Matching the bank SMS

The bank's debit SMS for a confirmed UPI expense is the same payment, not a
second one (`upi_sms_match.dart`). A match needs the same amount in INR, a
debit, and an SMS received from 5 minutes before to 1 hour after the draft
was started. If the SMS's bank is linked to an account, it must be the
account chosen for the payment. The nearest unmatched one is taken.

- **SMS after Yes:** the queued SMS joins the expense. No review item or
  notification is created.
- **SMS before Yes:** confirming rewrites the SMS's expense with the chosen
  category, title and UPI note. The SMS text, date and amount are kept, so
  its notification stays valid. The toast says it matched the bank SMS.
- **SMS still waiting for review:** it joins the new expense. A balance the
  bank reported in that SMS is not reduced twice.

UPI transfers between own accounts are not matched.

## Drafts and validation

Drafts are persisted before sharing. Confirmation consumes the draft and posts
one expense in a single SQLite transaction, preventing duplicate saves. Pending
drafts do not change balances or budgets. They are device-local, excluded from
export/Drive sync, and cleared when the ledger is replaced or erased. Confirmed
expenses follow normal sync. Database schema 11 adds `pending_upi_payments`.

Tests cover preference persistence, More/Add transaction visibility, the toast
lifetime, PNG generation, image-channel arguments, QR field preservation,
handoff failure, draft recovery, confirmation/deletion, and migration. Generated
QR test PNGs were also decoded with an independent ZXing reader.

Before release, test camera permissions, receiving the shared image in Google
Pay, completing/cancelling payment, return confirmation and process-death
recovery on a real device. Automated tests use fake payment apps and make no
real payments.
