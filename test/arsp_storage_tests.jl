using Test
using AiresDB
using AiresDB.Internal

const ARSP = AiresDB

@testset "ARSP-4 page storage primitives" begin
    @testset "page manager persists and rejects corruption" begin
        mktempdir() do dir
            path = joinpath(dir,"pages.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            page = ARSP.allocate_page!(manager,ARSP.PageTypeHeap;page_lsn=0)
            page.bytes[100] = 0x5a
            ARSP.finalize_page!(page)
            ARSP.write_page!(manager,page;sync=true)
            @test ARSP.read_page(manager,page.id).bytes[100] == 0x5a

            ARSP.set_page_lsn!(page,1)
            @test_throws ARSP.AiresError ARSP.write_page!(manager,page)
            ARSP.set_wal_durable_lsn!(manager,1)
            ARSP.write_page!(manager,page;sync=true)
            stats = ARSP.page_manager_stats(manager)
            @test stats.page_size == 512
            @test stats.allocations == 1
            close(manager)

            reopened = ARSP.open_page_manager(path;page_size=512,durable_lsn=1)
            @test ARSP.read_page(reopened,page.id).bytes[100] == 0x5a
            close(reopened)

            open(path,"r+") do io
                seek(io,512 + 99) # Page 1, byte 100; file offsets are zero-based.
                write(io,UInt8(0xaa))
                flush(io)
            end
            corrupt = ARSP.open_page_manager(path;page_size=512,durable_lsn=1)
            @test_throws ARSP.AiresError ARSP.read_page(corrupt,page.id)
            close(corrupt)
        end
    end

    @testset "slotted page keeps stable slot identities" begin
        page = ARSP.Page(1,ARSP.PageTypeHeap;page_size=512)
        ARSP.init_slotted_page!(page,ARSP.PageTypeHeap)
        first_slot = ARSP.slotted_insert!(page,fill(UInt8(0x11),40))
        second_slot = ARSP.slotted_insert!(page,fill(UInt8(0x22),60))
        @test first_slot == 1
        @test ARSP.slotted_read(page,second_slot) == fill(UInt8(0x22),60)
        ARSP.slotted_delete!(page,first_slot)
        ARSP.slotted_compact!(page)
        @test ARSP.slotted_read(page,second_slot) == fill(UInt8(0x22),60)
        @test_throws ARSP.AiresError ARSP.slotted_read(page,first_slot)
        ARSP.slotted_update!(page,second_slot,fill(UInt8(0x33),80))
        @test ARSP.slotted_read(page,second_slot) == fill(UInt8(0x33),80)
        @test_throws ARSP.AiresError ARSP.slotted_insert!(page,fill(UInt8(0x44),500))
    end

    @testset "buffer pool bounds pins and flushes dirty frames" begin
        mktempdir() do dir
            path = joinpath(dir,"buffer.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            first = ARSP.allocate_page!(manager,ARSP.PageTypeHeap)
            second = ARSP.allocate_page!(manager,ARSP.PageTypeHeap)
            pool = ARSP.BufferPool(manager;capacity=1)
            pinned = ARSP.fetch_page!(pool,first.id)
            @test ARSP.try_fetch_page!(pool,second.id) === nothing
            ARSP.unpin_page!(pool,pinned)
            replacement = ARSP.fetch_page!(pool,second.id)
            replacement.page.bytes[100] = 0x7e
            ARSP.finalize_page!(replacement.page)
            ARSP.unpin_page!(pool,replacement;dirty=true)
            for _ in 1:64
                repeated = ARSP.fetch_page!(pool,second.id)
                ARSP.unpin_page!(pool,repeated)
            end
            @test ARSP.buffer_pool_stats(pool).pinned_pages == 0
            ARSP.flush_all!(pool;sync=true)
            stats = ARSP.buffer_pool_stats(pool)
            @test stats.misses >= 2
            @test stats.buffer_waits >= 1
            @test stats.dirty_flushes >= 1
            close(pool)
            reopened = ARSP.open_page_manager(path;page_size=512,durable_lsn=0)
            @test ARSP.read_page(reopened,second.id).bytes[100] == 0x7e
            close(reopened)
        end
    end

    @testset "heap batch append finalizes packed pages and survives reopen" begin
        mktempdir() do dir
            path = joinpath(dir,"heap-batch.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            pool = ARSP.BufferPool(manager;capacity=8)
            columns = [ARSP.ColumnDef("Value",:C,255,false,false,true,false)]
            heap = ARSP.create_heap!(pool,columns)
            payloads = [fill(UInt8(index),40) for index in 1:100]
            rids = ARSP.heap_insert_raw_batch!(pool,heap,payloads)
            @test length(rids) == length(payloads)
            @test heap.page_count > 1
            @test ARSP.heap_read_raw(pool,first(rids)) == first(payloads)
            @test ARSP.heap_read_raw(pool,last(rids)) == last(payloads)
            ARSP.flush_all!(pool;sync=true)
            meta_id = heap.meta_page_id
            close(pool)

            reopened_manager = ARSP.open_page_manager(path;page_size=512,durable_lsn=0)
            reopened_pool = ARSP.BufferPool(reopened_manager;capacity=8)
            reopened_heap = ARSP.open_heap(reopened_pool,meta_id,columns)
            @test reopened_heap.page_count == heap.page_count
            @test ARSP.heap_read_raw(reopened_pool,rids[57]) == payloads[57]
            close(reopened_pool)
        end
    end

    @testset "heap RID forwarding survives reopen without duplicate scan rows" begin
        mktempdir() do dir
            path = joinpath(dir,"heap.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            pool = ARSP.BufferPool(manager;capacity=8)
            columns = [ARSP.ColumnDef("Value",:C,255,false,false,true,false)]
            heap = ARSP.create_heap!(pool,columns)
            anchor = ARSP.heap_insert_raw!(pool,heap,fill(UInt8(0x31),16))
            ARSP.heap_insert_raw!(pool,heap,fill(UInt8(0x32),300))
            updated = ARSP.heap_update_raw!(pool,heap,anchor,fill(UInt8(0x41),180))
            @test updated == anchor
            @test ARSP.heap_read_raw(pool,anchor) == fill(UInt8(0x41),180)
            ARSP.heap_update_raw!(pool,heap,anchor,fill(UInt8(0x42),160))
            @test ARSP.heap_read_raw(pool,anchor) == fill(UInt8(0x42),160)
            cursor = ARSP.heap_batch_cursor(heap,pool;batch_size=16)
            rows = only(collect(cursor))
            @test count(item->item[1] == anchor,rows) == 0
            @test count(item->item[2] == fill(UInt8(0x42),160),rows) == 1
            ARSP.flush_all!(pool;sync=true)
            meta_id = heap.meta_page_id
            close(pool)

            reopened_manager = ARSP.open_page_manager(path;page_size=512,durable_lsn=0)
            reopened_pool = ARSP.BufferPool(reopened_manager;capacity=8)
            reopened_heap = ARSP.open_heap(reopened_pool,meta_id,columns)
            @test ARSP.heap_read_raw(reopened_pool,anchor) == fill(UInt8(0x42),160)
            @test reopened_heap.first_page_id != 0
            close(reopened_pool)
        end
    end

    @testset "persistent B+Tree splits, ranges, deletion and reopen" begin
        mktempdir() do dir
            path = joinpath(dir,"btree.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            pool = ARSP.BufferPool(manager;capacity=32)
            tree = ARSP.create_btree!(pool)
            for key in 1:300
                try
                    ARSP.btree_insert!(pool,tree,Int64(key),ARSP.RID(UInt64(key),UInt16(1)))
                catch
                    @info "B+Tree buffer failure" key=key stats=ARSP.buffer_pool_stats(pool)
                    rethrow()
                end
            end
            @test tree.height >= 2
            @test ARSP.btree_lookup(pool,tree,Int64(1)) == ARSP.RID(1,1)
            @test ARSP.btree_lookup(pool,tree,Int64(300)) == ARSP.RID(300,1)
            @test ARSP.btree_lookup(pool,tree,Int64(301)) === nothing
            @test_throws ARSP.AiresError ARSP.btree_insert!(pool,tree,Int64(42),ARSP.RID(999,1))
            forward = ARSP.btree_range(pool,tree;lower=Int64(20),upper=Int64(25))
            @test [rid.page_id for (_,rid) in forward] == UInt64[20,21,22,23,24,25]
            backward = ARSP.btree_descending(pool,tree;lower=Int64(20),upper=Int64(25))
            @test [rid.page_id for (_,rid) in backward] == UInt64[25,24,23,22,21,20]
            cursor = ARSP.btree_range_cursor(pool,tree;lower=Int64(20),upper=Int64(25))
            cursor_rows = vcat(ARSP.next_btree_batch!(cursor;batch_size=2),
                               ARSP.next_btree_batch!(cursor;batch_size=2),
                               ARSP.next_btree_batch!(cursor;batch_size=2))
            @test [rid.page_id for (_,rid) in cursor_rows] == UInt64[20,21,22,23,24,25]
            @test ARSP.next_btree_batch!(cursor;batch_size=2) === nothing
            @test ARSP.btree_delete!(pool,tree,Int64(42))
            @test ARSP.btree_lookup(pool,tree,Int64(42)) === nothing
            @test !ARSP.btree_delete!(pool,tree,Int64(42))
            @test ARSP.btree_compare(ARSP.btree_key(ARSP.Decimal("-1.5")),ARSP.btree_key(ARSP.Decimal("0"))) < 0
            @test ARSP.btree_compare(ARSP.btree_key(ARSP.Decimal("0.01")),ARSP.btree_key(ARSP.Decimal("0.1"))) < 0
            @test ARSP.btree_compare(ARSP.btree_key(("aa",)),ARSP.btree_key(("b",))) < 0
            meta_id = tree.meta_page_id
            ARSP.flush_all!(pool;sync=true)
            close(pool)

            reopened_manager = ARSP.open_page_manager(path;page_size=512,durable_lsn=0)
            reopened_pool = ARSP.BufferPool(reopened_manager;capacity=32)
            reopened_tree = ARSP.open_btree(reopened_pool,meta_id)
            @test ARSP.btree_lookup(reopened_pool,reopened_tree,Int64(299)) == ARSP.RID(299,1)
            @test ARSP.btree_lookup(reopened_pool,reopened_tree,Int64(42)) === nothing
            @test ARSP.btree_stats(reopened_pool,reopened_tree).entries == 299
            close(reopened_pool)
        end
    end

    @testset "persistent B+Tree bulk load sorts atomically and survives reopen" begin
        mktempdir() do dir
            path = joinpath(dir,"btree-bulk.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            pool = ARSP.BufferPool(manager;capacity=32)
            tree = ARSP.create_btree!(pool)

            # Deliberately reverse the input.  The bulk loader owns ordering;
            # callers must not need to pre-sort a transaction write batch.
            entries = [(Int64(key),ARSP.RID(UInt64(key),UInt16(7))) for key in 300:-1:1]
            ARSP.btree_bulk_load!(pool,tree,entries)
            @test tree.height >= 2
            @test ARSP.btree_stats(pool,tree).entries == 300
            @test ARSP.btree_lookup(pool,tree,Int64(1)) == ARSP.RID(1,7)
            @test ARSP.btree_lookup(pool,tree,Int64(300)) == ARSP.RID(300,7)
            @test [rid.page_id for (_,rid) in ARSP.btree_range(pool,tree;lower=Int64(47),upper=Int64(53))] == UInt64[47,48,49,50,51,52,53]
            @test [rid.page_id for (_,rid) in ARSP.btree_descending(pool,tree;lower=Int64(47),upper=Int64(53))] == UInt64[53,52,51,50,49,48,47]

            meta_id = tree.meta_page_id
            ARSP.flush_all!(pool;sync=true)
            close(pool)

            reopened_manager = ARSP.open_page_manager(path;page_size=512,durable_lsn=0)
            reopened_pool = ARSP.BufferPool(reopened_manager;capacity=32)
            reopened_tree = ARSP.open_btree(reopened_pool,meta_id)
            @test ARSP.btree_stats(reopened_pool,reopened_tree).entries == 300
            @test [rid.page_id for (_,rid) in ARSP.btree_range(reopened_pool,reopened_tree;lower=Int64(298))] == UInt64[298,299,300]
            close(reopened_pool)
        end

        # Duplicate detection is validated before any new tree page is
        # published, so a rejected bulk transaction has no partial index.
        mktempdir() do dir
            path = joinpath(dir,"btree-bulk-duplicate.arsp")
            manager = ARSP.open_page_manager(path;create=true,page_size=512,durable_lsn=0)
            pool = ARSP.BufferPool(manager;capacity=8)
            tree = ARSP.create_btree!(pool)
            duplicate_batch = [(Int64(3),ARSP.RID(3,1)),
                               (Int64(1),ARSP.RID(1,1)),
                               (Int64(3),ARSP.RID(30,1))]
            @test_throws ARSP.AiresError ARSP.btree_bulk_load!(pool,tree,duplicate_batch)
            @test ARSP.btree_stats(pool,tree).entries == 0
            @test ARSP.btree_lookup(pool,tree,Int64(1)) === nothing
            @test ARSP.btree_lookup(pool,tree,Int64(3)) === nothing
            close(pool)
        end
    end
end
