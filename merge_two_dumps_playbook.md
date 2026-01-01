# Merging Two Postgres Dumps into One DB (Public + Staging Workflow)

This doc captures the **repeatable workflow** we used to merge two PostgreSQL dumps that share the **same schema** into one target database, while:

- preserving natural-key uniqueness (no duplicate logical records),
- avoiding primary-key collisions,
- keeping foreign keys consistent,
- and repairing denormalized `package_indexes` arrays after the merge.

---

## Overview

You will:

1. **Restore dump #1 into `public`** (normal restore).
2. **Create a second schema `staging`** that contains empty clones of the public tables.
3. **Create a _data‑only_ dump for dump #2** (no schema/functions/constraints).
4. **Restore dump #2 into `staging`**.
5. **Merge staging into public** using `merge_staging_into_public.sql`.
6. **Repair denormalized `package_indexes` arrays** using `update_package_indexes_arr.sql`.

Why this works:
- We insert “true parents” in public by **natural keys** (e.g., `purl`, `name`, `identifier`) using `ON CONFLICT DO NOTHING`.
- We build **ID maps** from staging → public for those parents.
- We rewrite **staging foreign keys** to match public IDs before inserting children.
- For append-only historical tables whose PKs are meaningless across dumps (metrics + edit), we **generate fresh PKs**.

---

## 1) Create the Second Schema (`staging`) with Empty Tables

You want a schema that mirrors `public` **exactly**, but starts empty.

```sql
-- create schema
CREATE SCHEMA IF NOT EXISTS staging;

-- clone all tables (structure only)
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT tablename
    FROM pg_tables
    WHERE schemaname = 'public'
  LOOP
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS staging.%I (LIKE public.%I INCLUDING ALL);',
      r.tablename, r.tablename
    );
  END LOOP;
END $$;
```

**Notes**
- `INCLUDING ALL` copies columns, defaults, constraints, indexes, and identity/serial.
- No data is copied.
- If you have sequences owned by public tables, they remain owned there — that’s fine because staging is temporary.

---

## 2) Create a Data‑Only Dump for Dump #2 (and Why It Must Be Data‑Only)

### Why data-only?

If you restore a full dump into staging, it will include:

- `CREATE TABLE ...`
- `ALTER TABLE ADD CONSTRAINT ...`
- `CREATE FUNCTION ...`
- extensions, triggers, etc.

That causes errors like:

- “function already exists”
- “multiple primary keys not allowed”
- conflicting constraints

Because **staging already has the schema**, you **only want rows**.

### Command

From the machine where dump #2 DB is accessible:

```bash
pg_dump \
  -U <user> \
  -d <db_name> \
  --data-only \
  --column-inserts \
  --disable-triggers \
  --no-owner --no-privileges \
  > dump2_data_only.sql
```

**Flags explained**
- `--data-only`: no schema, no functions.
- `--column-inserts`: INSERTs with explicit column lists (stable across column order changes).
- `--disable-triggers`: makes restore more permissive (especially if constraints exist).
- `--no-owner --no-privileges`: avoids role/permission noise on restore.

> If your original dump is already SQL, you can also generate a data‑only variant by re‑dumping from the source DB. Editing a full SQL dump to remove schema bits is fragile.

---

## 3) Restore Dump #2 into Staging

Assuming `dump2_data_only.sql` is on your host:

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f dump2_data_only.sql
```

But you need rows to land in `staging`, not `public`.

### Option A: Set search_path before restore (best)

Create a wrapper file:

```bash
cat > restore_dump2_to_staging.sql <<'SQL'
SET search_path = staging, public;
\i dump2_data_only.sql
SQL
```

Then restore:

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f restore_dump2_to_staging.sql
```

### Option B: Rewrite COPY targets (only if your dump uses COPY)

If the dump uses `COPY public.table ...`, you can rewrite:

```bash
sed 's/COPY public\./COPY staging\./g' dump2_data_only.sql > dump2_staging.sql
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f dump2_staging.sql
```

