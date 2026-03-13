# 032_relfilenode_reuse.pl — TDE Failure Analysis

## Test Overview

`032_relfilenode_reuse.pl` sets `full_page_writes=off` and `shared_buffers=1MB`, creates a
primary+standby pair with streaming replication, and exercises two scenarios that cause the same
relfilenode number to be reused for a new relation. A long-running transaction (`BEGIN` with no
commit) is held open in a separate session connected to the `postgres` database throughout the
test. The combination of `full_page_writes=off` and the long-running transaction is what triggers
both bugs.

---

## Bug 1: Stale TDE Key Cache After DROP+Recreate

### Root Cause

`TDESMgrRelation` (the TDE-extended `SMgrRelation`) caches the relation's encryption key in
`relKey` once it is loaded from the key map file, and tracks its state via `encryption_status`
(`RELATION_KEY_NOT_AVAILABLE` → `RELATION_KEY_AVAILABLE`). The struct is kept in a backend-local
hash table and is reused if the same `RelFileLocator` is opened again.

PostgreSQL normally destroys SMgrRelation structs at transaction end via `AtEOXact_SMgr` →
`smgrdestroy`. However, a backend in a long-running `BEGIN` block never reaches transaction end,
so its SMgrRelation structs — including `TDESMgrRelation` with the cached key — persist
indefinitely.

When another backend drops and recreates a relation (`conflict_db` is dropped and recreated with
the same OID), the following sequence happens:

1. `smgrdounlinkall` is called for the old relation. This calls `CacheInvalidateSmgr`, which
   sends a shared-invalidation message.
2. The long-running-transaction backend processes the barrier via `ProcessBarrierSmgrRelease` →
   `smgrreleaseall` → `smgrrelease` → `smgr_close` (= `mdclose`). This closes the VFD but
   **does not reset the TDE key cache** — `encryption_status` remains `RELATION_KEY_AVAILABLE`
   and `relKey` still holds the old key K1.
3. A new key K2 is written to the key map for the newly created relation with the same
   `RelFileLocator`.
4. `with_connections` (a helper in the test) calls `cause_eviction` in the long-running session,
   which triggers `pg_prewarm` on `large`. This evicts dirty shared buffers, which are written
   back via the long-running session's `SMgrRelation` — encrypted with the stale key K1.
5. New sessions read those pages and attempt to decrypt with K2 → checksum mismatch →
   **"invalid page in block N"**.

### Fix

Implement `tde_mdclose()` in `src/smgr/pg_tde_smgr.c` as the `smgr_close` callback instead of
the plain `mdclose`. After calling `mdclose`, reset `encryption_status` to
`RELATION_KEY_NOT_AVAILABLE` for the main fork so the key is reloaded from the key map on the
next I/O:

```c
static void
tde_mdclose(SMgrRelation reln, ForkNumber forknum)
{
    TDESMgrRelation *tdereln = (TDESMgrRelation *) reln;

    mdclose(reln, forknum);

    if (forknum == MAIN_FORKNUM &&
        tdereln->encryption_status == RELATION_KEY_AVAILABLE)
        tdereln->encryption_status = RELATION_KEY_NOT_AVAILABLE;
}
```

Register it in the smgr table: `.smgr_close = tde_mdclose`.

---

## Bug 2: Missing Key After ALTER DATABASE SET TABLESPACE

### Root Cause

`ALTER DATABASE SET TABLESPACE` is implemented in `dbcommands.c:movedb()`. It copies the entire
database directory using `copydir()` — a raw byte-level file copy. The smgr API is not involved;
there is no `smgropen`, no `smgrwrite`, no TDE layer. The encrypted bytes are copied verbatim to
the new tablespace directory.

The TDE key map file is stored per-database (`{dbOid}_keys`) and holds entries keyed on
`(spcOid, relNumber)`. After `copydir()` moves files from tablespace A (`spcOid=X`) to
tablespace B (`spcOid=Y`), the on-disk files are in the new location, but the key map still
contains entries with the original `spcOid=X`.

When a backend subsequently opens a relation in the moved database, `tde_mdopen` calls
`pg_tde_has_smgr_key` with the new `RelFileLocator` (`spcOid=Y, relNumber=R`). The lookup in
`pg_tde_find_map_entry` compares both `spcOid` and `relNumber`, so it finds no matching entry
and concludes the relation is unencrypted (`RELATION_NOT_ENCRYPTED`). The encrypted bytes on disk
are then read without decryption → "invalid page in block 0".

In the test, this is triggered by the third tablespace move (database moved back to
`test_tablespace`, `spcOid=16409`). The relation was created when the database was in
`pg_default` (`spcOid=0`), so the key map entry has `spcOid=0`. After the move the lookup uses
`spcOid=16409` and fails.

### Why Removing spcOid From Lookups Is Safe

Within a single database, `RelFileNumber` (relfilenode OID) is unique regardless of tablespace.
A relation lives in exactly one tablespace at a time, and the database directory layout ensures
no two relations in the same database share a relfilenode, even across tablespaces. Therefore
`relNumber` alone is sufficient to identify a key map entry.

The `spcOid` field is stored inside `TDEMapEntry` and is part of the AES-GCM Additional
Authenticated Data (AAD) used when encrypting the entry itself. AAD is derived from the stored
entry's own bytes, not from the caller's `rlocator`. So decryption of the entry is unaffected by
the caller passing a different `spcOid` — the stored `spcOid` in the entry is the one used for
AAD, and it has not changed.

### Fix

Remove `spcOid` from the equality comparisons in the three key map lookup functions in
`src/access/pg_tde_tdemap.c`:

- `pg_tde_free_key_map_entry` (~line 218)
- `pg_tde_replace_key_map_entry` (~line 474)
- `pg_tde_find_map_entry` (~line 512)

Before:
```c
map_entry.type == MAP_ENTRY_TYPE_KEY &&
map_entry.spcOid == rlocator.spcOid &&
map_entry.relNumber == rlocator.relNumber
```

After:
```c
map_entry.type == MAP_ENTRY_TYPE_KEY &&
map_entry.relNumber == rlocator.relNumber
```

---

## Result

After both fixes, `t/032_relfilenode_reuse.pl` passes all 14 subtests cleanly.
