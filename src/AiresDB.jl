# SPDX-FileCopyrightText: 2026 Aires Zam Wibisono
# SPDX-License-Identifier: NCSA

module AiresDB

using Dates
using Base64
using HTTP
using JSON3
using OpenSSL_jll
using Random
using SHA
using TOML
using UUIDs

export TinyServerConfig, TinyServer, start_tinyserver, stop_tinyserver!, server_url,
       initialize_root_credentials!, tinyserver_handler, run_client, cli_main

include("errors.jl")
include("types.jl")
include("tokens.jl")
include("lexer.jl")
include("ast.jl")
include("parser.jl")
include("catalog.jl")
include("expressions.jl")
include("semantic.jl")
include("storage.jl")
include("storage/page.jl")
include("storage/rid.jl")
include("storage/slottedpage.jl")
include("storage/bufferpool.jl")
include("storage/rowcodec.jl")
include("storage/recordmanager.jl")
include("storage/btree.jl")
include("storage/rollingpipeline.jl")
include("wal.jl")
include("mvcc.jl")
include("storage/pagestore.jl")
include("transactions.jl")
include("executor.jl")
include("api.jl")
include("relational.jl")
include("formatter.jl")
include("tinyserver.jl")
include("cli.jl")

"""Internal engine surface for TinyServer implementation, regression tests, and benchmarks."""
module Internal
using ..AiresDB: Session, execute!, execute_script!, parse_airesql, tokenize,
    QueryResult, format_table, AiresError, Decimal, Money, Engine,
    begin_transaction!, commit!, rollback!, with_transaction, with_snapshot,
    lookup, bulk_insert!, update_key!, delete_key!, scan_rows, table_columns,
    checkpoint!, vacuum!, mvcc_stats, storage_stats,
    RollingScheduler, StorageWorkUnit, StorageOperation, StoragePointLookup,
    StorageSequentialScan, StorageWrite, StorageIndex, StorageLaneState,
    LaneEmpty, LanePhase1, LanePhase2, LanePhase3, LanePhase4, LaneBlockedIO,
    LaneBlockedLatch, LaneDone, LaneError, StoragePhaseHandlers,
    StoragePhaseResult, phase_advance, phase_blocked_io, phase_blocked_latch,
    phase_complete, submit!, tick!, resume_lane!, run_until_complete!,
    pipeline_stats, pipeline_lane_states, request_result, btree_bulk_load!,
    RelTable, relation, rfilter, rmap, rproject, rrename, hashjoin, groupby, raggregate,
    rsort, rlimit, rdistinct, runion, query_result, RelAgg, Count, Sum, Avg, Min, Max,
    CountDistinct, SqlLike, sqllike, sqlin, sqlcmp, sqlnot, sqland, sqlor, radd, rsub, rmul, rdiv

export Session, execute!, execute_script!, parse_airesql, tokenize,
    QueryResult, format_table, AiresError, Decimal, Money, Engine,
    begin_transaction!, commit!, rollback!, with_transaction, with_snapshot,
    lookup, bulk_insert!, update_key!, delete_key!, scan_rows, table_columns,
    checkpoint!, vacuum!, mvcc_stats, storage_stats,
    RollingScheduler, StorageWorkUnit, StorageOperation, StoragePointLookup,
    StorageSequentialScan, StorageWrite, StorageIndex, StorageLaneState,
    LaneEmpty, LanePhase1, LanePhase2, LanePhase3, LanePhase4, LaneBlockedIO,
    LaneBlockedLatch, LaneDone, LaneError, StoragePhaseHandlers,
    StoragePhaseResult, phase_advance, phase_blocked_io, phase_blocked_latch,
    phase_complete, submit!, tick!, resume_lane!, run_until_complete!,
    pipeline_stats, pipeline_lane_states, request_result, btree_bulk_load!,
    RelTable, relation, rfilter, rmap, rproject, rrename, hashjoin, groupby, raggregate,
    rsort, rlimit, rdistinct, runion, query_result, RelAgg, Count, Sum, Avg, Min, Max,
    CountDistinct, SqlLike, sqllike, sqlin, sqlcmp, sqlnot, sqland, sqlor, radd, rsub, rmul, rdiv
end

end