You inspected your dump and confirmed it uses `COPY public...`, so either wrapper or sed works.

---

## 4) Merge Staging into Public

Run the merge script (the large one that:
- merges parents by natural key,
- builds maps,
- remaps staging FKs,
- inserts children,
- generates new ids for append-only tables,
- bumps sequences before inserts,
- resets sequences at end).

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f merge_staging_into_public.sql
```

### What the merge script does (conceptually)

1. **Insert parents by natural key**
   - `dataset` by `name`
   - `datasource` by `purl`
   - `package` by `purl`
   - `finding` by `identifier`
   - `finding_reporter` by `name`
   - `ON CONFLICT DO NOTHING` ensures duplicates don’t get created.

2. **Build id maps**
   - `map_dataset(staging_id → public_id)`
   - `map_datasource(...)`
   - etc.

3. **Rewrite staging foreign keys**
   - e.g., staging `datasource_event.datasource_id` becomes public `datasource.id`.
   - all join tables updated similarly.

4. **Insert children in dependency order**
   - first `datasource_event` (after its FK is remapped),
   - then join tables referencing it.

5. **Append-only historical tables get fresh ids**
   - `dataset_metrics`
   - `datasource_metrics`
   - `edit`
   - These tables represent time-series snapshots. Their PKs are meaningless across environments and collide easily, so:
     - we bump the sequence to `MAX(id)+1`,
     - then insert using `nextval(...)` to force new PKs.

6. **Reset all sequences**
   - ensures future inserts won’t collide.

---

## 5) Repair `package_indexes` Arrays (Second Script)

### Why this is required

You confirmed:
- `dataset_metrics.package_indexes` is a `bigint[]` of **package IDs at time of snapshot**
- `datasource.package_indexes` is also a `bigint[]`

During merge:
- some staging packages map to **existing public packages** (same `purl`) → keep old public IDs
- staging-only packages become **new public rows with new IDs**

Therefore, any staging snapshot arrays still contain **staging package ids**, which are now wrong.

### Fix script

Run after merge:

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f update_package_indexes_arr.sql
```

#### What it does

1. Builds `map_package` by natural key:

   `staging.package.id → public.package.id` using `purl`.

2. Fixes only merged-in metrics rows:

   Uses staging `txid` set to identify which `dataset_metrics` rows came from dump #2.

3. Fixes `public.datasource.package_indexes`:

   Correlated update rewrites arrays wherever they still contain staging IDs.

### Sanity check after the fix

```sql
SELECT count(*) AS bad_dataset_metrics_rows
FROM public.dataset_metrics dm
WHERE dm.package_indexes IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM unnest(dm.package_indexes) AS x
    LEFT JOIN public.package p ON p.id = x
    WHERE p.id IS NULL
  );
```

Expect **0**.

---

## Full Workflow (Copy/Paste)

```bash
# 0) restore dump1 normally into public
psql -U mr_data mrs_db -f dump1.sql

# 1) create staging schema + empty clones
psql -U mr_data mrs_db -f create_staging_schema.sql

# 2) create data-only dump2 (from source DB)
pg_dump -U <user> -d <db2> --data-only --column-inserts --disable-triggers \
  --no-owner --no-privileges > dump2_data_only.sql

# 3) restore dump2 into staging
cat > restore_dump2_to_staging.sql <<'SQL'
SET search_path = staging, public;
\i dump2_data_only.sql
SQL
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f restore_dump2_to_staging.sql

# 4) merge staging into public
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f merge_staging_into_public.sql

# 5) repair denormalized arrays
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f update_package_indexes_arr.sql
```

---

## Gotchas / Notes

- If another table throws `*_pkey` on insert, it likely needs the same pattern:
  - bump its sequence before insert
  - insert with `nextval()` in the SELECT

- Natural key assumptions must hold:
  - `package.purl` unique
  - `dataset.name` unique
  - `datasource.purl` unique
  - `finding.identifier` unique
  - etc.

If any of those are violated across dumps, those rows will be skipped in favor of existing public rows by design.

---

That’s the whole playbook.
