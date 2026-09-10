#!/usr/bin/env python3
"""Run the SDEBO performance profile against Firebird Embedded."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import statistics
import subprocess
import time
from datetime import date, datetime
from decimal import Decimal
from fractions import Fraction
from pathlib import Path

import psutil
from firebird.driver import connect, create_database, driver_config


SEED = 1999
TABLE_ORDER = [
    "branches",
    "departments",
    "customers",
    "accounts",
    "transactions",
    "employees",
    "documents",
]

DDL = [
    "create table branches (branch_id bigint primary key, code varchar(8) not null unique, city varchar(40) not null, status varchar(16) not null)",
    "create table departments (department_id bigint primary key, name varchar(64) not null, cost_center varchar(16) not null unique)",
    "create table customers (customer_id bigint primary key, branch_id bigint not null, name varchar(96) not null, status varchar(16) not null, risk_class bigint not null, created_at date not null)",
    "create table accounts (account_id bigint primary key, customer_id bigint not null, account_type varchar(16) not null, balance_cents bigint not null, status varchar(16) not null, opened_at date not null)",
    "create table transactions (transaction_id bigint primary key, account_id bigint not null, timestamp_value timestamp not null, transaction_type varchar(16) not null, amount_cents bigint not null, channel varchar(16) not null, reference_value varchar(32) not null unique)",
    "create table employees (employee_id bigint primary key, department_id bigint not null, branch_id bigint not null, name varchar(96) not null, employee_role varchar(16) not null, salary_cents bigint not null, status varchar(16) not null)",
    "create table documents (document_id bigint primary key, owner_type varchar(16) not null, owner_id bigint not null, document_type varchar(16) not null, title varchar(128) not null, created_at date not null, checksum varchar(64) not null)",
    "create index customers_branch_status on customers(branch_id, status)",
    "create index accounts_customer on accounts(customer_id)",
    "create index transactions_account on transactions(account_id)",
    "create index employees_department on employees(department_id)",
]

INSERTS = {
    "branches": "insert into branches values (?, ?, ?, ?)",
    "departments": "insert into departments values (?, ?, ?)",
    "customers": "insert into customers values (?, ?, ?, ?, ?, ?)",
    "accounts": "insert into accounts values (?, ?, ?, ?, ?, ?)",
    "transactions": "insert into transactions values (?, ?, ?, ?, ?, ?, ?)",
    "employees": "insert into employees values (?, ?, ?, ?, ?, ?, ?)",
    "documents": "insert into documents values (?, ?, ?, ?, ?, ?, ?)",
}


def percentile_ns(values: list[int], fraction: float) -> float:
    ordered = sorted(values)
    return ordered[max(0, min(len(ordered) - 1, math.ceil(fraction * len(ordered)) - 1))] / 1e6


def latency(values: list[int]) -> dict:
    return {
        "count": len(values),
        "samples_ms": [value / 1e6 for value in values],
        "p50_ms": percentile_ns(values, 0.50),
        "p95_ms": percentile_ns(values, 0.95),
        "p99_ms": percentile_ns(values, 0.99),
        "errors": 0,
    }


def timed_samples(warmup: int, measured: int, operation) -> list[int]:
    for index in range(1, warmup + 1):
        operation(index)
    samples = []
    for index in range(1, measured + 1):
        started = time.perf_counter_ns()
        operation(warmup + index)
        samples.append(time.perf_counter_ns() - started)
    return samples


def parse_row(name: str, fields: list[str]) -> tuple:
    if name == "branches":
        return int(fields[0]), fields[1], fields[2], fields[3]
    if name == "departments":
        return int(fields[0]), fields[1], fields[2]
    if name == "customers":
        return int(fields[0]), int(fields[1]), fields[2], fields[3], int(fields[4]), date.fromisoformat(fields[5])
    if name == "accounts":
        return int(fields[0]), int(fields[1]), fields[2], int(fields[3]), fields[4], date.fromisoformat(fields[5])
    if name == "transactions":
        return int(fields[0]), int(fields[1]), datetime.fromisoformat(fields[2]), fields[3], int(fields[4]), fields[5], fields[6]
    if name == "employees":
        return int(fields[0]), int(fields[1]), int(fields[2]), fields[3], fields[4], int(fields[5]), fields[6]
    if name == "documents":
        return int(fields[0]), fields[1], int(fields[2]), fields[3], fields[4], date.fromisoformat(fields[5]), fields[6]
    raise RuntimeError(f"unknown SDEBO table {name}")


def rows_from_file(dataset: Path, name: str):
    with (dataset / f"{name}.psv").open("r", encoding="utf-8", newline="") as stream:
        next(stream)
        for line in stream:
            yield parse_row(name, line.rstrip("\n").split("|"))


def batched(source, size: int = 5_000):
    batch = []
    for row in source:
        batch.append(row)
        if len(batch) == size:
            yield batch
            batch = []
    if batch:
        yield batch


def canonical(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, datetime):
        return value.isoformat(timespec="seconds")
    if isinstance(value, date):
        return value.isoformat()
    return str(value)


def result_digest(rows) -> str:
    digest = hashlib.sha256()
    for row in rows:
        digest.update(("|".join(canonical(value) for value in row) + "\n").encode("utf-8"))
    return digest.hexdigest()


def aggregate_digest(rows) -> str:
    digest = hashlib.sha256()
    for row in rows:
        values = [str(row[0])]
        for value in row[1:]:
            fraction = Fraction(value) if isinstance(value, Decimal) else Fraction(int(value), 1)
            values.append(f"{fraction.numerator}/{fraction.denominator}")
        digest.update(("|".join(values) + "\n").encode("utf-8"))
    return digest.hexdigest()


def database_size(root: Path) -> int:
    return sum(path.stat().st_size for path in root.iterdir() if path.is_file())


def configure_client(firebird_root: Path) -> None:
    os.environ["PATH"] = str(firebird_root) + os.pathsep + os.environ.get("PATH", "")
    driver_config.fb_client_library.value = str(firebird_root / "fbclient.dll")


def create_schema(database: Path, firebird_root: Path):
    connection = create_database(str(database), user="SYSDBA", password="masterkey", charset="UTF8")
    cursor = connection.cursor()
    for statement in DDL:
        cursor.execute(statement)
    connection.commit()
    connection.close()
    subprocess.run(
        [str(firebird_root / "gfix.exe"), "-user", "SYSDBA", "-password", "masterkey", "-write", "sync", str(database)],
        check=True,
        capture_output=True,
        text=True,
    )


def open_database(database: Path):
    return connect(str(database), user="SYSDBA", password="masterkey", charset="UTF8")


def prewarm(root: Path, firebird_root: Path) -> None:
    database = root / "warmup.fdb"
    connection = create_database(str(database), user="SYSDBA", password="masterkey", charset="UTF8")
    cursor = connection.cursor()
    cursor.execute("create table t (id bigint primary key, val bigint not null)")
    connection.commit()
    cursor.executemany("insert into t values (?, ?)", [(i, i) for i in range(1, 17)])
    connection.commit()
    cursor.execute("select sum(val) from t")
    assert cursor.fetchone()[0] == 136
    connection.close()


def run(dataset: Path, output: Path, firebird_root: Path, run_number: int) -> None:
    output.mkdir(parents=True, exist_ok=False)
    configure_client(firebird_root)
    prewarm(output, firebird_root)
    database = output / "sdbeo.fdb"
    manifest = json.loads((dataset / "manifest.json").read_text(encoding="utf-8"))
    create_schema(database, firebird_root)
    connection = open_database(database)
    cursor = connection.cursor()
    tests = {}

    load_started = time.perf_counter_ns()
    for name in TABLE_ORDER:
        for batch in batched(rows_from_file(dataset, name)):
            cursor.executemany(INSERTS[name], batch)
        connection.commit()
    load_ns = time.perf_counter_ns() - load_started
    counts = {}
    for name in TABLE_ORDER:
        cursor.execute(f"select count(*) from {name}")
        count = int(cursor.fetchone()[0])
        expected = int(manifest["tables"][name]["rows"])
        if count != expected:
            raise RuntimeError(f"{name} row count {count} != {expected}")
        counts[name] = count
    total_rows = int(manifest["total_rows"])
    process = psutil.Process()
    peak_rss = getattr(process.memory_info(), "peak_wset", process.memory_info().rss)
    tests["Q01"] = {
        "elapsed_ms": load_ns / 1e6,
        "throughput_rows_s": total_rows / (load_ns / 1e9),
        "rows": total_rows,
        "row_counts": counts,
        "storage_bytes": database.stat().st_size,
        "process_peak_rss_bytes": peak_rss,
        "errors": 0,
    }

    transaction_count = int(manifest["tables"]["transactions"]["rows"])

    def transaction_key(iteration: int) -> int:
        return 1 + ((iteration * 104_729 + SEED) % transaction_count)

    lookup_cursor = connection.cursor()

    def lookup_operation(iteration: int) -> None:
        key = transaction_key(iteration)
        lookup_cursor.execute("select transaction_id, account_id, timestamp_value, transaction_type, amount_cents, channel, reference_value from transactions where transaction_id = ?", (key,))
        row = lookup_cursor.fetchone()
        if row is None or int(row[0]) != key:
            raise RuntimeError(f"Q02 lookup mismatch for {key}")

    tests["Q02"] = latency(timed_samples(100, 1000, lookup_operation)) | {"correct": True, "allocation": "not recorded"}

    filter_cursor = connection.cursor()

    def filter_operation(iteration: int) -> None:
        key = transaction_key(iteration)
        reference = f"TX-{SEED}-{key:012d}"
        filter_cursor.execute("select transaction_id, reference_value from transactions where reference_value = ? order by reference_value rows 1", (reference,))
        row = filter_cursor.fetchone()
        if row is None or int(row[0]) != key or row[1].rstrip() != reference:
            raise RuntimeError("Q03 indexed filter mismatch")

    tests["Q03"] = latency(timed_samples(100, 1000, filter_operation)) | {"correct": True, "index": "unique B-tree(reference)"}

    range_cursor = connection.cursor()

    def range_operation(iteration: int) -> None:
        first_key = 1 + ((iteration * 7_919 + SEED) % (transaction_count - 100))
        last_key = first_key + 99
        range_cursor.execute(
            "select transaction_id, amount_cents from transactions where transaction_id >= ? and transaction_id <= ? order by transaction_id rows 100",
            (first_key, last_key),
        )
        rows = range_cursor.fetchall()
        if len(rows) != 100 or int(rows[0][0]) != first_key or int(rows[-1][0]) != last_key:
            raise RuntimeError("Q04 range mismatch")

    tests["Q04"] = latency(timed_samples(2, 7, range_operation)) | {"correct": True, "rows_per_result": 100, "index": "primary B-tree(transaction_id)"}

    aggregate_cursor = connection.cursor()
    aggregate_digest_value = ""

    def aggregate_operation(_iteration: int) -> None:
        nonlocal aggregate_digest_value
        aggregate_cursor.execute("select channel, count(*), sum(amount_cents), avg(cast(amount_cents as decimal(18,6))), min(amount_cents), max(amount_cents) from transactions group by channel order by channel")
        rows = aggregate_cursor.fetchall()
        if len(rows) != 5:
            raise RuntimeError("Q05 group count mismatch")
        aggregate_digest_value = aggregate_digest(rows)

    aggregate_samples = timed_samples(2, 7, aggregate_operation)
    tests["Q05"] = latency(aggregate_samples) | {"correct": True, "result_digest": aggregate_digest_value}

    join_queries = [
        ("select count(*) from accounts a join customers c on a.customer_id = c.customer_id where c.branch_id = 7", ()),
        ("select count(*) from employees e join departments d on e.department_id = d.department_id where e.branch_id = 11", ()),
    ]
    join_samples = []
    join_digests = []
    for query, parameters in join_queries:
        holder = [""]

        def join_operation(_iteration: int, statement=query, args=parameters) -> None:
            cursor.execute(statement, args)
            rows = cursor.fetchall()
            holder[0] = result_digest(rows)

        join_samples.extend(timed_samples(2, 7, join_operation))
        join_digests.append(holder[0])
    tests["Q06"] = latency(join_samples) | {"correct": True, "result_digests": join_digests, "relations": 2}

    scan_count = 0
    scan_digest_value = ""

    def scan_operation(_iteration: int) -> None:
        nonlocal scan_count, scan_digest_value
        cursor.execute("select transaction_id, amount_cents from transactions")
        digest = hashlib.sha256()
        count = 0
        while True:
            rows = cursor.fetchmany(4096)
            if not rows:
                break
            count += len(rows)
            for row in rows:
                digest.update(f"{int(row[0])}|{int(row[1])}\n".encode("ascii"))
        if count != transaction_count:
            raise RuntimeError("Q07 scan count mismatch")
        scan_count = count
        scan_digest_value = digest.hexdigest()

    scan_samples = timed_samples(2, 7, scan_operation)
    tests["Q07"] = latency(scan_samples) | {
        "correct": True,
        "rows": scan_count,
        "throughput_rows_s": scan_count / (statistics.median(scan_samples) / 1e9),
        "result_digest": scan_digest_value,
    }

    cursor.execute("create table operations (operation_id bigint primary key, op_value bigint not null, note varchar(64) not null)")
    connection.commit()
    insert_cursor = connection.cursor()

    def insert_operation(iteration: int) -> None:
        insert_cursor.execute("insert into operations values (?, ?, ?)", (iteration, iteration * 3, f"insert-{iteration}"))
        connection.commit()

    insert_samples = timed_samples(20, 200, insert_operation)
    cursor.execute("select count(*) from operations")
    tests["T01"] = latency(insert_samples) | {"correct": int(cursor.fetchone()[0]) == 220, "durability": "forced writes sync per commit"}

    update_cursor = connection.cursor()

    def update_operation(iteration: int) -> None:
        key = 1 + ((iteration * 17 + SEED) % 220)
        update_cursor.execute("update operations set op_value = ? where operation_id = ?", (iteration * 11, key))
        connection.commit()

    update_samples = timed_samples(20, 100, update_operation)

    def delete_operation(iteration: int) -> None:
        key = 221 - iteration
        update_cursor.execute("delete from operations where operation_id = ?", (key,))
        connection.commit()

    delete_samples = timed_samples(20, 100, delete_operation)
    cursor.execute("select count(*) from operations")
    combined_write = update_samples + delete_samples
    tests["T02"] = latency(combined_write) | {
        "correct": int(cursor.fetchone()[0]) == 100,
        "update": latency(update_samples),
        "delete": latency(delete_samples),
        "durability": "forced writes sync per commit",
    }

    connection.close()
    reopened = open_database(database)
    reopen_cursor = reopened.cursor()
    reopen_cursor.execute("select transaction_id from transactions where transaction_id = ?", (transaction_count,))
    q02_reopen = reopen_cursor.fetchone() is not None
    reopen_cursor.execute("select count(*) from operations")
    t01_rows = int(reopen_cursor.fetchone()[0])
    reopened.close()

    report = {
        "engine": "Firebird",
        "engine_version": "5.0.4.1812",
        "mode": "embedded",
        "run": run_number,
        "dataset": manifest["profile"],
        "seed": SEED,
        "source_digest": manifest["logical_source_sha256"],
        "configuration": {
            "runtime": f"Python {os.sys.version.split()[0]} firebird-driver 2.0.3",
            "client_library": str(firebird_root / "fbclient.dll"),
            "durability": "forced writes sync; one commit per measured write",
            "money_representation": "signed BIGINT cents",
        },
        "tests": tests,
        "reopen_checks": {"Q02_key": q02_reopen, "T01_rows": t01_rows},
        "status": q02_reopen and t01_rows == 100,
    }
    (output / "result.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(output / "result.json")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dataset", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--firebird-root", type=Path, required=True)
    parser.add_argument("--run", type=int, default=1)
    args = parser.parse_args()
    run(args.dataset.resolve(), args.output.resolve(), args.firebird_root.resolve(), args.run)


if __name__ == "__main__":
    main()
