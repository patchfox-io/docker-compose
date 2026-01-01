-- ============================================================
-- verify_package_indexes.sql  (UPDATED)
--
-- Purpose:
--   1) Confirm pre-existing public.package_indexes arrays remain valid
--      (i.e., every referenced id resolves to a public.package row).
--      This avoids false positives caused by overlapping id ranges
--      between dump1 and dump2.
--   2) Confirm remapped package_indexes for rows imported from staging
--      now point to public.package rows whose purls match the staging
--      package_indexes purls (position-by-position).
--
-- Assumptions:
--   - package natural key = purl (unique in both schemas).
--   - dataset_metrics imported from staging share txid values with staging.
--   - datasource exists in both schemas when purl matches.
--
-- Output:
--   Each section returns 0 rows / 0 count when everything is correct.
-- ============================================================

BEGIN;

-- ============================================================
-- A) Build staging_id -> public_id map for packages (by purl)
-- ============================================================
CREATE TEMP TABLE map_package AS
SELECT s.id AS staging_id,
       p.id AS public_id,
       p.purl AS purl
FROM staging.package s
JOIN public.package p USING (purl);

-- ============================================================
-- 1) Public-only datasource.package_indexes were not harmed:
--    Every id in public-only datasource arrays must resolve to a
--    real public.package.id.
--
--    We restrict to "public-only" datasources (not present in staging)
--    to isolate pre-existing data from merge side-effects.
-- ============================================================

WITH public_only AS (
  SELECT d.*
  FROM public.datasource d
  LEFT JOIN staging.datasource s USING (purl)
  WHERE s.purl IS NULL
)
SELECT count(*) AS public_only_datasource_arrays_with_missing_public_packages
FROM public_only d
WHERE d.package_indexes IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM unnest(d.package_indexes) AS x
    LEFT JOIN public.package p ON p.id = x
    WHERE p.id IS NULL
  );

-- Expect 0.

-- ============================================================
-- 2) dataset_metrics imported from staging:
--    public.package_indexes purls == staging.package_indexes purls (same order)
-- ============================================================

WITH staging_txids AS (
  SELECT DISTINCT txid FROM staging.dataset_metrics
),
pairs AS (
  SELECT
    s.id  AS staging_dm_id,
    p.id  AS public_dm_id,
    s.txid,
    s.package_indexes AS staging_pkg_ids,
    p.package_indexes AS public_pkg_ids
  FROM staging.dataset_metrics s
  JOIN public.dataset_metrics p USING (txid)
  JOIN staging_txids st USING (txid)
  WHERE s.package_indexes IS NOT NULL
    AND p.package_indexes IS NOT NULL
),
staging_purls AS (
  SELECT
    public_dm_id,
    array_agg(sp.purl ORDER BY u.ord) AS staging_purls
  FROM pairs pr
  JOIN LATERAL unnest(pr.staging_pkg_ids) WITH ORDINALITY AS u(pkg_id, ord) ON TRUE
  JOIN staging.package sp ON sp.id = u.pkg_id
  GROUP BY public_dm_id
),
public_purls AS (
  SELECT
    public_dm_id,
    array_agg(pp.purl ORDER BY u.ord) AS public_purls
  FROM pairs pr
  JOIN LATERAL unnest(pr.public_pkg_ids) WITH ORDINALITY AS u(pkg_id, ord) ON TRUE
  JOIN public.package pp ON pp.id = u.pkg_id
  GROUP BY public_dm_id
)
SELECT
  pr.public_dm_id,
  pr.staging_dm_id,
  pr.txid,
  sp.staging_purls,
  pp.public_purls
FROM pairs pr
JOIN staging_purls sp USING (public_dm_id)
JOIN public_purls  pp USING (public_dm_id)
WHERE sp.staging_purls IS DISTINCT FROM pp.public_purls;

-- Expect 0 rows.

-- ============================================================
-- 3) datasource.package_indexes for overlapping datasources:
--    public purls == staging purls (same order), for same datasource purl
-- ============================================================

WITH pairs AS (
  SELECT
    s.purl AS datasource_purl,
    s.package_indexes AS staging_pkg_ids,
    p.package_indexes AS public_pkg_ids
  FROM staging.datasource s
  JOIN public.datasource p USING (purl)
  WHERE s.package_indexes IS NOT NULL
    AND p.package_indexes IS NOT NULL
),
staging_purls AS (
  SELECT
    datasource_purl,
    array_agg(sp.purl ORDER BY u.ord) AS staging_purls
  FROM pairs pr
  JOIN LATERAL unnest(pr.staging_pkg_ids) WITH ORDINALITY AS u(pkg_id, ord) ON TRUE
  JOIN staging.package sp ON sp.id = u.pkg_id
  GROUP BY datasource_purl
),
public_purls AS (
  SELECT
    datasource_purl,
    array_agg(pp.purl ORDER BY u.ord) AS public_purls
  FROM pairs pr
  JOIN LATERAL unnest(pr.public_pkg_ids) WITH ORDINALITY AS u(pkg_id, ord) ON TRUE
  JOIN public.package pp ON pp.id = u.pkg_id
  GROUP BY datasource_purl
)
SELECT
  pr.datasource_purl,
  sp.staging_purls,
  pp.public_purls
FROM pairs pr
JOIN staging_purls sp USING (datasource_purl)
JOIN public_purls  pp USING (datasource_purl)
WHERE sp.staging_purls IS DISTINCT FROM pp.public_purls;

-- Expect 0 rows.

COMMIT;
