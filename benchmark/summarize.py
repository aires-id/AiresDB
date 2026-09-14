#!/usr/bin/env python3
"""Build a concise English AiresDB device-benchmark report.

Example:
    python benchmark/summarize.py \
      --baseline verification/micro-v010-run1.toml \
      --current verification/micro-current-run1.toml \
      --tpcc verification/tpcc.toml \
      --tpch verification/tpch.toml \
      --output verification/BENCHMARK-RESULTS.md

The microbenchmark flags are repeatable. Their raw ``samples_ms`` arrays are
pooled before nearest-rank percentiles and throughput are recomputed.
"""

from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import sys
import tempfile
import tomllib
from typing import Any, Iterable, Mapping, Sequence


TPCC_FAMILIES = ("NewOrder", "Payment", "OrderStatus", "Delivery", "StockLevel")
TPCH_QUERIES = tuple(f"Q{number:02d}" for number in range(1, 23))


class ReportError(ValueError):
    """An input report is missing or internally inconsistent."""


def parse_arguments(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Summarize AiresDB microbenchmarks, TPC-C-derived workloads, and "
            "TPC-H-derived workloads as Markdown."
        )
    )
    parser.add_argument(
        "--baseline",
        action="append",
        default=[],
        metavar="MICRO_V010.toml",
        help="Baseline microbenchmark report; repeat for multiple runs.",
    )
    parser.add_argument(
        "--current",
        action="append",
        default=[],
        metavar="MICRO_CURRENT.toml",
        help="Current candidate microbenchmark report; repeat for multiple runs.",
    )
    parser.add_argument("--tpcc", metavar="TPCC.toml", help="TPC-C-derived workload report.")
    parser.add_argument("--tpch", metavar="TPCH.toml", help="TPC-H-derived workload report.")
    parser.add_argument("--output", required=True, metavar="REPORT.md", help="Output Markdown path.")
    args = parser.parse_args(argv)
    if not (args.baseline or args.current or args.tpcc or args.tpch):
        parser.error("provide at least one benchmark input")
    return args


