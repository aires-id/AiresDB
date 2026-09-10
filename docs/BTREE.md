# Persistent B+Tree

ARSP-4 indexes are page-based `PersistentBTree` structures. They are not an
in-memory dictionary serialized at checkpoint time. Every node is an ARSP
slotted page and survives page-pool flush/reopen through a small metadata page.

```text
B+Tree metadata page: AIRESBP1
        │
        ▼
  internal node ─────── internal node
      │      │               │
    leaf ⇄ leaf ⇄ leaf ⇄ leaf
       key → RID
```

## Pages

The metadata page records root page ID, first leaf page ID, and tree height.
Internal nodes store a parent pointer, level, first child pointer, separator
keys, and remaining child pointers. Leaf nodes store a parent pointer, previous
and next leaf links, and `key → RID` records.

Node payloads are stored through the common slotted-page layer. Split operations
create a right sibling, rewrite the left node, repair the neighboring leaf link,
then insert the right-minimum separator into the parent. Internal splits promote
a separator; splitting the root creates a new root and updates the metadata
page.

## Keys

Keys are canonical bytes compared lexicographically. Implemented typed codecs
preserve order for signed/unsigned integers, `UInt128`, Bool, String, Date,
Time, DateTime, Money, finite Float64, Decimal, and composite tuples. Decimal
uses a sign/exponent/significand representation, so it remains exact rather than
being converted to Float64. Tuple components are byte-escaped and terminated to
preserve lexicographic composite-key order.

`NULL` never enters a unique/primary index. Nullable index ordering falls back
to the relational sort because AiresQL's NULL positioning must remain correct.

## Operations

```julia
tree = create_btree!(pool)
btree_bulk_load!(pool, tree, [(key, rid), ...])  # only an empty tree
btree_insert!(pool, tree, key, rid)
btree_lookup(pool, tree, key)
btree_delete!(pool, tree, key)
btree_range(pool, tree; lower, upper, reverse)

cursor = btree_range_cursor(pool, tree; lower, upper, reverse)
batch = next_btree_batch!(cursor; batch_size=256)
```

The cursor emits bounded ordered batches. PageStore avoids relational full
sorting for `M:` only when a single-table non-aggregate query uses bare column
references whose order tuple exactly matches a primary/unique B+Tree, all order
directions are the same, every ordered column is declared `NOT NULL`, and the
snapshot is current with no local table overlay. Other correct AiresQL orderings
fall back to the relational sort.

PageStore builds persistent trees for the primary/unique index specifications it
already maintains logically. The legacy hash indexes remain part of the existing
constraint and MVCC semantics; they are not the B+Tree's on-disk representation.
The current planner does not yet turn arbitrary predicate ranges into B+Tree
range scans; the direct persistent range primitive is separately available and
benchmarked.

`btree_bulk_load!` is the initial-load path used when PageStore fills a newly
created table. It canonicalizes and sorts all supplied key/RID pairs, rejects a
duplicate before a node is changed, packs leaf pages, then constructs internal
levels bottom-up and persists metadata. It accepts only a pristine empty tree;
transactional changes after that continue through `btree_insert!` and normal
split handling.

## Concurrency and durability

Each page has a frame latch. In this release the tree `write_latch` is an
exclusive global tree latch acquired by lookup, range, each cursor batch, insert,
and delete. Readers and writers are therefore serialized per tree operation;
per-frame latches protect bytes but do not supply concurrent reader traversal.
Outside PageStore's store mutex, a multi-batch direct cursor can release that
latch between batches. This deliberately conservative choice prevents a reader
from traversing a half-linked split or delete change until a B-link or
latch-coupled protocol is added.

B+Tree mutation is executed in ARSP P3 only after the transaction WAL record is
durable. Dirty pages carry that WAL LSN and cannot flush ahead of it. The
page-store applied-LSN catalog is written only after the affected node/heap
pages have flushed.

## Current limitations

Delete removes a leaf entry but does not yet merge underfull leaves, rebalance
internal nodes, shrink the root, or recycle pages. Empty leaves remain valid and
lookups/range scans stay correct. A future vacuum/rebuild can reclaim that space.

Ordinary incremental mutation currently decodes and re-encodes a node; a later
optimization can retain ordered slots and use binary search without changing the
on-disk format. A physical vacuum/rebuild is also needed before delete-heavy
workloads can reclaim B+Tree space.
