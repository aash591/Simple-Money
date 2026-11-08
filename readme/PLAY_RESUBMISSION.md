# Play resubmission: Simple Money (com.aash591.SimpleMoney)

Rejected for the SMS/Call Log policy: listing didn't match the declared use case, and core functionality couldn't be verified.

## Store listing text

**Short description (80 chars max)**
Track spending automatically from your bank SMS. Private, on your device.

**Full description (opening, then the rest as before)**
Simple Money records your spending for you. With your permission, it reads the SMS on your phone, including new ones as they arrive, and picks out the messages from your bank. Each debit or credit becomes a transaction with the amount, date, account and merchant filled in.

Reading bank SMS is the main feature of the app. Without SMS access you can still add transactions by hand.

Your privacy
• Bank messages are read and processed on your device only.
• Messages are never uploaded, sold or shared.
• OTPs and personal messages are ignored and not stored.
• You can turn SMS reading off at any time in More › Settings.

Privacy policy: https://aashglobal.in/privacy (update the URL if the page lives elsewhere)

Screenshots to show: the "Enable Automatic Detection" screen, a transaction list with SMS-detected entries, and the account list found by the first scan.

## Permissions Declaration Form

Play Console › Policy and programs › App content › Sensitive app permissions › SMS or Call Log permissions.

- Permissions: READ_SMS, RECEIVE_SMS
- Core functionality: tracking financial transactions from bank SMS (read bank SMS and add them as transactions automatically)
- Why no alternative works: transaction details exist only in the bank's SMS; the app has no bank login or API.
- Data handling: processed on device, not sold, shared or uploaded.

**Instructions for reviewers** (paste into the form)

1. Install the app and open it. Tap "Get started".
2. Skip the Google backup step (top right "Skip").
3. On "Enable Automatic Detection", read the disclosure and tap "Enable Permissions". Allow SMS and notifications.
4. The app scans existing SMS and lists any bank accounts it finds. On a device with no bank SMS, nothing is found; use step 5.
5. Send the test SMS below to the test device (or use an emulator: Extended controls › Phone › SMS). A new transaction appears within seconds under Home / Transactions.
6. To turn it off: More › Settings › "Transactions from SMS" switch, or Android Settings › Apps › Simple Money › Permissions.

Test SMS (an HDFC-style debit alert):
`Your AC XXXXX1234 Debited INR 25.00 on 11/10/26 -CDM CHARGE DR. Avl Bal INR 9,876.54.-SBI`

This is the SBI sample from app/test/bank_sms_parser_test.dart. Confirm on a real build that it shows up before you submit.

## Demo video (unlisted YouTube, 1-2 min)

1. Fresh install, tap Get started, skip backup.
2. Show the disclosure screen and tap Enable Permissions; show the system prompt and allow it.
3. Show the first-scan accounts, or send the test SMS and show the transaction appearing.
4. Open More › Settings and show the "Transactions from SMS" switch (turn it off, then on again).
5. Paste the video link into the declaration form.

## Checklist

- [ ] Deploy documentation/ so the new privacy page is live
- [ ] Listing text and screenshots updated
- [ ] Test SMS confirmed to be detected on a real build
- [ ] Video recorded and link added to the form
- [ ] Declaration form re-submitted with the new AAB
- [ ] Send for review from Publishing overview
