# Contributing to AiresDB

Thank you for helping improve AiresDB. Use Julia 1.12 and keep each change as
small and focused as practical without changing the character of AiresQL.
Storage and transaction changes must preserve MVCC boundaries, WAL-before-data,
recovery behavior, and `Commit Outcome Unknown` semantics.

1. Create a branch from `main`.
2. Run `julia --startup-file=no --project=. -e 'using Pkg; Pkg.test()'`.
3. Add a regression test for each bug fix or behavior change when practical.
4. Do not commit `.aires` databases, the `work/` directory, system images,
   caches, or temporary benchmark output.
5. Describe the behavior change, reason, test results, and remaining risks in
   the pull request.

By submitting a contribution, you agree that it is distributed under the
University of Illinois/NCSA Open Source License in `LICENSE`, unless the
maintainer agrees otherwise in writing. New product files under `src/` or
`bin/` must begin with:

```text
# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA
```

Contributors may add their own `SPDX-FileCopyrightText` line. Do not copy the
complete license text into every file.

The TPC-C and TPC-H benchmarks in this project are TPC-derived engineering
workloads. Do not describe their results as certified, compliant, `tpmC`, or
`QphH`.
