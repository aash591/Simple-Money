"""Give each private unmatched SMS an approximate, body-free review reason.

Run from app/: python tool/explain_unmatched_sms.py
Results are local, gitignored, and deliberately contain no message body or value.
These reasons aid review; they are not parser decisions.
"""

from collections import Counter
import json
from pathlib import Path
import re


ROOT = Path(__file__).resolve().parent.parent.parent
ARCHIVES = ROOT / "artifacts" / "sms"
REASONS = {
    "possible_transaction_variant": "Looks like a completed transaction, but its wording is not covered by a validated rule.",
    "security_or_setup": "Security code or account setup message; no completed transaction should be imported.",
    "future_or_offer": "Offer, upcoming bill, or payment request; it does not confirm a completed transaction.",
    "account_notice": "Account, card, reward, KYC, or balance notice rather than a clear new transaction.",
    "failed_or_reversed": "Failed, declined, cancelled, or reversed activity needs separate handling.",
    "no_supported_amount": "No amount in a supported money format accompanies a confirmed transaction.",
    "amount_without_completion": "An amount appears, but the wording does not clearly confirm a completed debit or credit.",
    "unclear": "The wording needs manual review before a safe transaction rule can be added.",
}
MONEY = re.compile(r"(?:\brs\.?\s*\d|\binr\s*\d|₹\s*\d)", re.I)
COMPLETED = re.compile(
    r"\b(?:debited|credited|spent|withdrawn|paid|deposited|transferred)\b"
    r"|\breceived payment\b|\bpayment of\b.{0,70}\b(?:processed|received)\b",
    re.I,
)
FAILED = re.compile(r"\b(?:failed|declined|cancelled|reversed|reversal|unsuccessful)\b", re.I)
FUTURE = re.compile(
    r"\b(?:due|offer|eligible|preapproved|pre-approved|apply now|pay by|payment request|request to pay|will be|cashback offer)\b",
    re.I,
)
SECURITY = re.compile(
    r"\b(?:otp|one.time.password|verification code|set your pin|reset your pin|upi pin)\b",
    re.I,
)
NOTICE = re.compile(
    r"\b(?:kyc|statement|balance|reward points|registered|linked|limit|mandate|welcome|charges|account opening|card activation)\b",
    re.I,
)


def reason(body: str) -> str:
    if FAILED.search(body):
        return "failed_or_reversed"
    lowered = body.lower()
    if ("pay your bill" in lowered and "bill has" in lowered) or (
        "outstanding" in lowered and "emi" in lowered
    ):
        return "future_or_offer"
    if COMPLETED.search(body) and MONEY.search(body) and not re.search(r"\b(?:will|would|could)\b.{0,30}\b(?:be\s+)?(?:debited|credited|paid)\b", body, re.I):
        return "possible_transaction_variant"
    if SECURITY.search(body):
        return "security_or_setup"
    if FUTURE.search(body):
        return "future_or_offer"
    if NOTICE.search(body):
        return "account_notice"
    if not MONEY.search(body):
        return "no_supported_amount"
    if not COMPLETED.search(body):
        return "amount_without_completion"
    return "unclear"


def main() -> None:
    combined = Counter()
    by_device = {}
    by_sender = {}
    for directory in sorted(ARCHIVES.iterdir()):
        ids_path = directory / "unmatched-ids.jsonl"
        if not ids_path.exists():
            continue
        source = directory / "all_sms.jsonl"
        if not source.exists():
            source = directory / "inbox.jsonl"
        ids = {row["smsId"]: row["senderFamily"] for row in map(json.loads, ids_path.open(encoding="utf-8"))}
        explanations = []
        for row in map(json.loads, source.open(encoding="utf-8-sig")):
            if row["smsId"] not in ids:
                continue
            code = reason(row["body"])
            explanations.append({
                "smsId": row["smsId"],
                "senderFamily": ids[row["smsId"]],
                "reasonCode": code,
                "reason": REASONS[code],
            })
        if len(explanations) != len(ids):
            raise ValueError(f"Unmatched ID count mismatch in {directory}")
        (directory / "unmatched-explanations.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in explanations), encoding="utf-8"
        )
        counts = Counter(row["reasonCode"] for row in explanations)
        for row in explanations:
            by_sender.setdefault(row["senderFamily"], Counter())[row["reasonCode"]] += 1
        combined.update(counts)
        by_device[directory.name] = {"unmatched": len(explanations), "reasons": dict(counts)}
        (directory / "unmatched-summary.json").write_text(
            json.dumps({"unmatched": len(explanations), "reasons": dict(counts),
                        "reasonDescriptions": REASONS, "preliminary": True}, indent=2) + "\n",
            encoding="utf-8",
        )
        print(directory.name, len(explanations), dict(counts))
    (ARCHIVES / "unmatched-summary.json").write_text(
        json.dumps({"unmatched": sum(combined.values()), "reasons": dict(combined),
                    "byDevice": by_device,
                    "bySender": {key: dict(value) for key, value in sorted(by_sender.items())},
                    "reasonDescriptions": REASONS,
                    "preliminary": True}, indent=2) + "\n",
        encoding="utf-8",
    )


if __name__ == "__main__":
    main()
