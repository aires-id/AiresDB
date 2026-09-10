#!/usr/bin/env python3
"""Build the concise Indonesian AiresDB device-benchmark report.

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
            "Ringkas benchmark mikro AiresDB, workload turunan TPC-C, dan "
            "workload turunan TPC-H menjadi Markdown."
        )
    )
    parser.add_argument(
        "--baseline",
        action="append",
        default=[],
        metavar="MICRO_V010.toml",
        help="Laporan mikro baseline; dapat diulang untuk beberapa run.",
    )
    parser.add_argument(
        "--current",
        action="append",
        default=[],
        metavar="MICRO_CURRENT.toml",
        help="Laporan mikro kandidat saat ini; dapat diulang untuk beberapa run.",
    )
    parser.add_argument("--tpcc", metavar="TPCC.toml", help="Laporan workload turunan TPC-C.")
    parser.add_argument("--tpch", metavar="TPCH.toml", help="Laporan workload turunan TPC-H.")
    parser.add_argument("--output", required=True, metavar="REPORT.md", help="Lokasi Markdown keluaran.")
    args = parser.parse_args(argv)
    if not (args.baseline or args.current or args.tpcc or args.tpch):
        parser.error("berikan paling sedikit satu input benchmark")
    return args


def load_toml(path_text: str) -> tuple[Path, dict[str, Any]]:
    path = Path(path_text).expanduser().resolve()
    try:
        with path.open("rb") as stream:
            parsed = tomllib.load(stream)
    except FileNotFoundError as error:
        raise ReportError(f"file tidak ditemukan: {path}") from error
    except tomllib.TOMLDecodeError as error:
        raise ReportError(f"TOML tidak valid di {path}: {error}") from error
    except OSError as error:
        raise ReportError(f"gagal membaca {path}: {error}") from error
    if not isinstance(parsed, dict):
        raise ReportError(f"akar TOML harus berupa tabel: {path}")
    return path, parsed


def table(value: Any, context: str) -> Mapping[str, Any]:
    if not isinstance(value, Mapping):
        raise ReportError(f"{context} harus berupa tabel TOML")
    return value


def finite_number(value: Any, context: str, *, nonnegative: bool = True) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ReportError(f"{context} harus berupa angka")
    number = float(value)
    if not math.isfinite(number):
        raise ReportError(f"{context} harus berupa angka terhingga")
    if nonnegative and number < 0:
        raise ReportError(f"{context} tidak boleh negatif")
    return number


def integer(value: Any, context: str, *, nonnegative: bool = True) -> int:
    number = finite_number(value, context, nonnegative=nonnegative)
    if not number.is_integer():
        raise ReportError(f"{context} harus berupa bilangan bulat")
    return int(number)


def nearest_rank(values: Sequence[float], fraction: float) -> float:
    if not values:
        raise ReportError("persentil memerlukan paling sedikit satu sampel")
    ordered = sorted(values)
    index = max(1, math.ceil(fraction * len(ordered))) - 1
    return ordered[index]


def summary_from_samples(samples: Sequence[float]) -> dict[str, float | int]:
    if not samples:
        raise ReportError("array samples_ms tidak boleh kosong")
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
            f"{context}.samples_ms wajib ada agar beberapa run dapat digabung tanpa mengira-ngira persentil"
        )
    samples = [finite_number(value, f"{context}.samples_ms[{index}]") for index, value in enumerate(raw)]
    if not samples:
        raise ReportError(f"{context}.samples_ms tidak boleh kosong")
    if "count" in section and integer(section["count"], f"{context}.count") != len(samples):
        raise ReportError(f"{context}.count tidak sama dengan panjang samples_ms")
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
        raise ReportError(f"konfigurasi {group_name}.{key} berbeda antar-run: {details}")
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
        "versions": sorted({str(report.get("engine_version", "tidak tercatat")) for _, report in loaded}),
        "durability": sorted({str(report.get("durability_label", "tidak tercatat")) for _, report in loaded}),
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
        raise ReportError(f"{context} tidak memiliki {', '.join(missing)}")
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
        return "ya" if value else "tidak"
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
        cpu = "tidak tercatat"
    else:
        cpu = str(cpu_models)
    total_memory = first_present(reports, "total_memory_bytes")
    memory = "tidak tercatat"
    if total_memory is not None:
        memory = f"{finite_number(total_memory, 'total_memory_bytes') / (1024 ** 3):.2f} GiB"
    kernel = first_present(reports, "kernel") or "tidak tercatat"
    architecture = first_present(reports, "architecture") or "tidak tercatat"
    logical = first_present(reports, "cpu_threads_detected")
    julia_version = first_present(reports, "julia_version") or "tidak tercatat"
    julia_threads = first_present(reports, "julia_threads")
    flush = first_present(reports, "commit_flush_mode")
    measured = [str(value) for value in (report.get("measured_on") for report in reports) if value]

    lines = [
        "## Perangkat dan runtime",
        "",
        "| Komponen | Nilai |",
        "|---|---|",
        f"| CPU | {markdown(cpu)} |",
        f"| Thread logis terdeteksi | {markdown(logical if logical is not None else 'tidak tercatat')} |",
        f"| Memori total | {memory} |",
        f"| Sistem | {markdown(kernel)} / {markdown(architecture)} |",
        f"| Julia | {markdown(julia_version)}; {markdown(julia_threads if julia_threads is not None else 'tidak tercatat')} thread |",
    ]
    if flush:
        lines.append(f"| Flush commit | {markdown(flush)} |")
    if measured:
        lines.append(f"| Rentang pengukuran | {markdown(min(measured))} sampai {markdown(max(measured))} |")
    return lines


def render_micro(baseline: dict[str, Any] | None, current: dict[str, Any] | None) -> list[str]:
    if baseline is None and current is None:
        return []
    lines = [
        "## Mikro: point read dan point update",
        "",
        (
            "Sampel mentah dari semua run sejenis digabung, lalu p50/p95 dihitung ulang dengan "
            "metode *nearest-rank*. Throughput dihitung dari jumlah sampel dibagi total waktu sampel."
        ),
        "",
        "| Operasi | Baseline sampel | Baseline p50 (ms) | Baseline p95 (ms) | Baseline ops/s | Kandidat sampel | Kandidat p50 (ms) | Kandidat p95 (ms) | Kandidat ops/s | Rasio ops/s | Percepatan p50 | Percepatan p95 |",
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
    lines.extend(["", "Konfigurasi mikro:"])
    for name, report in (("baseline", baseline), ("kandidat", current)):
        if report:
            lines.append(
                f"- {name}: {report['runs']} run; {format_number(report.get('rows'))} baris; "
                f"{format_number(report.get('warmup_pairs'))} pasangan warmup; versi "
                f"{markdown(', '.join(report['versions']))}; durabilitas {markdown(', '.join(report['durability']))}."
            )
    if baseline and current and baseline.get("rows") != current.get("rows"):
        lines.append("- Perhatian: jumlah baris baseline dan kandidat berbeda, sehingga rasio tidak setara langsung.")
    return lines


def render_tpcc(path: Path, report: Mapping[str, Any]) -> list[str]:
    latency = table(report.get("latency"), f"{path}:latency")
    missing = [name for name in TPCC_FAMILIES if name not in latency]
    if missing:
        raise ReportError(f"{path} tidak memuat seluruh lima keluarga transaksi: {', '.join(missing)}")
    summaries = {
        name: scalar_summary(table(latency[name], f"{path}:latency.{name}"), f"{path}:latency.{name}")
        for name in TPCC_FAMILIES
    }
    counters = table(report.get("counters"), f"{path}:counters")
    consistency = table(report.get("consistency"), f"{path}:consistency")
    for name, value in consistency.items():
        if not isinstance(value, bool):
            raise ReportError(f"{path}:consistency.{name} harus boolean")

    lines = [
        "## Workload turunan TPC-C: lima keluarga transaksi",
        "",
        (
            f"Konfigurasi: {format_number(report.get('warehouses'))} warehouse × "
            f"{format_number(report.get('districts_per_warehouse'))} district × "
            f"{format_number(report.get('customers_per_district'))} customer; "
            f"{format_number(report.get('items'))} item; seed {markdown(report.get('seed', 'tidak tercatat'))}. "
            f"Pengukuran {format_number(report.get('transactions'))} transaksi setelah "
            f"{format_number(report.get('warmup_transactions'))} warmup dalam "
            f"{format_number(report.get('wall_seconds'))} detik: "
            f"{format_number(report.get('transactions_per_second'))} transaksi/s."
        ),
        "",
        "| Keluarga | Hitungan | p50 (ms) | p95 (ms) | Mix ops/s |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in TPCC_FAMILIES:
        item = summaries[name]
        lines.append(
            f"| {name} | {format_number(item['count'])} | {format_number(item['p50_ms'])} | "
            f"{format_number(item['p95_ms'])} | {format_number(item.get('mix_operations_per_second'))} |"
        )
    lines.extend(["", "Counter transaksi:"])
    for name in ("commits", "expected_rollbacks", "retries", "errors"):
        if name in counters:
            lines.append(f"- `{name}`: {format_number(counters[name])}")
    for name in sorted(set(counters) - {"commits", "expected_rollbacks", "retries", "errors"}):
        lines.append(f"- `{markdown(name)}`: {format_number(counters[name])}")
    lines.extend(["", "Invariant konsistensi setelah workload:"])
    for name in sorted(consistency):
        lines.append(f"- {'LULUS' if consistency[name] else 'GAGAL'} — `{markdown(name)}`")
    lines.append(f"- Status keseluruhan: **{'LULUS' if consistency and all(consistency.values()) else 'GAGAL'}**.")
    return lines


def render_tpch(path: Path, report: Mapping[str, Any]) -> list[str]:
    queries = table(report.get("queries"), f"{path}:queries")
    missing = [name for name in TPCH_QUERIES if name not in queries]
    if missing:
        raise ReportError(f"{path} tidak memuat seluruh 22 query: {', '.join(missing)}")
    summaries: dict[str, tuple[int, dict[str, float | int]]] = {}
    for name in TPCH_QUERIES:
        section = table(queries[name], f"{path}:queries.{name}")
        if "result_rows" not in section:
            raise ReportError(f"{path}:queries.{name}.result_rows tidak ada")
        summaries[name] = (
            integer(section["result_rows"], f"{path}:queries.{name}.result_rows"),
            scalar_summary(section, f"{path}:queries.{name}"),
        )
    oracle = report.get("independent_sql_oracle_passed")
    if oracle is not None and not isinstance(oracle, bool):
        raise ReportError(f"{path}:independent_sql_oracle_passed harus boolean")

    lines = [
        "## Workload turunan TPC-H: seluruh 22 query",
        "",
        (
            f"Skala sintetis {markdown(report.get('scale', 'tidak tercatat'))}; "
            f"{format_number(report.get('repetitions'))} repetisi terukur/query setelah "
            f"{format_number(report.get('warmup_per_query'))} warmup/query; seed "
            f"{markdown(report.get('seed', 'tidak tercatat'))}. Generator: "
            f"{markdown(report.get('generator', 'tidak tercatat'))}."
        ),
        "",
        "| Query | Baris hasil | Sampel | p50 (ms) | p95 (ms) |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in TPCH_QUERIES:
        rows, item = summaries[name]
        lines.append(
            f"| {name} | {format_number(rows)} | {format_number(item['count'])} | "
            f"{format_number(item['p50_ms'])} | {format_number(item['p95_ms'])} |"
        )
    if oracle is True:
        oracle_text = "**LULUS** — semua hasil dibandingkan dengan oracle SQL independen."
    elif oracle is False:
        oracle_text = "**TIDAK DIJALANKAN** — laporan merekam `false`."
    else:
        oracle_text = "**TIDAK TERCATAT**."
    lines.extend(["", f"Oracle SQL independen: {oracle_text}"])
    return lines


def source_lines(
    baseline: dict[str, Any] | None,
    current: dict[str, Any] | None,
    tpcc: tuple[Path, Mapping[str, Any]] | None,
    tpch: tuple[Path, Mapping[str, Any]] | None,
) -> list[str]:
    entries: list[tuple[str, Path]] = []
    if baseline:
        entries.extend(("mikro baseline", path) for path in baseline["source_paths"])
    if current:
        entries.extend(("mikro kandidat", path) for path in current["source_paths"])
    if tpcc:
        entries.append(("turunan TPC-C", tpcc[0]))
    if tpch:
        entries.append(("turunan TPC-H", tpch[0]))
    lines = ["## Jejak input", ""]
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
        "# Hasil benchmark AiresDB v0.1.0 pada perangkat ini",
        "",
        "**Status benchmark:** hasil berikut adalah pengukuran engineering lokal dari workload turunan TPC-C/TPC-H. Pengujian ini **tidak diaudit oleh TPC dan bukan hasil patuh TPC**, sehingga angkanya **bukan tpmC dan bukan QphH** serta tidak boleh dibandingkan dengan hasil resmi TPC.",
        "",
    ]
    lines.extend(render_hardware(reports))
    lines.extend(["", "## Metodologi", ""])
    lines.extend(
        [
            "- Semua angka dibaca langsung dari laporan TOML; skrip ini tidak menjalankan workload dan tidak mengarang sampel.",
            "- p50 dan p95 memakai *nearest-rank*. Warmup dan pemuatan data berada di luar sampel latensi yang diringkas.",
            "- Pengukuran antarversi bermakna hanya saat perangkat, data, jumlah baris, warmup, dan beban sistem sebanding. Label durabilitas dicantumkan karena biaya flush memengaruhi write.",
            "- Workload TPC-C memakai driver tertutup, skala/generator yang diungkap, tanpa terminal think time atau audit TPC. Workload TPC-H memakai data sintetis kecuali laporan menyebut DBGEN eksternal; tidak menjalankan prosedur power/throughput/refresh resmi.",
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
        raise ReportError(f"gagal menulis {destination}: {error}") from error
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
    print(f"Laporan tersimpan: {destination}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
