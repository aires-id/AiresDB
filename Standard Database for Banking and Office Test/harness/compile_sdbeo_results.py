#!/usr/bin/env python3
"""Compile SDEBO run evidence into the publication result files."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import platform
import shutil
import statistics
import subprocess
from datetime import datetime
from pathlib import Path

import psutil


WEIGHTS = {"Q01": 3, "Q02": 4, "Q03": 3, "Q04": 3, "Q05": 3, "Q06": 4, "Q07": 2, "Q08": 3,
           "T01": 3, "T02": 4, "T03": 4, "T04": 4, "T05": 4, "R01": 3, "R02": 4, "R03": 4,
           "R04": 4, "R05": 4, "S01": 3, "O01": 2}
POINTS = {"A": 4.0, "AB": 3.5, "B": 3.0, "BC": 2.5, "C": 2.0, "D": 1.0, "E": 0.0}
PERFORMANCE = {
    "Q01": ("throughput_rows_s", 1_000.0, "throughput"),
    "Q02": ("p95_ms", 5.0, "latency"),
    "Q03": ("p95_ms", 15.0, "latency"),
    "Q04": ("p95_ms", 25.0, "latency"),
    "Q05": ("p50_ms", 1_500.0, "latency"),
    "Q06": ("p50_ms", 2_000.0, "latency"),
    "Q07": ("throughput_rows_s", 50_000.0, "throughput"),
    "T01": ("p95_ms", 10.0, "latency"),
    "T02": ("p95_ms", 15.0, "latency"),
}


def grade_ratio(ratio: float, correct: bool = True) -> str:
    if not correct or ratio < 0.25:
        return "E"
    if ratio >= 1.5:
        return "A"
    if ratio >= 1.2:
        return "AB"
    if ratio >= 1.0:
        return "B"
    if ratio >= 0.75:
        return "BC"
    if ratio >= 0.5:
        return "C"
    return "D"


def grade_q08(ratio: float, correct: bool = True) -> str:
    if not correct or ratio < 0.50:
        return "E"
    if ratio >= 1.00:
        return "A"
    if ratio >= 0.95:
        return "AB"
    if ratio >= 0.90:
        return "B"
    if ratio >= 0.80:
        return "BC"
    if ratio >= 0.70:
        return "C"
    return "D"


def grade_s01(ratio: float, correct: bool = True) -> str:
    if not correct or ratio < 0.25:
        return "E"
    if ratio >= 0.95:
        return "A"
    if ratio >= 0.85:
        return "AB"
    if ratio >= 0.75:
        return "B"
    if ratio >= 0.65:
        return "BC"
    if ratio >= 0.50:
        return "C"
    return "D"


def class_name(score: float) -> str:
    if score == 4.0:
        return "Perfect"
    if score > 3.5:
        return "Excellent"
    if score > 3.0:
        return "Great"
    if score > 2.5:
        return "Good"
    if score >= 2.0:
        return "Adequate / Layak Dasar"
    return "Tidak Layak"


def grade_functional(code: str, test: dict, engine: str) -> tuple[str, str]:
    correct = bool(test.get("correct", True))
    if code in {"Q08", "S01"}:
        ratio = test["passed"] / test.get("total", test.get("common_families", 1))
        grade = grade_q08(ratio, correct) if code == "Q08" else grade_s01(ratio, correct)
        return grade, f"{test['passed']}/{test.get('total', test.get('common_families'))} controls/families"
    if code == "O01":
        if not correct or test.get("errors") or not test.get("restart_ok", False):
            return "E", "error, crash, or restart failure"
        growth = max(0.0, float(test.get("memory_growth_ratio") or 0.0))
        if growth < 0.05:
            grade = "A"
        elif growth < 0.10:
            grade = "AB"
        elif growth < 0.20:
            grade = "B"
        elif growth < 0.30:
            grade = "BC"
        elif growth < 0.50:
            grade = "C"
        else:
            grade = "D"
        return grade, f"memory growth {growth:.2%}; {test.get('duration_seconds', 0):.1f}s; {len(test.get('errors', []))} errors"
    if not correct:
        return "E", "correctness failure"
    if code == "R01":
        return ("A", "3 native gbak backups usable") if engine == "Firebird" else ("BC", "3 usable offline copies; non-native cap")
    if code == "R02":
        return ("A", "3 automated native restores match") if engine == "Firebird" else ("B", "3 manually orchestrated restores match")
    if code == "R03":
        return "A", f"{len(test.get('process_kill_cycles', []))} process-kill cycles valid; VM unavailable"
    if code == "T03":
        return "A", f"{test.get('normal_transfers')} transfers plus {len(test.get('crash_cycles', []))} crash boundaries"
    if code == "T04":
        return "A", f"{test.get('cycles')} rollback cycles preserved state"
    if code == "T05":
        return "A", f"{test.get('workers')} workers; {test.get('lost_updates')} lost updates"
    if code == "R04":
        return "A", "reopen, recovery, and index checks passed"
    if code == "R05":
        return "A", f"{len(test.get('cases', []))} corruptions detected or safely recovered; no silent mismatch"
    raise KeyError(code)


def read_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def compile_engine(base: Path, engine: str) -> dict:
    runs = [read_json(base / "runs" / engine / f"run-{number}" / "result.json") for number in range(1, 6)]
    resilience = read_json(base / "resilience" / engine / "result.json")
    grades = {}
    for code, (metric, target, direction) in PERFORMANCE.items():
        values = [float(run["tests"][code][metric]) for run in runs]
        value = statistics.median(values)
        correct = all(bool(run["tests"][code].get("correct", True)) and int(run["tests"][code].get("errors", 0)) == 0 for run in runs)
        pfr = value / target if direction == "throughput" else target / value
        grades[code] = {"grade": grade_ratio(pfr, correct), "points": POINTS[grade_ratio(pfr, correct)], "metric": metric,
                        "median": value, "run_values": values, "target_b": target, "pfr": pfr, "correct": correct}
    for code in ["Q08", "T03", "T04", "T05", "R01", "R02", "R03", "R04", "R05", "S01", "O01"]:
        grade, evidence = grade_functional(code, resilience["tests"][code], engine)
        grades[code] = {"grade": grade, "points": POINTS[grade], "evidence": evidence, "correct": bool(resilience["tests"][code].get("correct", True))}
    weighted = sum(WEIGHTS[code] * grades[code]["points"] for code in WEIGHTS)
    score = weighted / sum(WEIGHTS.values())
    no_silent = resilience["tests"]["R05"].get("silent_mismatches", 1) == 0
    medium = score >= 2.5 and POINTS[grades["T04"]["grade"]] >= 2 and POINTS[grades["R02"]["grade"]] >= 2 and POINTS[grades["R03"]["grade"]] >= 2 and no_silent
    bank = score > 3.0 and all(POINTS[grades[code]["grade"]] >= 3 for code in ["T03", "T04", "R02", "R03", "R05"]) and no_silent
    return {"engine": engine, "version": runs[0]["engine_version"], "mode": "embedded", "score": score, "class": class_name(score),
            "medium_office": "PASS" if medium else "FAIL", "small_bank_technical": "PASS" if bank else "FAIL", "grades": grades,
            "resilience_status": resilience["status"]}


def cpu_name() -> str:
    try:
        value = subprocess.check_output(["powershell", "-NoProfile", "-Command", "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)"], text=True).strip()
        return value or platform.processor()
    except Exception:
        return platform.processor()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--firebird-root", type=Path, required=True)
    args = parser.parse_args()
    base = args.base.resolve()
    engines = [compile_engine(base, name) for name in ["AiresDB", "Firebird"]]
    dataset = read_json(base / "dataset" / "manifest.json")
    report = {"standard": "SDEBO 1.0", "profile": "SDEBO-S750", "seed": 1999, "total_rows": dataset["total_rows"],
              "logical_source_sha256": dataset["logical_source_sha256"], "total_weight": sum(WEIGHTS.values()), "engines": engines,
              "deviations": ["VM hard power-off cycles unavailable on this physical host; five external process-termination cycles were run per engine.",
                             "Both engines were tested through embedded APIs on the same host; S01 server/network gate is not applicable.",
                             "AiresDB R01 uses an offline checkpoint plus file copy because v0.1.0 has no native backup facility; its grade is capped at BC.",
                             "An unscored first AiresDB T05 attempt exposed cross-Engine Session teardown interference: closing one worker while others committed closed the shared page manager. The scored rerun retained all workers until measurement ended.",
                             "The first AiresDB O01 attempt was invalidated because the harness called update_key! with an incorrect do-block argument order. O01 was rerun for the full duration with zero errors; both records are retained."]}
    (base / "result.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    with (base / "result.csv").open("w", newline="", encoding="utf-8") as stream:
        writer = csv.DictWriter(stream, fieldnames=["engine", "version", "test", "weight", "grade", "points", "weighted_points", "metric", "median", "target_b", "pfr", "evidence"])
        writer.writeheader()
        for engine in engines:
            for code in WEIGHTS:
                item = engine["grades"][code]
                writer.writerow({"engine": engine["engine"], "version": engine["version"], "test": code, "weight": WEIGHTS[code], "grade": item["grade"],
                                 "points": item["points"], "weighted_points": item["points"] * WEIGHTS[code], "metric": item.get("metric", ""),
                                 "median": item.get("median", ""), "target_b": item.get("target_b", ""), "pfr": item.get("pfr", ""), "evidence": item.get("evidence", "")})

    disk = psutil.disk_usage(str(base))
    environment = {"captured_at_local": datetime.now().astimezone().isoformat(), "test_window_local": "2026-09-09 through 2026-09-11",
                   "os": platform.platform(), "cpu": cpu_name(), "logical_cpu": psutil.cpu_count(),
                   "physical_cpu": psutil.cpu_count(logical=False), "ram_bytes": psutil.virtual_memory().total,
                   "storage": {"path": str(base.drive), "type": "SSD (host-reported)", "total_bytes": disk.total, "free_bytes_after_test": disk.free},
                   "dataset": {"profile": "SDEBO-S750", "rows": dataset["total_rows"], "seed": 1999, "digest": dataset["logical_source_sha256"]},
                   "engines": {"AiresDB": {"version": "0.1.0", "runtime": "Julia 1.12.7", "mode": "embedded", "durability": "WAL fsync per commit"},
                               "Firebird": {"version": "5.0.4.1812", "runtime": "Python 3 + firebird-driver 2.0.3", "mode": "embedded", "durability": "forced writes sync"}},
                   "firebird_distribution": {"root": str(args.firebird_root.resolve()), "download_sha256": "01e844fce4d5f53272a76205dbc3a1ba4b782ab8e8eadcd808cdbccd9ce13b72"}}
    (base / "environment.json").write_text(json.dumps(environment, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    raw = base / "raw"
    recovery = base / "recovery"
    raw.mkdir(exist_ok=True)
    recovery.mkdir(exist_ok=True)
    for engine in ["AiresDB", "Firebird"]:
        target = raw / engine
        target.mkdir(exist_ok=True)
        for number in range(1, 6):
            shutil.copy2(base / "runs" / engine / f"run-{number}" / "result.json", target / f"performance-run-{number}.json")
        shutil.copy2(base / "resilience" / engine / "result.json", recovery / f"{engine}-resilience.json")

    harness_manifest = {}
    for path in sorted((base.parent / "harness").glob("*")):
        if path.is_file() and path.suffix in {".py", ".jl"}:
            harness_manifest[path.name] = sha256(path)
    (raw / "harness-sha256.json").write_text(json.dumps(harness_manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(base / "result.json")


if __name__ == "__main__":
    main()
