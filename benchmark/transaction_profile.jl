#!/usr/bin/env julia
"""Break a small TPC-C-derived transaction into begin/body/commit timings."""

include("AiresBench.jl")
using .AiresBench
using AiresDB
using AiresDB.Internal
const AB = AiresDB

length(ARGS) == 2 || error("Usage: transaction_profile.jl DATABASE_DIRECTORY DATABASE")
session = Session(ARGS[1])
execute!(session,"Pilih '$(ARGS[2])' -:")

function measure_transaction!(f::Function,label)
    started = time_ns()
    begin_transaction!(session)
    after_begin = time_ns()
    try
        f(session)
        after_body = time_ns()
        commit!(session)
        finished = time_ns()
        println(label," begin_ms=",(after_begin-started)/1e6,
            " body_ms=",(after_body-after_begin)/1e6,
            " commit_ms=",(finished-after_body)/1e6,
            " total_ms=",(finished-started)/1e6)
    catch
        AiresDB.in_transaction(session) && rollback!(session)
        rethrow()
    end
end

function profiled_commit!(session)
    tx = session.transaction::AB.TransactionState
    handle = session.handle::AB.DatabaseHandle
    marks = Pair{String,Float64}[]
    previous = time_ns()
    mark(label) = begin
        now = time_ns(); push!(marks,label => (now-previous)/1e6); previous = now
    end
    lock(handle.mutex) do
        AB.with_wal_lock(handle.path) do
            AB.refresh_locked!(handle,session.storage); mark("refresh")
            AB.certify!(handle,tx); mark("certify")
            csn = handle.csn + UInt64(1)
            catalog = tx.catalog_dirty || !isempty(tx.ddl) ? csn : handle.catalog_epoch
            db = AB.merge_transaction(handle,tx,csn); mark("merge")
            bytes = AB.delta_payload(session.storage,handle,db,tx,csn,catalog); mark("wal_encode")
            handle.poisoned = true
            lsn = AB.wal_append_locked(handle.path,handle.lsn,bytes); mark("wal_sync")
            store = handle.page_store::AB.PageStore
            lock(store.mutex) do
                plan = AB._PageCommitPlan(store,handle.current,db,tx,csn,lsn,copy(handle.file_id))
                AB.set_wal_durable_lsn!(store.manager,lsn)
                for name in sort!(collect(tx.dirty))
                    if name in tx.ddl
                        if haskey(db.tables,name)
                            store.tables[name] = AB._page_store_build_table!(store,db.tables[name],csn,lsn)
                        else
                            delete!(store.tables,name)
                        end
                    else
                        AB._page_store_apply_table_changes!(store,handle.current.tables[name],db.tables[name],
                            tx.working.tables[name],csn,lsn)
                    end
                    mark("page_table_" * name)
                end
                AB.flush_all!(store.pool;sync=true); mark("page_data_sync")
                AB._page_store_publish_plan!(plan); mark("page_catalog")
            end
            AB.publish_versions!(handle,db,tx.dirty,tx.ddl,csn,catalog;
                change_tables=tx.working.tables); mark("mvcc_publish")
            handle.lsn = lsn; handle.offset = filesize(handle.path); handle.poisoned = false
            session.database = handle.current; session.revision = handle.csn
            AB.finish_transaction!(session); mark("finish")
        end
    end
    println("commit_phases=",marks)
end

for iteration in 1:5
    measure_transaction!("Payment") do tx
        AiresBench.payment!(tx,1,1,1,1,1,1000;history_id=10000+iteration)
    end
end
for iteration in 1:5
    measure_transaction!("NewOrder") do tx
        AiresBench.new_order!(tx,1,1,1,collect(1:5),fill(5,5),fill(1,5))
    end
end
begin_transaction!(session)
AiresBench.new_order!(session,1,1,1,collect(1:5),fill(5,5),fill(1,5))
profiled_commit!(session)
println("storage=",storage_stats(session))
close(session)
