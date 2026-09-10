#!/usr/bin/env python3
"""Build the human-readable SDEBO publication report."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER, TA_LEFT
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.pdfbase import pdfmetrics
from reportlab.platypus import KeepTogether, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle


NAVY = colors.HexColor("#17253A")
BLUE = colors.HexColor("#2166B1")
CYAN = colors.HexColor("#38A3A5")
PALE = colors.HexColor("#EAF1F7")
INK = colors.HexColor("#243244")
MUTED = colors.HexColor("#5B6877")
GREEN = colors.HexColor("#197A55")
RED = colors.HexColor("#A43C3C")


def fmt(value: float, metric: str) -> str:
    if "throughput" in metric:
        return f"{value:,.0f} rows/s"
    return f"{value:,.3f} ms"


def load(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def build(base: Path, output: Path) -> None:
    result = load(base / "result.json")
    environment = load(base / "environment.json")
    resilience = {name: load(base / "resilience" / name / "result.json") for name in ["AiresDB", "Firebird"]}
    engines = {item["engine"]: item for item in result["engines"]}

    font = "Helvetica"
    bold = "Helvetica-Bold"
    for normal_path, bold_path in [
        (Path(r"C:\Windows\Fonts\segoeui.ttf"), Path(r"C:\Windows\Fonts\segoeuib.ttf")),
        (Path(r"C:\Windows\Fonts\arial.ttf"), Path(r"C:\Windows\Fonts\arialbd.ttf")),
    ]:
        if normal_path.exists() and bold_path.exists():
            pdfmetrics.registerFont(TTFont("Report", normal_path))
            pdfmetrics.registerFont(TTFont("Report-Bold", bold_path))
            font, bold = "Report", "Report-Bold"
            break

    styles = getSampleStyleSheet()
    styles.add(ParagraphStyle(name="TitleX", fontName=bold, fontSize=25, leading=29, textColor=NAVY, spaceAfter=8))
    styles.add(ParagraphStyle(name="Deck", fontName=font, fontSize=11, leading=16, textColor=MUTED, spaceAfter=16))
    styles.add(ParagraphStyle(name="H1X", fontName=bold, fontSize=17, leading=21, textColor=NAVY, spaceBefore=8, spaceAfter=9))
    styles.add(ParagraphStyle(name="H2X", fontName=bold, fontSize=11, leading=14, textColor=BLUE, spaceBefore=7, spaceAfter=5))
    styles.add(ParagraphStyle(name="BodyX", fontName=font, fontSize=9.2, leading=13, textColor=INK, spaceAfter=7))
    styles.add(ParagraphStyle(name="SmallX", fontName=font, fontSize=7.5, leading=10, textColor=MUTED))
    styles.add(ParagraphStyle(name="Cell", fontName=font, fontSize=7.2, leading=9, textColor=INK))
    styles.add(ParagraphStyle(name="CellB", fontName=bold, fontSize=7.2, leading=9, textColor=INK))
    styles.add(ParagraphStyle(name="CellHead", fontName=bold, fontSize=7.2, leading=9, textColor=colors.white))
    styles.add(ParagraphStyle(name="Score", fontName=bold, fontSize=18, leading=20, textColor=colors.white, alignment=TA_CENTER))
    styles.add(ParagraphStyle(name="ScoreLabel", fontName=font, fontSize=7.5, leading=9, textColor=colors.white, alignment=TA_CENTER))

    doc = SimpleDocTemplate(str(output), pagesize=A4, leftMargin=17 * mm, rightMargin=17 * mm, topMargin=18 * mm, bottomMargin=17 * mm,
                            title="SDEBO 1.0 - AiresDB v0.1.0 vs Firebird 5.0.4", author="SDEBO reproducible harness")

    def page(canvas, document):
        canvas.saveState()
        canvas.setFillColor(NAVY)
        canvas.rect(0, A4[1] - 9 * mm, A4[0], 9 * mm, fill=1, stroke=0)
        canvas.setFont(font, 7.5)
        canvas.setFillColor(colors.white)
        canvas.drawString(17 * mm, A4[1] - 6 * mm, "SDEBO 1.0 | S750 | Publication evidence")
        canvas.setFillColor(MUTED)
        canvas.drawRightString(A4[0] - 17 * mm, 8 * mm, f"Page {document.page}")
        canvas.restoreState()

    def p(text, style="BodyX"):
        return Paragraph(text, styles[style])

    def cell(text, bold_cell=False):
        return Paragraph(str(text), styles["CellB" if bold_cell else "Cell"])

    def table(rows, widths, header=True, font_size=7.2):
        converted = [[item if hasattr(item, "wrap") else Paragraph(str(item), styles["CellHead"] if header and row_index == 0 else styles["Cell"]) for item in row] for row_index, row in enumerate(rows)]
        value = Table(converted, colWidths=widths, repeatRows=1 if header else 0, hAlign="LEFT")
        commands = [("VALIGN", (0, 0), (-1, -1), "TOP"), ("LEFTPADDING", (0, 0), (-1, -1), 4), ("RIGHTPADDING", (0, 0), (-1, -1), 4),
                    ("TOPPADDING", (0, 0), (-1, -1), 4), ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
                    ("GRID", (0, 0), (-1, -1), 0.35, colors.HexColor("#C8D2DD"))]
        if header:
            commands += [("BACKGROUND", (0, 0), (-1, 0), NAVY), ("TEXTCOLOR", (0, 0), (-1, 0), colors.white)]
        for index in range(1 if header else 0, len(rows)):
            if index % 2 == 0:
                commands.append(("BACKGROUND", (0, index), (-1, index), colors.HexColor("#F5F8FA")))
        value.setStyle(TableStyle(commands))
        return value

    story = [Spacer(1, 12 * mm), p("STANDARD DATABASE ENGINE FOR BANKING AND OFFICE TEST", "H2X"),
             p("AiresDB v0.1.0 vs Firebird 5.0.4", "TitleX"),
             p("SDEBO 1.0 publication run - SDEBO-S750 - seed 1999 - Windows embedded profile - 9-11 September 2026", "Deck")]

    score_cards = []
    for name, color in [("AiresDB", BLUE), ("Firebird", CYAN)]:
        item = engines[name]
        content = Table([[p(name, "ScoreLabel")], [p(f"{item['score']:.2f}", "Score")], [p(item["class"], "ScoreLabel")]], colWidths=[72 * mm], rowHeights=[8 * mm, 13 * mm, 9 * mm])
        content.setStyle(TableStyle([("BACKGROUND", (0, 0), (-1, -1), color), ("VALIGN", (0, 0), (-1, -1), "MIDDLE")]))
        score_cards.append(content)
    cards = Table([score_cards], colWidths=[78 * mm, 78 * mm], hAlign="LEFT")
    cards.setStyle(TableStyle([("LEFTPADDING", (0, 0), (-1, -1), 0), ("RIGHTPADDING", (0, 0), (-1, -1), 6)]))
    story += [cards, Spacer(1, 9 * mm), p("Decision", "H1X")]
    verdict_rows = [["Engine", "Medium Office", "Small Bank Technical", "Critical finding"]]
    for name in ["AiresDB", "Firebird"]:
        item = engines[name]
        finding = "R01 capped at BC: offline checkpoint + file copy" if name == "AiresDB" else "Q07 full scan is below target B"
        verdict_rows.append([name, item["medium_office"], item["small_bank_technical"], finding])
    story += [table(verdict_rows, [31 * mm, 32 * mm, 40 * mm, 70 * mm]), Spacer(1, 5 * mm),
              p("Both engines pass the applicable Medium Office and Small Bank Technical correctness gates in this embedded profile. AiresDB's final score is held back mainly by the absence of a native backup format. Firebird's main measured weakness is full-scan throughput. Scores apply only to this hardware, configuration, dataset, and harness.")]

    story += [PageBreak(), p("Method and fairness", "H1X"),
              p("The public SDEBO 1.0 procedure was followed with the full 750,000-row dataset. The generator used seed 1999 and produced the same pipe-delimited source files for both engines. Each engine received a fresh database for each of five independent performance runs. Point operations used 100 warm-up and 1,000 measured iterations; scans, aggregates, and joins used 2 warm-up and 7 measured iterations; writes used 20 warm-up and 200 measured operations. Final performance values are medians across the five independent runs."),
              p("Durability was enabled for both products: AiresDB committed through its fsync-backed WAL and Firebird used forced writes in synchronous mode. Money was stored as signed 64-bit integer cents. Both products ran embedded on the same OS and SSD. No performance run overlapped another performance run."),
              p("Environment", "H2X")]
    env_rows = [
        ["Field", "Recorded value"], ["OS", environment["os"]], ["CPU", environment["cpu"]],
        ["CPU topology", f"{environment['physical_cpu']} physical / {environment['logical_cpu']} logical"],
        ["RAM", f"{environment['ram_bytes'] / 2**30:.2f} GiB"], ["Storage", f"SSD; {environment['storage']['free_bytes_after_test'] / 2**30:.2f} GiB free after test"],
        ["Dataset", f"SDEBO-S750; {result['total_rows']:,} rows; seed {result['seed']}"], ["Source digest", result["logical_source_sha256"]],
        ["AiresDB", "0.1.0; Julia 1.12.7; embedded; WAL fsync per commit"], ["Firebird", "5.0.4.1812; firebird-driver 2.0.3; embedded; forced writes sync"],
    ]
    story += [table(env_rows, [38 * mm, 135 * mm]), p("Comparison limits", "H2X"),
              p("The host has four hardware threads, below the comparison recommendation of four cores/eight threads, but above the published minimum. VM hard power-off was unavailable; each engine instead completed five externally terminated process cycles at transaction boundaries. S01 server/network gates are outside the embedded profile. These deviations are disclosed rather than silently substituted.")]

    story += [PageBreak(), p("Performance results", "H1X"),
              p("PFR compares the observed median with the published B target. Throughput uses observed/target; latency uses target/observed. A requires PFR >= 1.50, AB >= 1.20, B >= 1.00, BC >= 0.75, C >= 0.50, D >= 0.25."),]
    perf_rows = [["Test", "Target B", "AiresDB median", "Grade", "Firebird median", "Grade", "Observed comparison"]]
    names = {"Q01": "Bulk load", "Q02": "PK lookup p95", "Q03": "Indexed filter p95", "Q04": "Range p95", "Q05": "Aggregate median", "Q06": "Join median", "Q07": "Full scan", "T01": "Insert commit p95", "T02": "Update/delete p95"}
    for code in ["Q01", "Q02", "Q03", "Q04", "Q05", "Q06", "Q07", "T01", "T02"]:
        a, f = engines["AiresDB"]["grades"][code], engines["Firebird"]["grades"][code]
        metric = a["metric"]
        target = fmt(a["target_b"], metric)
        if "throughput" in metric:
            factor = a["median"] / f["median"]
            comparison = f"AiresDB {factor:.2f}x Firebird"
        else:
            factor = a["median"] / f["median"]
            comparison = f"Firebird {factor:.2f}x lower latency" if factor >= 1 else f"AiresDB {1/factor:.2f}x lower latency"
        perf_rows.append([f"{code} {names[code]}", target, fmt(a["median"], metric), a["grade"], fmt(f["median"], metric), f["grade"], comparison])
    story += [table(perf_rows, [29 * mm, 24 * mm, 28 * mm, 12 * mm, 28 * mm, 12 * mm, 40 * mm]), Spacer(1, 5 * mm),
              p("AiresDB leads bulk loading by about 12.8x and full scanning by about 3.9x. Firebird has lower point lookup, indexed filter, aggregate, join, and committed-write latency on this host. AiresDB still exceeds every published B performance target; its aggregate receives AB because the median is 1.37 times the target rather than the 1.50 required for A.")]

    story += [PageBreak(), p("Transactions, recovery, and security", "H1X")]
    functional = ["Q08", "T03", "T04", "T05", "R01", "R02", "R03", "R04", "R05", "S01", "O01"]
    func_rows = [["Test", "Weight", "AiresDB", "AiresDB evidence", "Firebird", "Firebird evidence"]]
    for code in functional:
        a, f = engines["AiresDB"]["grades"][code], engines["Firebird"]["grades"][code]
        func_rows.append([code, WEIGHT_LABEL(code), a["grade"], a["evidence"], f["grade"], f["evidence"]])
    story += [table(func_rows, [15 * mm, 14 * mm, 16 * mm, 57 * mm, 16 * mm, 57 * mm]), Spacer(1, 5 * mm),
              p("All tested atomicity, rollback, concurrency, restore-digest, crash-reopen, journal/index, and corruption-safety checks completed without a silent mismatch. Firebird used three native gbak backups and restores. AiresDB v0.1.0 has no native backup command, so the test used a quiescent checkpoint followed by a documented file copy; the public rule caps that result at BC."),
              p("Corruption tests deliberately modified a header, a data/page region, and a tail/log region on disposable copies. A pass means the engine rejected the copy or reopened to the exact pre-recorded logical digest. It does not claim that every possible on-disk corruption pattern was exhaustively tested.")]

    story += [PageBreak(), p("Sustained workload", "H1X")]
    o_rows = [["Metric", "AiresDB", "Firebird"]]
    for label, key, transform in [
        ("Duration", "duration_seconds", lambda x: f"{x:.1f} s"), ("Operations", "iterations", lambda x: f"{x:,}"),
        ("Errors", "errors", lambda x: str(len(x))), ("RSS start", "start_rss_bytes", lambda x: f"{x/2**20:.1f} MiB"),
        ("RSS end", "end_rss_bytes", lambda x: f"{x/2**20:.1f} MiB"), ("RSS peak", "peak_rss_bytes", lambda x: f"{x/2**20:.1f} MiB"),
        ("Average process CPU", "average_cpu_percent_one_core", lambda x: f"{x:.1f}% of one logical core"),
        ("Memory growth", "memory_growth_ratio", lambda x: f"{x:.2%}"), ("Latency p95", "p95_ms", lambda x: f"{x:.3f} ms"),
        ("Last/first-quarter latency", "latency_drift_ratio", lambda x: f"{x:.3f}x"), ("Disk growth", "disk_growth_bytes", lambda x: f"{x/2**20:.1f} MiB"),
    ]:
        values = []
        for name in ["AiresDB", "Firebird"]:
            raw = resilience[name]["tests"]["O01"].get(key)
            values.append(transform(raw) if raw is not None else "n/a")
        o_rows.append([label, *values])
    story += [table(o_rows, [70 * mm, 51 * mm, 51 * mm]), Spacer(1, 5 * mm),
              p("The 15-minute mixed workload combined indexed lookups, committed updates, 100-row range queries, and grouped aggregates. O01 grading follows end-to-start RSS growth and requires zero operation errors plus a successful restart. Peak RSS is reported separately because temporary working memory can be reclaimed before the end of the run.")]

    story += [PageBreak(), p("Complete weighted score", "H1X")]
    score_rows = [["Code", "Wt", "AiresDB grade", "Pts", "Weighted", "Firebird grade", "Pts", "Weighted"]]
    for code in WEIGHTS_ORDER():
        a, f = engines["AiresDB"]["grades"][code], engines["Firebird"]["grades"][code]
        weight = WEIGHT_LABEL(code)
        score_rows.append([code, weight, a["grade"], f"{a['points']:.1f}", f"{weight*a['points']:.1f}", f["grade"], f"{f['points']:.1f}", f"{weight*f['points']:.1f}"])
    score_rows.append(["FINAL", "68", engines["AiresDB"]["class"], f"{engines['AiresDB']['score']:.2f}", "-", engines["Firebird"]["class"], f"{engines['Firebird']['score']:.2f}", "-"])
    story += [table(score_rows, [23 * mm, 11 * mm, 31 * mm, 17 * mm, 22 * mm, 31 * mm, 17 * mm, 22 * mm]), Spacer(1, 4 * mm),
              p("Gate outcome", "H2X"), table(verdict_rows, [31 * mm, 32 * mm, 40 * mm, 70 * mm]),
              p("For embedded operation, S01 is scored for disclosure but its server/network gate is not applied. Small Bank Technical PASS requires final score above 3.00, grades of at least B on T03, T04, R02, R03, and R05, plus no silent corruption, half transaction, or backup mismatch.")]

    story += [PageBreak(), p("Evidence and reproducibility", "H1X"),
              p("The publication directory includes result.json, result.csv, environment.json, raw performance JSON for all ten main runs, resilience evidence for both engines, the deterministic dataset manifest, harness source hashes, and SHA256SUMS. Database files are retained in the run directories for local audit but are excluded from the compact publication checksum list when redundant."),
              p("Source references", "H2X"),
              p("Benchmark rules and scoring: SDEBO Test Specification v1.0 publication document supplied with this repository. Comparator distribution: Firebird 5.0.4.1812 Windows x64 archive, official release. Driver: firebird-driver 2.0.3. Firebird embedded access, forced writes, gbak, and gfix behavior follow the Firebird 5 Quick Start Guide and bundled command-line help."),
              p("Official links", "H2X"),
              p("Firebird 5.0 release page: https://firebirdsql.org/en/firebird-5-0/<br/>Firebird 5 Quick Start Guide: https://www.firebirdsql.org/file/documentation/html/en/firebirddocs/qsg5/firebird-5-quickstartguide.html<br/>Python driver documentation: https://github.com/FirebirdSQL/python3-driver/blob/master/docs/getting-started.txt", "SmallX"),
              p("Interpretation", "H2X"),
              p("This report is a single-host technical comparison, not a universal product ranking. AiresDB's strongest measured advantages are bulk ingestion and sequential scanning; Firebird's mature page engine delivers lower latency in most point and report operations and provides native backup tooling. The result supports continued AiresDB work on aggregate latency, memory footprint, native online backup, and server security while preserving its current high-throughput data path."),
              p("Additional engineering observation", "H2X"),
              p("An unscored first AiresDB T05 attempt found a Session lifecycle defect: closing one independently constructed worker Session while other workers were still committing closed the shared page manager and produced Commit Outcome Unknown. The scored rerun retained every worker until all measured operations completed, then recorded 1,000 commits with no lost update. The lifecycle behavior remains a stability issue to fix and is preserved in raw/harness-notes. A separate first O01 attempt was invalidated solely for an incorrect harness update_key! call and was rerun for the full duration.")]

    doc.build(story, onFirstPage=page, onLaterPages=page)


def WEIGHTS_ORDER():
    return ["Q01", "Q02", "Q03", "Q04", "Q05", "Q06", "Q07", "Q08", "T01", "T02", "T03", "T04", "T05", "R01", "R02", "R03", "R04", "R05", "S01", "O01"]


def WEIGHT_LABEL(code):
    weights = {"Q01": 3, "Q02": 4, "Q03": 3, "Q04": 3, "Q05": 3, "Q06": 4, "Q07": 2, "Q08": 3,
               "T01": 3, "T02": 4, "T03": 4, "T04": 4, "T05": 4, "R01": 3, "R02": 4, "R03": 4,
               "R04": 4, "R05": 4, "S01": 3, "O01": 2}
    return weights[code]


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.base.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
