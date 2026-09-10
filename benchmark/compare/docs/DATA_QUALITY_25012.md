# Data-quality evidence — ISO/IEC 25012:2008

[ISO/IEC 25012:2008](https://www.iso.org/standard/35736.html), confirmed by ISO
in 2025, defines a structured-data quality model with fifteen characteristics.
This suite turns the applicable characteristics into repeatable checks over
synthetic benchmark data. It cannot establish that synthetic data are accurate
about a real business domain.

| ISO/IEC 25012 characteristic | Check | Evidence field |
| --- | --- | --- |
| Accuracy | deterministic expected aggregate and differential query result | aggregate/result digest |
| Completeness | expected row counts per table and no unexpected NULL in required fixture fields | cardinalities/null checks |
| Consistency | primary-key uniqueness and TPC-C-derived state invariants | `consistency` |
| Credibility | generator seed, source file hashes, package versions, and no hidden row transformation | provenance block |
| Currentness | dataset generation timestamp and fixed logical date values | configuration/timestamp |
| Accessibility | each engine can reopen/read all persisted fixture rows | reopen test |
| Compliance | declared types, primary keys, and SQL constraints are checked per engine | schema verification |
| Confidentiality | synthetic data only; no personal production data are accepted | scope statement |
| Efficiency | load, scan, lookup, range, aggregate, mutation, and query durations | workload samples |
| Precision | money stays integer cents; result canonicalization rejects lossy type coercion | typed digest |
| Traceability | seed → generated rows → schema → report digest chain | manifest + traceability |
| Understandability | data dictionary derives from `C_SCHEMA` / `H_SCHEMA` | report schema block |
| Availability | successful open/reopen at the local test moment | reopen result only |
| Portability | portable logical data are loaded through each native binding | per-engine loading result |
| Recoverability | AiresDB WAL/recovery evidence comes from root tests; compare suite checks clean reopen | explicitly limited |

## Measurement rules

- A digest is computed over typed, canonical row values, ordered by declared
  key/order columns. It is not a checksum of engine storage files.
- Any data mismatch fails verification before timings are considered.
- `NULL`, integer cents, text, and ISO date strings remain distinguishable in
  canonicalization; `Float64` is not used for currency fixture values.
- TPC-derived fixtures are synthetic and are not source data for a data-quality
  claim about an operational organization.
