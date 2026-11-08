"""Capture a connected Android phone's SMS provider into a private JSONL archive.

Run from app/: python tool/capture_sms_snapshot.py SERIAL DIRECTORY_NAME
Only counts and hashes are printed. The archive stays under gitignored artifacts/sms/.
"""

from collections import Counter
from datetime import datetime, timezone
from hashlib import sha256
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys


ROOT = Path(__file__).resolve().parent.parent.parent
ARCHIVES = ROOT / "artifacts" / "sms"


def adb(serial: str, *args: str) -> str:
    executable = shutil.which("adb") or str(
        Path(os.environ["LOCALAPPDATA"]) / "Android/Sdk/platform-tools/adb.exe"
    )
    result = subprocess.run(
        [executable, "-s", serial, *args],
        capture_output=True, check=True,
    )
    return result.stdout.decode("utf-8", errors="replace")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("Usage: capture_sms_snapshot.py SERIAL DIRECTORY_NAME")
    serial, name = sys.argv[1:]
    if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
        raise ValueError("Directory name may contain only letters, digits, _ and -")
    target = ARCHIVES / name
    if target.exists():
        raise FileExistsError(f"Snapshot already exists: {target}")
    target.mkdir(parents=True)

    props = {
        "manufacturer": adb(serial, "shell", "getprop", "ro.product.manufacturer").strip(),
        "model": adb(serial, "shell", "getprop", "ro.product.model").strip(),
        "androidVersion": adb(serial, "shell", "getprop", "ro.build.version.release").strip(),
    }
    ids_text = adb(serial, "shell", "content", "query", "--uri", "content://sms", "--projection", "_id")
    expected_ids = set(re.findall(r"(?m)^Row: \d+ _id=(\d+)\s*$", ids_text))
    full_text = adb(
        serial, "shell", "content", "query", "--uri", "content://sms",
        "--projection", "_id:address:date:type:body",
    )
    starts = list(re.finditer(r"(?m)^Row: \d+ _id=", full_text))
    rows = []
    for index, start in enumerate(starts):
        end = starts[index + 1].start() if index + 1 < len(starts) else len(full_text)
        item = full_text[start.start():end].rstrip("\r\n")
        match = re.fullmatch(
            r"Row: \d+ _id=(\d+), address=(.*?), date=(\d+), type=(\d+), body=(.*)",
            item, flags=re.DOTALL,
        )
        if match is None:
            raise ValueError(f"Unexpected provider row structure at index {index}")
        sms_id, address, date_ms, kind, body = match.groups()
        rows.append({
            "smsId": int(sms_id), "address": address,
            "dateMs": int(date_ms), "type": int(kind), "body": body,
        })
    captured_ids = {str(row["smsId"]) for row in rows}
    if len(rows) != len(expected_ids) or captured_ids != expected_ids:
        raise ValueError(
            f"Provider count/ID mismatch: expected {len(expected_ids)}, got {len(rows)}"
        )

    archive = target / "all_sms.jsonl"
    with archive.open("w", encoding="utf-8", newline="\n") as output:
        for row in rows:
            output.write(json.dumps(row, ensure_ascii=False) + "\n")
    counts = Counter(str(row["type"]) for row in rows)
    metadata = {
        "deviceName": name,
        **props,
        "source": "Android content://sms provider",
        "capturedAtUtc": datetime.now(timezone.utc).isoformat(),
        "messageCount": len(rows),
        "messageCountByType": dict(sorted(counts.items())),
        "format": "UTF-8 JSON Lines",
        "fields": ["smsId", "address", "dateMs", "type", "body"],
        "sha256": sha256(archive.read_bytes()).hexdigest(),
        "byteCount": archive.stat().st_size,
        "note": "Local private SMS snapshot; bodies are unredacted. No phone messages were modified.",
    }
    (target / "metadata.json").write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    print(name, "messages", len(rows), "by type", dict(counts), "sha256", metadata["sha256"])


if __name__ == "__main__":
    main()
