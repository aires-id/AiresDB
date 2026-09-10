# ARSP-4 Buffer Pool

The ARSP-4 buffer pool is a bounded cache of fixed-size page frames. It sits
between heap/B+Tree/catalog code and the page manager:

```text
record manager / B+Tree
           ↓
       BufferPool
           ↓
    PageManager (8 KiB)
           ↓
          disk
```

## Frame and replacement policy

Each `BufferFrame` contains:

```text
page ID
page bytes
pin count
dirty flag
Clock reference bit
per-frame latch
```

The pool has a fixed capacity (64 frames by default) and a deterministic Clock
replacement policy. A pinned frame is never eligible for eviction. Dirty frames
are written through the page manager before their slot is reused.

The lookup map is only a page-ID-to-frame cache index; it is not used to store
rows or B+Tree data.

## API

```julia
frame = fetch_page!(pool, page_id)
mark_dirty!(pool, frame; page_lsn)
unpin_page!(pool, frame; dirty=true, page_lsn)

frame = new_page!(pool, PageTypeHeap; page_lsn)
prefetch_page!(pool, next_page_id)
flush_frame!(pool, frame; sync=true)
flush_all!(pool; sync=true)
```

`try_fetch_page!` returns `nothing` when all frames are pinned. ARSP P2 turns
that condition into a blocked lane and records a buffer wait instead of growing
the cache beyond its limit.

## I/O and read-ahead

The pool releases its mutex before a read miss reaches the page manager. ARSP P2
first performs a cache-only check, then delegates a miss to `Threads.@spawn`
through `fetch_page_wait!`; the worker waits on the pool's `Threads.Condition` when every
frame is pinned and resumes its own scheduler lane after acquisition, signaling the
scheduler's `Base.Event`. This lets
other ready scheduler lanes progress while P2 waits. PageStore still serializes
each public work-unit wrapper under its store mutex, and deeper B+Tree/heap P3
traversal can still use a synchronous fetch, so this is not unlimited end-to-end
request concurrency. A sequential heap cursor prefetches its next linked page
after completing a page, then immediately unpins the prefetched frame.

Concurrent duplicate misses may perform a redundant read; the second reader
uses the already-installed frame. This favors a short critical section over
holding the pool-wide mutex during disk I/O.

## WAL rule

The page manager tracks the highest durable WAL LSN. `write_page!` rejects a
page whose `page_lsn` is newer than that watermark. Consequently a dirty
committed page cannot be flushed before its WAL transaction is durable.

There is no background flusher in this release. PageStore flushes its dirty
data/index frames before publishing the applied-LSN catalog marker, and pool
close flushes remaining frames. A future asynchronous flusher must preserve the
same page-LSN check.

## Statistics

`buffer_pool_stats(pool)` reports capacity, used frames, pinned frames and pin
count, hits, misses, evictions, dirty flushes, buffer waits, prefetches, and hit
ratio. `storage_stats(session)` nests these values with page-manager and ARSP
pipeline statistics.
