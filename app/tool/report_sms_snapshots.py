"""Recheck private phone archives without copying message bodies into reports.

Run from app/: python tool/report_sms_snapshots.py
The archives and generated reports remain under gitignored artifacts/sms/.
"""

from collections import Counter
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
import shutil
import subprocess


APP = Path(__file__).resolve().parent.parent
ROOT = APP.parent
ARCHIVES = ROOT / "artifacts" / "sms"
MANIFEST = APP / "packages/universal_bank_sms_parser/distribution/manifest.json"


def digest(path: Path) -> str:
    return sha256(path.read_bytes()).hexdigest()


def analyze(path: Path) -> tuple[dict, list[dict]]:
    messages = []
    source_ids = []
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        row = json.loads(line)
        if row.get("type", 1) != 1:
            continue
        source_ids.append(row["smsId"])
        messages.append({
            "sender": row.get("sender", row.get("address")),
            "receivedAt": row.get("receivedAtMs", row.get("dateMs")),
            "body": row["body"],
        })
    payload = "".join(json.dumps(message) + "\n" for message in messages)
    process = subprocess.run(
        [shutil.which("dart") or "dart", "run", "tool/diagnose_sms_inbox.dart", "--per-message"],
        cwd=APP,
        input=payload,
        text=True,
        capture_output=True,
        check=True,
    )
    decisions = [json.loads(line) for line in process.stdout.splitlines()]
    if len(decisions) != len(messages):
        raise ValueError(f"Decision count mismatch for {path}")
    reasons = Counter(row["reason"] for row in decisions)
    completed = Counter(
        row["family"] for row in decisions
        if row["reason"] == "completedNeedsReview"
    )
    unmatched = Counter(
        row["family"] for row in decisions
        if row["reason"] == "noMatchingFormat"
    )
    rules = Counter(
        row["ruleId"] for row in decisions if row["ruleId"] is not None
    )
    report = {
        "snapshotSha256": digest(path),
        "manifestSha256": digest(MANIFEST),
        "analyzedAtUtc": datetime.now(timezone.utc).isoformat(),
        "receivedCount": len(messages),
        "decisionCounts": dict(reasons),
        "completedBySender": dict(completed.most_common()),
        "unmatchedBySender": dict(unmatched.most_common()),
        "completedByRule": dict(rules.most_common()),
    }
    unmatched_rows = [
        {"smsId": source_ids[row["index"]], "senderFamily": row["family"]}
        for row in decisions if row["reason"] == "noMatchingFormat"
    ]
    return report, unmatched_rows


def main() -> None:
    for directory in sorted(ARCHIVES.iterdir()):
        if not directory.is_dir():
            continue
        path = directory / "all_sms.jsonl"
        if not path.exists():
            path = directory / "inbox.jsonl"
        if not path.exists():
            continue
        report, unmatched_rows = analyze(path)
        (directory / "analysis-latest.json").write_text(
            json.dumps(report, indent=2) + "\n", encoding="utf-8"
        )
        (directory / "unmatched-ids.jsonl").write_text(
            "".join(json.dumps(row) + "\n" for row in unmatched_rows),
            encoding="utf-8",
        )
        print(directory.name, report["decisionCounts"])


if __name__ == "__main__":
    main()
