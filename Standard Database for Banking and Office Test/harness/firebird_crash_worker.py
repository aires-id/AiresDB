#!/usr/bin/env python3
"""Child process intentionally killed by the SDEBO recovery harness."""

from __future__ import annotations

import argparse
import os
import time
from pathlib import Path

from firebird.driver import connect, driver_config


def mark(path: Path, value: str) -> None:
    with path.open("w", encoding="ascii") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--firebird-root", type=Path, required=True)
    parser.add_argument("--stage", choices=["after_debit", "after_credit", "before_commit", "after_commit"], required=True)
    parser.add_argument("--marker", type=Path, required=True)
    parser.add_argument("--amount", type=int, default=1)
    args = parser.parse_args()

    os.environ["PATH"] = str(args.firebird_root) + os.pathsep + os.environ.get("PATH", "")
    driver_config.fb_client_library.value = str(args.firebird_root / "fbclient.dll")
    connection = connect(str(args.database), user="SYSDBA", password="masterkey", charset="UTF8")
    cursor = connection.cursor()
    cursor.execute("update accounts set balance_cents = balance_cents - ? where account_id = 1", (args.amount,))
    if args.stage == "after_debit":
        mark(args.marker, args.stage)
        time.sleep(60)
    cursor.execute("update accounts set balance_cents = balance_cents + ? where account_id = 2", (args.amount,))
    if args.stage in {"after_credit", "before_commit"}:
        mark(args.marker, args.stage)
        time.sleep(60)
    connection.commit()
    if args.stage == "after_commit":
        mark(args.marker, args.stage)
        time.sleep(60)
    connection.close()


if __name__ == "__main__":
    main()