def load_toml(path_text: str) -> tuple[Path, dict[str, Any]]:
    path = Path(path_text).expanduser().resolve()
    try:
        with path.open("rb") as stream:
            parsed = tomllib.load(stream)
    except FileNotFoundError as error:
        raise ReportError(f"file not found: {path}") from error
    except tomllib.TOMLDecodeError as error:
        raise ReportError(f"invalid TOML in {path}: {error}") from error
    except OSError as error:
        raise ReportError(f"could not read {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise ReportError(f"TOML root must be a table: {path}")
    return path, parsed


def table(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ReportError(f"{context} must be a TOML table")
    return value


def finite_number(value: Any, context: str, *, nonnegative: bool = True) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError(f"{context} must be a number")
    number = float(value)
    if not math.isfinite(number):
        raise ReportError(f"{context} must be finite")
    if nonnegative and number < 0:
        raise ReportError(f"{context} must not be negative")
    return number


def integer(value: Any, context: str, *, nonnegative: bool = True) -> int:
    number = finite_number(value, context, nonnegative=nonnegative)
    if not number.is_integer():
        raise ReportError(f"{context} must be an integer")
    return int(number)


def nearest_rank(values: Sequence[float], fraction: float) -> float:
    if not values:
        raise ReportError("a percentile requires at least one sample")
    ordered = sorted(values)
    index = max(1, math.ceil(fraction * len(ordered))) - 1
    return ordered[index]


def summary_from_samples(samples: Sequence[float]) -> dict[str, float | int]:
    if not samples:
        raise ReportError("samples_ms must not be empty")
    total = math.fsum(samples)
    return {
        "count": len(samples),
        "p50_ms": nearest_rank(samples, 0.50),
        "p95_ms": nearest_rank(samples, 0.95),
        "total_ms": total,
        "operations_per_second": math.inf if total == 0 else len(samples) * 1000.0 / total,
    }


def sample_array(section: Mapping[str, Any], context: str) -> list[float]:
    raw = section.get("samples_ms")
    if not isinstance(raw, list):
        raise ReportError(
            f"{context}.samples_ms is required to pool runs without estimating percentiles"
        )
    samples = [finite_number(value, f"{context}.samples_ms[{index}]") for index, value in enumerate(raw)]
    if not samples:
        raise ReportError(f"{context}.samples_ms must not be empty")
    if "count" in section and integer(section["count"], f"{context}.count") != len(samples):
        raise ReportError(f"{context}.count does not match the samples_ms length")
    return samples


def common_configuration(
    reports: Sequence[tuple[Path, Mapping[str, Any]]], key: str, group_name: str
) -> Any:
    values = [(path, report.get(key)) for path, report in reports if key in report]
    if not values:
        return None
    expected = values[0][1]
    if any(value != expected for _, value in values[1:]):
        details = ", ".join(f"{path.name}={value!r}" for path, value in values)
        raise ReportError(f"configuration {group_name}.{key} differs between runs: {details}")
    return expected


def aggregate_micro(
    loaded: Sequence[tuple[Path, dict[str, Any]]], group_name: str
) -> dict[str, Any] | None:
    if not loaded:
        return None
    rows = common_configuration(loaded, "rows", group_name)
    warmup = common_configuration(loaded, "warmup_pairs", group_name)
    if rows is not None:
        integer(rows, f"{group_name}.rows")
    if warmup is not None:
        integer(warmup, f"{group_name}.warmup_pairs")

    result: dict[str, Any] = {
        "runs": len(loaded),
        "rows": rows,
        "warmup_pairs": warmup,
        "versions": sorted({str(report.get("engine_version", "not recorded")) for _, report in loaded}),
        "durability": sorted({str(report.get("durability_label", "not recorded")) for _, report in loaded}),
        "source_paths": [path for path, _ in loaded],
        "reports": [report for _, report in loaded],
    }
    for operation in ("read", "write"):
        pooled: list[float] = []
        for path, report in loaded:
            section = table(report.get(operation), f"{path}:{operation}")
            pooled.extend(sample_array(section, f"{path}:{operation}"))
        result[operation] = summary_from_samples(pooled)
    return result


def scalar_summary(section: Mapping[str, Any], context: str) -> dict[str, float | int]:
    required = ("count", "p50_ms", "p95_ms")
    missing = [key for key in required if key not in section]
    if missing:
        raise ReportError(f"{context} is missing {', '.join(missing)}")
    result: dict[str, float | int] = {
        "count": integer(section["count"], f"{context}.count"),
        "p50_ms": finite_number(section["p50_ms"], f"{context}.p50_ms"),
        "p95_ms": finite_number(section["p95_ms"], f"{context}.p95_ms"),
    }
    for key in ("operations_per_second", "mix_operations_per_second"):
        if key in section:
            result[key] = finite_number(section[key], f"{context}.{key}")
    return result


def format_number(value: Any, digits: int = 3) -> str:
    if value is None:
        return "—"
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, int):
        return f"{value:,}"
    if isinstance(value, float):
        if math.isinf(value):
            return "∞"
        return f"{value:,.{digits}f}"
    return str(value)


def markdown(value: Any) -> str:
    return str(value).replace("|", "\\|").replace("\r", " ").replace("\n", " ")


def ratio(numerator: Any, denominator: Any) -> str:
    if not isinstance(numerator, (int, float)) or not isinstance(denominator, (int, float)):
        return "—"
    if denominator == 0:
        return "∞" if numerator > 0 else "—"
    return f"{numerator / denominator:.2f}×"


def first_present(reports: Iterable[Mapping[str, Any]], key: str) -> Any:
    for report in reports:
        value = report.get(key)
        if value is not None and value != "":
            return value
    return None


def render_hardware(reports: Sequence[Mapping[str, Any]]) -> list[str]:
    cpu_models = first_present(reports, "cpu_models")
    if isinstance(cpu_models, list):
        cpu = ", ".join(dict.fromkeys(str(model) for model in cpu_models))
    elif cpu_models is None:
        cpu = "not recorded"
    else:
        cpu = str(cpu_models)
    total_memory = first_present(reports, "total_memory_bytes")
    memory = "not recorded"
    if total_memory is not None:
        memory = f"{finite_number(total_memory, 'total_memory_bytes') / (1024 ** 3):.2f} GiB"
    kernel = first_present(reports, "kernel") or "not recorded"
    architecture = first_present(reports, "architecture") or "not recorded"
    logical = first_present(reports, "cpu_threads_detected")
    julia_version = first_present(reports, "julia_version") or "not recorded"
    julia_threads = first_present(reports, "julia_threads")
    flush = first_present(reports, "commit_flush_mode")
    measured = [str(value) for value in (report.get("measured_on") for report in reports) if value]

    lines = [
        "## Hardware and runtime",
        "",
        "| Component | Value |",
        "|---|---|",
        f"| CPU | {markdown(cpu)} |",
        f"| Detected logical threads | {markdown(logical if logical is not None else 'not recorded')} |",
        f"| Total memory | {memory} |",
        f"| System | {markdown(kernel)} / {markdown(architecture)} |",
        f"| Julia | {markdown(julia_version)}; {markdown(julia_threads if julia_threads is not None else 'not recorded')} thread(s) |",
    ]
    if flush:
        lines.append(f"| Flush commit | {markdown(flush)} |")
    if measured:
        lines.append(f"| Measurement range | {markdown(min(measured))} to {markdown(max(measured))} |")
    return lines


def render_micro(baseline: dict[str, Any] | None, current: dict[str, Any] | None) -> list[str]:
    if baseline is None and current is None:
        return []
    lines = [
        "## Microbenchmarks: point read and point update",
        "",
        (
            "Raw samples from like-for-like runs are pooled, then p50/p95 are recomputed using "
            "the *nearest-rank* method. Throughput is the sample count divided by total sample time."
        ),
        "",
        "| Operation | Baseline samples | Baseline p50 (ms) | Baseline p95 (ms) | Baseline ops/s | Candidate samples | Candidate p50 (ms) | Candidate p95 (ms) | Candidate ops/s | Ops/s ratio | p50 speedup | p95 speedup |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for operation, label in (("read", "Point read"), ("write", "Point update")):
        old = baseline.get(operation) if baseline else None
        new = current.get(operation) if current else None
        lines.append(
            "| " + " | ".join(
                [
                    label,
                    format_number(old.get("count") if old else None),
                    format_number(old.get("p50_ms") if old else None),
                    format_number(old.get("p95_ms") if old else None),
                    format_number(old.get("operations_per_second") if old else None),
                    format_number(new.get("count") if new else None),
                    format_number(new.get("p50_ms") if new else None),
                    format_number(new.get("p95_ms") if new else None),
                    format_number(new.get("operations_per_second") if new else None),
                    ratio(
                        new.get("operations_per_second") if new else None,
                        old.get("operations_per_second") if old else None,
                    ),
                    ratio(old.get("p50_ms") if old else None, new.get("p50_ms") if new else None),
                    ratio(old.get("p95_ms") if old else None, new.get("p95_ms") if new else None),
                ]
            ) + " |"
        )
    lines.extend(["", "Microbenchmark configuration:"])
    for name, report in (("baseline", baseline), ("candidate", current)):
        if report:
            lines.append(
                f"- {name}: {report['runs']} run(s); {format_number(report.get('rows'))} rows; "
                f"{format_number(report.get('warmup_pairs'))} warmup pairs; version "
                f"{markdown(', '.join(report['versions']))}; durability {markdown(', '.join(report['durability']))}."
            )
    if baseline and current and baseline.get("rows") != current.get("rows"):
        lines.append("- Warning: baseline and candidate row counts differ, so ratios are not directly comparable.")
    return lines


def render_tpcc(path: Path, report: Mapping[str, Any]) -> list[str]:
    latency = table(report.get("latency"), f"{path}:latency")
    missing = [name for name in TPCC_FAMILIES if name not in latency]
    if missing:
        raise ReportError(f"{path} does not contain all five transaction families: {', '.join(missing)}")
    summaries = {
        name: scalar_summary(table(latency[name], f"{path}:latency.{name}"), f"{path}:latency.{name}")
        for name in TPCC_FAMILIES
    }
    counters = table(report.get("counters"), f"{path}:counters")
    consistency = table(report.get("consistency"), f"{path}:consistency")
    for name, value in consistency.items():
        if not isinstance(value, bool):
            raise ReportError(f"{path}:consistency.{name} must be boolean")

    lines = [
        "## TPC-C-derived workload: five transaction families",
        "",
        (
            f"Configuration: {format_number(report.get('warehouses'))} warehouse(s) × "
            f"{format_number(report.get('districts_per_warehouse'))} district × "
            f"{format_number(report.get('customers_per_district'))} customer(s); "
            f"{format_number(report.get('items'))} item(s); seed {markdown(report.get('seed', 'not recorded'))}. "
            f"Measured {format_number(report.get('transactions'))} transaction(s) after "
            f"{format_number(report.get('warmup_transactions'))} warmup transaction(s) in "
            f"{format_number(report.get('wall_seconds'))} seconds: "
            f"{format_number(report.get('transactions_per_second'))} transaction(s)/s."
        ),
        "",
        "| Family | Count | p50 (ms) | p95 (ms) | Mixed ops/s |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in TPCC_FAMILIES:
        item = summaries[name]
        lines.append(
            f"| {name} | {format_number(item['count'])} | {format_number(item['p50_ms'])} | "
            f"{format_number(item['p95_ms'])} | {format_number(item.get('mix_operations_per_second'))} |"
        )
    lines.extend(["", "Transaction counters:"])
    for name in ("commits", "expected_rollbacks", "retries", "errors"):
        if name in counters:
            lines.append(f"- `{name}`: {format_number(counters[name])}")
    for name in sorted(set(counters) - {"commits", "expected_rollbacks", "retries", "errors"}):
        lines.append(f"- `{markdown(name)}`: {format_number(counters[name])}")
    lines.extend(["", "Consistency invariants after the workload:"])
    for name in sorted(consistency):
        lines.append(f"- {'PASS' if consistency[name] else 'FAIL'} — `{markdown(name)}`")
    lines.append(f"- Overall status: **{'PASS' if consistency and all(consistency.values()) else 'FAIL'}**.")
    return lines


def render_tpch(path: Path, report: Mapping[str, Any]) -> list[str]:
    queries = table(report.get("queries"), f"{path}:queries")
    missing = [name for name in TPCH_QUERIES if name not in queries]
    if missing:
        raise ReportError(f"{path} does not contain all 22 queries: {', '.join(missing)}")
    summaries: dict[str, tuple[int, dict[str, float | int]]] = {}
    for name in TPCH_QUERIES:
        section = table(queries[name], f"{path}:queries.{name}")
        if "result_rows" not in section:
            raise ReportError(f"{path}:queries.{name}.result_rows is missing")
        summaries[name] = (
            integer(section["result_rows"], f"{path}:queries.{name}.result_rows"),
            scalar_summary(section, f"{path}:queries.{name}"),
        )
    oracle = report.get("independent_sql_oracle_passed")
    if oracle is not None and not isinstance(oracle, bool):
        raise ReportError(f"{path}:independent_sql_oracle_passed must be boolean")

    lines = [
        "## TPC-H-derived workload: all 22 queries",
        "",
        (
            f"Synthetic scale {markdown(report.get('scale', 'not recorded'))}; "
            f"{format_number(report.get('repetitions'))} measured repetition(s)/query after "
            f"{format_number(report.get('warmup_per_query'))} warmup(s)/query; seed "
            f"{markdown(report.get('seed', 'not recorded'))}. Generator: "
            f"{markdown(report.get('generator', 'not recorded'))}."
        ),
        "",
        "| Query | Result rows | Samples | p50 (ms) | p95 (ms) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in TPCH_QUERIES:
        rows, item = summaries[name]
        lines.append(
            f"| {name} | {format_number(rows)} | {format_number(item['count'])} | "
            f"{format_number(item['p50_ms'])} | {format_number(item['p95_ms'])} |"
        )
    if oracle is True:
        oracle_text = "**PASS** — every result was compared with an independent SQL oracle."
    elif oracle is False:
        oracle_text = "**NOT RUN** — the report records `false`."
    else:
        oracle_text = "**NOT RECORDED**."
    lines.extend(["", f"Independent SQL oracle: {oracle_text}"])
    return lines


def source_lines(
    baseline: dict[str, Any] | None,
    current: dict[str, Any] | None,
    tpcc: tuple[Path, Mapping[str, Any]] | None,
    tpch: tuple[Path, Mapping[str, Any]] | None,
) -> list[str]:
    entries: list[tuple[str, Path]] = []
    if baseline:
        entries.extend(("baseline microbenchmark", path) for path in baseline["source_paths"])
    if current:
        entries.extend(("candidate microbenchmark", path) for path in current["source_paths"])
    if tpcc:
        entries.append(("TPC-C-derived", tpcc[0]))
    if tpch:
        entries.append(("TPC-H-derived", tpch[0]))
    lines = ["## Input trace", ""]
    lines.extend(f"- {label}: `{markdown(path)}`" for label, path in entries)
    return lines


def build_report(
    baseline: dict[str, Any] | None,
    current: dict[str, Any] | None,
    tpcc: tuple[Path, Mapping[str, Any]] | None,
    tpch: tuple[Path, Mapping[str, Any]] | None,
) -> str:
    reports: list[Mapping[str, Any]] = []
    if current:
        reports.extend(current["reports"])
    if tpcc:
        reports.append(tpcc[1])
    if tpch:
        reports.append(tpch[1])
    if baseline:
        reports.extend(baseline["reports"])

    lines = [
        "# AiresDB v0.1.0 benchmark results on this device",
        "",
        "**Benchmark status:** these are local engineering measurements from TPC-C-derived and TPC-H-derived workloads. They are **not audited by TPC and are not TPC-compliant results**, so they are **not tpmC or QphH** and must not be compared with official TPC results.",
        "",
    ]
    lines.extend(render_hardware(reports))
    lines.extend(["", "## Methodology", ""])
    lines.extend(
        [
            "- Every figure is read directly from TOML reports; this script neither runs workloads nor invents samples.",
            "- p50 and p95 use *nearest-rank*. Warmup and data loading are outside the summarized latency samples.",
            "- Cross-version measurements are meaningful only when hardware, data, row count, warmup, and system load are comparable. The durability label is shown because flush cost affects writes.",
            "- The TPC-C-derived workload uses a closed driver, disclosed scale/generator, no terminal think time, and no TPC audit. The TPC-H-derived workload uses synthetic data unless a report declares external DBGEN; it does not run official power, throughput, or refresh procedures.",
        ]
    )
    micro_lines = render_micro(baseline, current)
    if micro_lines:
        lines.extend([""] + micro_lines)
    if tpcc:
        lines.extend([""] + render_tpcc(*tpcc))
    if tpch:
        lines.extend([""] + render_tpch(*tpch))
    lines.extend([""] + source_lines(baseline, current, tpcc, tpch))
    return "\n".join(lines).rstrip() + "\n"


def write_atomic(path_text: str, content: str) -> Path:
    destination = Path(path_text).expanduser().resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary_name: str | None = None
    try:
        with tempfile.NamedTemporaryFile(
            "w", encoding="utf-8", newline="\n", dir=destination.parent, delete=False
        ) as stream:
            temporary_name = stream.name
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_name, destination)
    except OSError as error:
        if temporary_name:
            try:
                Path(temporary_name).unlink(missing_ok=True)
            except OSError:
                pass
        raise ReportError(f"could not write {destination}: {error}") from error
    return destination


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_arguments(argv)
    try:
        baseline = aggregate_micro([load_toml(path) for path in args.baseline], "baseline")
        current = aggregate_micro([load_toml(path) for path in args.current], "current")
        tpcc = load_toml(args.tpcc) if args.tpcc else None
        tpch = load_toml(args.tpch) if args.tpch else None
        destination = write_atomic(args.output, build_report(baseline, current, tpcc, tpch))
    except ReportError as error:
        print(f"summarize.py: {error}", file=sys.stderr)
        return 2
    print(f"Report written: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
