BEGIN;

CREATE TEMP TABLE map_package AS
SELECT s.id AS staging_id,
       p.id AS public_id
FROM staging.package s
JOIN public.package p USING (purl);

CREATE TEMP TABLE staging_txids AS
SELECT DISTINCT txid FROM staging.dataset_metrics;

-- Fix public.dataset_metrics.package_indexes for rows coming from staging
WITH to_fix AS (
  SELECT dm.id, dm.package_indexes
  FROM public.dataset_metrics dm
  JOIN staging_txids st USING (txid)
  WHERE dm.package_indexes IS NOT NULL
)
UPDATE public.dataset_metrics dm
SET package_indexes = sub.new_indexes
FROM to_fix f,
LATERAL (
  SELECT COALESCE(
           array_agg(COALESCE(mp.public_id, x) ORDER BY ord),
           '{}'::bigint[]
         ) AS new_indexes
  FROM unnest(f.package_indexes) WITH ORDINALITY AS u(x, ord)
  LEFT JOIN map_package mp ON mp.staging_id = x
) sub
WHERE dm.id = f.id;

-- Fix public.datasource.package_indexes
-- Correlated subquery in SET (no FROM scoping issues)
UPDATE public.datasource d
SET package_indexes = (
  SELECT COALESCE(
           array_agg(COALESCE(mp.public_id, x) ORDER BY ord),
           '{}'::bigint[]
         )
  FROM unnest(d.package_indexes) WITH ORDINALITY AS u(x, ord)
  LEFT JOIN map_package mp ON mp.staging_id = x
)
WHERE d.package_indexes IS NOT NULL
  AND EXISTS (
    SELECT 1
    FROM unnest(d.package_indexes) AS x
    JOIN map_package mp ON mp.staging_id = x
  );

COMMIT;
