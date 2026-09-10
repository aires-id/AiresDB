#!/usr/bin/env python3
"""Generate the deterministic SDEBO Revision 1.0 source dataset.

The files deliberately use a restricted pipe-delimited UTF-8 representation:
generated text never contains a pipe, quote, carriage return, or newline.  Both
engine runners consume these exact files and record their SHA-256 digests.
Monetary values are signed integer cents, which is an exact fixed-scale
representation supported by both engines.
"""

from __future__ import annotations

import argparse
import hashlib
import json
from datetime import date, datetime, timedelta
from pathlib import Path


SEED = 1999
PROFILES = {
    "M250": {
        "customers": 19_950,
        "accounts": 30_000,
        "transactions": 150_000,
        "employees": 5_000,
        "documents": 44_900,
        "branches": 50,
        "departments": 100,
    },
    "S750": {
        "customers": 49_950,
        "accounts": 75_000,
        "transactions": 500_000,
        "employees": 10_000,
        "documents": 114_900,
        "branches": 50,
        "departments": 100,
    },
}


def pseudo_checksum(kind: str, identity: int) -> str:
    value = f"SDEBO|{SEED}|{kind}|{identity}".encode("utf-8")
    return hashlib.sha256(value).hexdigest()


def write_rows(path: Path, header: tuple[str, ...], count: int, make_row) -> dict:
    digest = hashlib.sha256()
    with path.open("w", encoding="utf-8", newline="\n") as stream:
        encoded = ("|".join(header) + "\n").encode("utf-8")
        stream.buffer.write(encoded)
        digest.update(encoded)
        for identity in range(1, count + 1):
            row = tuple(str(value) for value in make_row(identity))
            if len(row) != len(header):
                raise RuntimeError(f"row width mismatch in {path.name}")
            encoded = ("|".join(row) + "\n").encode("utf-8")
            stream.buffer.write(encoded)
            digest.update(encoded)
    return {
        "file": path.name,
        "rows": count,
        "sha256": digest.hexdigest(),
        "bytes": path.stat().st_size,
        "columns": list(header),
    }


def generate(profile: str, output: Path) -> dict:
    counts = PROFILES[profile]
    output.mkdir(parents=True, exist_ok=False)
    base_day = date(2022, 1, 1)
    base_timestamp = datetime(2024, 1, 1)
    statuses = ("ACTIVE", "PENDING", "REVIEW", "BLOCKED", "CLOSED")
    channels = ("BRANCH", "ATM", "WEB", "MOBILE", "BATCH")
    account_types = ("SAVINGS", "CURRENT", "DEPOSIT", "LOAN", "ESCROW")
    roles = ("TELLER", "ANALYST", "OFFICER", "MANAGER", "AUDITOR")
    document_types = ("KYC", "INVOICE", "CONTRACT", "MEMO", "REPORT")

    tables = {}
    tables["branches"] = write_rows(
        output / "branches.psv",
        ("branch_id", "code", "city", "status"),
        counts["branches"],
        lambda i: (i, f"BR{i:03d}", f"City-{(i * 7 + SEED) % 31:02d}", statuses[i % 5]),
    )
    tables["departments"] = write_rows(
        output / "departments.psv",
        ("department_id", "name", "cost_center"),
        counts["departments"],
        lambda i: (i, f"Department-{i:03d}", f"CC{(i * 13 + SEED) % 997:03d}"),
    )
    tables["customers"] = write_rows(
        output / "customers.psv",
        ("customer_id", "branch_id", "name", "status", "risk_class", "created_at"),
        counts["customers"],
        lambda i: (
            i,
            1 + ((i * 17 + SEED) % counts["branches"]),
            f"Customer-{i:08d}-{chr(65 + i % 26) * (i % 19)}",
            statuses[(i * 3 + SEED) % 5],
            1 + ((i * 11 + SEED) % 5),
            (base_day + timedelta(days=(i * 23 + SEED) % 1461)).isoformat(),
        ),
    )
    tables["accounts"] = write_rows(
        output / "accounts.psv",
        ("account_id", "customer_id", "account_type", "balance_cents", "status", "opened_at"),
        counts["accounts"],
        lambda i: (
            i,
            1 + ((i * 13 + SEED) % counts["customers"]),
            account_types[(i * 7 + SEED) % 5],
            100_000 + ((i * 7_919 + SEED) % 10_000_000),
            statuses[(i * 5 + SEED) % 5],
            (base_day + timedelta(days=(i * 29 + SEED) % 1461)).isoformat(),
        ),
    )
    tables["transactions"] = write_rows(
        output / "transactions.psv",
        ("transaction_id", "account_id", "timestamp", "type", "amount_cents", "channel", "reference"),
        counts["transactions"],
        lambda i: (
            i,
            1 + ((i * 37 + SEED) % counts["accounts"]),
            (base_timestamp + timedelta(hours=(i * 13 + SEED) % 17_520)).isoformat(timespec="seconds"),
            "CREDIT" if (i + SEED) % 2 else "DEBIT",
            100 + ((i * 97 + SEED) % 100_000),
            channels[(i * 11 + SEED) % 5],
            f"TX-{SEED}-{i:012d}",
        ),
    )
    tables["employees"] = write_rows(
        output / "employees.psv",
        ("employee_id", "department_id", "branch_id", "name", "role", "salary_cents", "status"),
        counts["employees"],
        lambda i: (
            i,
            1 + ((i * 19 + SEED) % counts["departments"]),
            1 + ((i * 31 + SEED) % counts["branches"]),
            f"Employee-{i:07d}-{chr(65 + i % 26) * (i % 17)}",
            roles[(i * 3 + SEED) % 5],
            300_000_00 + ((i * 10_007 + SEED) % 2_000_000_00),
            statuses[(i * 7 + SEED) % 5],
        ),
    )
    tables["documents"] = write_rows(
        output / "documents.psv",
        ("document_id", "owner_type", "owner_id", "document_type", "title", "created_at", "checksum"),
        counts["documents"],
        lambda i: (
            i,
            "CUSTOMER" if (i + SEED) % 3 else "EMPLOYEE",
            1 + ((i * 43 + SEED) % (counts["customers"] if (i + SEED) % 3 else counts["employees"])),
            document_types[(i * 17 + SEED) % 5],
            f"Document-{i:09d}-{chr(65 + i % 26) * (i % 23)}",
            (base_day + timedelta(days=(i * 47 + SEED) % 1461)).isoformat(),
            pseudo_checksum("DOCUMENT", i),
        ),
    )

    combined = hashlib.sha256()
    for name in sorted(tables):
        entry = tables[name]
        combined.update(f"{name}|{entry['rows']}|{entry['sha256']}\n".encode("ascii"))
    manifest = {
        "specification": "SDEBO Revision 1.0",
        "profile": f"SDEBO-{profile}",
        "seed": SEED,
        "total_rows": sum(counts.values()),
        "representation": "UTF-8 pipe-separated text; money stored as signed integer cents",
        "tables": tables,
        "logical_source_sha256": combined.hexdigest(),
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=sorted(PROFILES), default="S750")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    manifest = generate(args.profile, args.output.resolve())
    print(json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
