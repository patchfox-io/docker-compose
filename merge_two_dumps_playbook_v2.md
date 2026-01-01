# Merging Two Postgres Dumps into One DB (Public + Staging Workflow)

This playbook describes a repeatable way to merge **two PostgreSQL dumps that share the same schema** into one target database, while:

- preserving natural‑key uniqueness (no duplicate logical records),
- avoiding primary‑key collisions,
- keeping foreign keys consistent,
- and repairing denormalized `package_indexes` arrays after the merge.

---

## Overview

You will:

1. Restore dump **#1** into `public` (normal restore).
2. Create a second schema `staging` containing empty clones of the public tables.
3. Create a **data‑only** dump for dump **#2**.
4. Restore dump #2 into `staging`.
5. Merge staging into public via `merge_staging_into_public.sql`.
6. Repair `package_indexes` arrays via `update_package_indexes_arr.sql`.
7. Verify correctness via `verify_package_indexes.sql`.

Why this works:
- We insert “true parents” in public by **natural keys** (e.g., `purl`, `name`, `identifier`) using `ON CONFLICT DO NOTHING`.
- We build **ID maps** from staging → public for those parents.
- We rewrite **staging foreign keys** to match public IDs before inserting children.
- For append‑only historical tables whose PKs are meaningless across dumps (metrics + edit), we **generate fresh PKs**.

---

## 1) Create the Second Schema (`staging`) with Empty Tables

Create a schema that mirrors `public` exactly, but contains no data:

```sql
CREATE SCHEMA IF NOT EXISTS staging;

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

Notes:
- `INCLUDING ALL` copies columns, defaults, constraints, indexes, and identity/serial.
- No data is copied.
- Staging is temporary; it’s ok that sequences are still owned by public.

---

## 2) Create a Data‑Only Dump for Dump #2 (and Why It Must Be Data‑Only)

### Why data‑only?

A full dump includes schema objects (`CREATE TABLE`, `ALTER TABLE`, functions, triggers, extensions).  
Restoring a full dump into staging causes errors like:

- “function already exists”
- “multiple primary keys not allowed”
- constraint redefinition conflicts

Because the staging schema already exists, dump #2 must be **rows only**.

### Command

From the dump‑#2 source DB:

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

Flag meanings:
- `--data-only`: no schema.
- `--column-inserts`: stable explicit column lists.
- `--disable-triggers`: avoids trigger/constraint surprises on load.
- `--no-owner --no-privileges`: avoids role noise.

---

## 3) Restore Dump #2 into Staging

You need rows to land in `staging`, not `public`.

### Preferred: set search_path wrapper

```bash
cat > restore_dump2_to_staging.sql <<'SQL'
SET search_path = staging, public;
\i dump2_data_only.sql
SQL

psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f restore_dump2_to_staging.sql
```

### Alternative: rewrite COPY targets (only if your dump uses COPY)

```bash
sed 's/COPY public\./COPY staging\./g' dump2_data_only.sql > dump2_staging.sql
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f dump2_staging.sql
```

---

## 4) Merge Staging into Public

Run the merge script:

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f merge_staging_into_public.sql
```

### What the merge script does

1. **Insert parents by natural key** with `ON CONFLICT DO NOTHING`:
   - `dataset` by `name`
   - `datasource` by `purl`
   - `package` by `purl`
   - `finding` by `identifier`
   - `finding_reporter` by `name`

2. **Build staging→public id maps** (by those same natural keys).

3. **Rewrite staging foreign keys** using the maps.

4. **Insert children in dependency order** (e.g., events before event‑join tables).

5. **Append‑only historical tables get fresh ids**
   - `dataset_metrics`
   - `datasource_metrics`
   - `edit`

   For these:
   - bump sequence to `MAX(id)+1`
   - insert with `nextval(...)` so ids never collide.

6. **Reset sequences** at the end for future inserts.

---

## 5) Repair `package_indexes` Arrays (Second Script)

### Why this is required

You confirmed:
- `dataset_metrics.package_indexes` is a `bigint[]` of **package ids at snapshot time**
- `datasource.package_indexes` is also a `bigint[]`

During merge:
- some staging packages map to existing public rows (same `purl`) → keep old ids
- staging‑only packages become new public rows → **new ids**

So staging snapshots still contain staging package ids and must be remapped.

### Fix script

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f update_package_indexes_arr.sql
```

What it does:
1. build `map_package` by `purl` (staging_id → public_id)
2. rewrite `public.dataset_metrics.package_indexes` for rows imported from staging (detected by shared `txid`)
3. rewrite `public.datasource.package_indexes` wherever staging ids are still present

---

## 6) Verify the `package_indexes` Handling (Integrity Check)

After running the repair script, validate two things:

1. **Public‑only datasource arrays were not harmed**  
   Every id in pre‑existing public arrays still resolves to a real public package.

2. **Staging‑imported arrays now point at the same logical packages**  
   The **package purl arrays match position‑by‑position** between staging and public for:
   - `dataset_metrics.package_indexes`
   - `datasource.package_indexes` (for overlapping datasources)

Run:

```bash
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f verify_package_indexes.sql
```

Good output looks like:

- `public_only_datasource_arrays_with_missing_public_packages = 0`
- 0 rows returned for datasource purl comparisons
- 0 rows returned for dataset_metrics purl comparisons

Example:

```
public_only_datasource_arrays_with_missing_public_packages
---------------------------------------------------------
0

datasource_purl | staging_purls | public_purls
---------------+---------------+-------------
(0 rows)
```

If any count is non‑zero or rows return, rerun the repair script and re‑verify.

---

## Full Workflow (Copy/Paste)

```bash
# 0) Restore dump1 into public
psql -U mr_data mrs_db -f dump1.sql

# 1) Create staging schema + empty clones
psql -U mr_data mrs_db -f create_staging_schema.sql

# 2) Create data‑only dump2 (from source DB)
pg_dump -U <user> -d <db2> --data-only --column-inserts --disable-triggers \
  --no-owner --no-privileges > dump2_data_only.sql

# 3) Restore dump2 into staging
cat > restore_dump2_to_staging.sql <<'SQL'
SET search_path = staging, public;
\i dump2_data_only.sql
SQL
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f restore_dump2_to_staging.sql

# 4) Merge staging into public
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f merge_staging_into_public.sql

# 5) Repair denormalized arrays
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f update_package_indexes_arr.sql

# 6) Verify arrays are correct + public untouched
psql -U mr_data mrs_db -v ON_ERROR_STOP=on -f verify_package_indexes.sql
```

---

## Gotchas / Notes

- If another table throws `*_pkey` on insert, apply the same pattern:
  - bump its sequence first
  - insert with `nextval(...)` for fresh ids

- Natural keys must be truly unique across dumps:
  - `package.purl`
  - `dataset.name`
  - `datasource.purl`
  - `finding.identifier`
  - `finding_reporter.name`

If those aren’t unique, duplicates will be skipped in favor of existing public rows by design.

---

That’s the playbook.
