"""Print privacy-safe template clusters for one local SMS archive.

Usage from app/: python tool/review_unmatched_sms.py PATH FAMILY [REASON_CODE]
Unknown words and all numbers are replaced; raw bodies are never printed.
"""

from collections import Counter
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys


APP = Path(__file__).resolve().parent.parent
SAFE = set((
    "a ac account amount atm available balance bal bank bill card cash charged inr been "
    "credit credited debit debited due emi failed from in initiated limit "
    "mandate on otp paid payment processed received reward rewards rs sent "
    "spent successful successfully to transaction transfer txn upi withdrawn "
    "your for at by of has have was is the and points statement refund "
    "registered created you onecard federal sbi axis hdfc canara cash "
    "purchase spent ref number id with through thru via ending last total "
    "min max fee charges alert deposited deposit reversed reversal declined "
    "request approved complete completed pending offer available thank thanks "
    "auto outstanding pay outstanding minimum update new linked set "
    "today tomorrow day date time current earn earned welcome savings "
    "instant mobile netbanking using loan insurance kyc visit branch "
).split())


def skeleton(body: str) -> str:
    words = re.findall(r"[A-Za-z]+|\d+|@", body)
    result = [word.lower() if word.lower() in SAFE or word == "@" else "#" for word in words]
    return " ".join(result[:40])


def main() -> None:
    path = Path(sys.argv[1])
    family = sys.argv[2].upper()
    reason_code = sys.argv[3] if len(sys.argv) > 3 else None
    eligible_ids = None
    if reason_code:
        explanation_path = path.parent / "unmatched-explanations.jsonl"
        eligible_ids = {
            row["smsId"] for row in map(json.loads, explanation_path.open(encoding="utf-8"))
            if row["reasonCode"] == reason_code
        }
    rows = [json.loads(line) for line in path.read_text(encoding="utf-8-sig").splitlines()]
    rows = [row for row in rows if row.get("type", 1) == 1]
    payload = "".join(json.dumps({
        "sender": row.get("sender", row.get("address")),
        "receivedAt": row.get("receivedAtMs", row.get("dateMs")),
        "body": row["body"],
    }) + "\n" for row in rows)
    proc = subprocess.run(
        [shutil.which("dart") or "dart", "run", "tool/diagnose_sms_inbox.dart", "--per-message"],
        cwd=APP, input=payload, text=True, capture_output=True, check=True,
    )
    decisions = [json.loads(line) for line in proc.stdout.splitlines()]
    clusters = Counter(
        skeleton(rows[decision["index"]]["body"])
        for decision in decisions
        if decision["family"] == family and decision["reason"] == "noMatchingFormat"
        and (eligible_ids is None or rows[decision["index"]]["smsId"] in eligible_ids)
    )
    for template, count in clusters.most_common(30):
        print(count, template)


if __name__ == "__main__":
    main()
