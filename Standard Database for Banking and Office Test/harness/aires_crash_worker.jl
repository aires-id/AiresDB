#!/usr/bin/env julia

using AiresDB
using AiresDB.Internal

length(ARGS) >= 2 || error("usage: aires_crash_worker.jl ROOT transfer|checkpoint [amount]")
root = ARGS[1]
mode = ARGS[2]
session = Session(root; storage=AiresDB.BinaryRowStore(4 * 1024 * 1024 * 1024))
execute!(session, "Pilih 'sdbeo' -:")

if mode == "transfer"
    amount = length(ARGS) >= 3 ? parse(Int64, ARGS[3]) : Int64(1)
    begin_transaction!(session)
    debit = lookup(session, "accounts", Int64(1))
    credit = lookup(session, "accounts", Int64(2))
    debit === nothing && error("missing debit account")
    credit === nothing && error("missing credit account")
    update_key!(session, "accounts", Int64(1), Dict("balance_cents" => debit[4] - amount))
    update_key!(session, "accounts", Int64(2), Dict("balance_cents" => credit[4] + amount))
    commit!(session)
elseif mode == "checkpoint"
    checkpoint!(session)
else
    error("unknown crash worker mode $mode")
end

close(session)
