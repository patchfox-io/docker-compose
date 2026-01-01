BEGIN;
SET session_replication_role = 'replica';
SET CONSTRAINTS ALL DEFERRED;

-- ============================================================
-- 1) MERGE TRUE PARENTS (natural keys), omit id
-- ============================================================

-- dataset (unique: name, latest_txid)
INSERT INTO public.dataset (latest_job_id, latest_txid, name, status, updated_at)
SELECT latest_job_id, latest_txid, name, status, updated_at
FROM staging.dataset
ON CONFLICT DO NOTHING;

-- datasource (unique: purl, latest_txid)
INSERT INTO public.datasource (
  commit_branch, domain, first_event_received_at, last_event_received_at,
  last_event_received_status, latest_job_id, latest_txid, name,
  number_event_processing_errors, number_events_received, package_indexes,
  purl, status, type
)
SELECT
  commit_branch, domain, first_event_received_at, last_event_received_at,
  last_event_received_status, latest_job_id, latest_txid, name,
  number_event_processing_errors, number_events_received, package_indexes,
  purl, status, type
FROM staging.datasource
ON CONFLICT DO NOTHING;

-- package (unique: purl)
INSERT INTO public.package (
  most_recent_version, most_recent_version_published_at, name, namespace,
  number_major_versions_behind_head, number_minor_versions_behind_head,
  number_patch_versions_behind_head, number_versions_behind_head,
  purl, this_version_published_at, type, updated_at, version
)
SELECT
  most_recent_version, most_recent_version_published_at, name, namespace,
  number_major_versions_behind_head, number_minor_versions_behind_head,
  number_patch_versions_behind_head, number_versions_behind_head,
  purl, this_version_published_at, type, updated_at, version
FROM staging.package
ON CONFLICT DO NOTHING;

-- finding (unique: identifier)
INSERT INTO public.finding (identifier)
SELECT identifier
FROM staging.finding
ON CONFLICT DO NOTHING;

-- finding_reporter (unique: name)
INSERT INTO public.finding_reporter (name)
SELECT name
FROM staging.finding_reporter
ON CONFLICT DO NOTHING;


-- ============================================================
-- 2) BUILD MAPS FOR PARENTS (staging_id -> public_id)
-- ============================================================

CREATE TEMP TABLE map_dataset AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.dataset s
JOIN public.dataset p USING (name);

CREATE TEMP TABLE map_datasource AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.datasource s
JOIN public.datasource p USING (purl);

CREATE TEMP TABLE map_package AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.package s
JOIN public.package p USING (purl);

CREATE TEMP TABLE map_finding AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.finding s
JOIN public.finding p USING (identifier);

CREATE TEMP TABLE map_reporter AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.finding_reporter s
JOIN public.finding_reporter p USING (name);


-- ============================================================
-- 3) REMAP STAGING FKs
-- ============================================================

-- datasource_event.datasource_id -> datasource.id
UPDATE staging.datasource_event se
SET datasource_id = md.public_id
FROM map_datasource md
WHERE se.datasource_id = md.staging_id;

-- dataset_metrics.dataset_id -> dataset.id
UPDATE staging.dataset_metrics dm
SET dataset_id = mds.public_id
FROM map_dataset mds
WHERE dm.dataset_id = mds.staging_id;

-- edit.datasource_id -> datasource.id
UPDATE staging.edit e
SET datasource_id = md.public_id
FROM map_datasource md
WHERE e.datasource_id = md.staging_id;

-- finding_data.finding_id -> finding.id
UPDATE staging.finding_data fd
SET finding_id = mf.public_id
FROM map_finding mf
WHERE fd.finding_id = mf.staging_id;

-- join tables
UPDATE staging.datasource_dataset dd
SET datasource_id = md.public_id
FROM map_datasource md
WHERE dd.datasource_id = md.staging_id;

UPDATE staging.datasource_dataset dd
SET dataset_id = mds.public_id
FROM map_dataset mds
WHERE dd.dataset_id = mds.staging_id;

UPDATE staging.package_finding pf
SET package_id = mp.public_id
FROM map_package mp
WHERE pf.package_id = mp.staging_id;
UPDATE staging.package_finding pf
SET finding_id = mf.public_id
FROM map_finding mf
WHERE pf.finding_id = mf.staging_id;

UPDATE staging.package_critical_finding pcf
SET package_id = mp.public_id
FROM map_package mp
WHERE pcf.package_id = mp.staging_id;
UPDATE staging.package_critical_finding pcf
SET finding_id = mf.public_id
FROM map_finding mf
WHERE pcf.finding_id = mf.staging_id;

UPDATE staging.package_high_finding phf
SET package_id = mp.public_id
FROM map_package mp
WHERE phf.package_id = mp.staging_id;
UPDATE staging.package_high_finding phf
SET finding_id = mf.public_id
FROM map_finding mf
WHERE phf.finding_id = mf.staging_id;

UPDATE staging.package_medium_finding pmf
SET package_id = mp.public_id
FROM map_package mp
WHERE pmf.package_id = mp.staging_id;
UPDATE staging.package_medium_finding pmf
SET finding_id = mf.public_id
FROM map_finding mf
WHERE pmf.finding_id = mf.staging_id;

UPDATE staging.package_low_finding plf
SET package_id = mp.public_id
FROM map_package mp
WHERE plf.package_id = mp.staging_id;
UPDATE staging.package_low_finding plf
SET finding_id = mf.public_id
FROM map_finding mf
WHERE plf.finding_id = mf.staging_id;

UPDATE staging.finding_to_reporter ftr
SET finding_id = mf.public_id
FROM map_finding mf
WHERE ftr.finding_id = mf.staging_id;
UPDATE staging.finding_to_reporter ftr
SET reporter_id = mr.public_id
FROM map_reporter mr
WHERE ftr.reporter_id = mr.staging_id;


-- ============================================================
-- 4) INSERT datasource_event + remap its join table
-- ============================================================

INSERT INTO public.datasource_event (
  analyzed, commit_branch, commit_date_time, commit_hash, event_date_time,
  forecasted, job_id, oss_enriched, package_index_enriched, payload,
  processing_error, purl, recommended, status, txid, datasource_id
)
SELECT
  analyzed, commit_branch, commit_date_time, commit_hash, event_date_time,
  forecasted, job_id, oss_enriched, package_index_enriched, payload,
  processing_error, purl, recommended, status, txid, datasource_id
FROM staging.datasource_event
ON CONFLICT DO NOTHING;

CREATE TEMP TABLE map_dse AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.datasource_event s
JOIN public.datasource_event p USING (txid);

UPDATE staging.datasource_event_package dep
SET datasource_event_id = mdse.public_id
FROM map_dse mdse
WHERE dep.datasource_event_id = mdse.staging_id;

UPDATE staging.datasource_event_package dep
SET package_id = mp.public_id
FROM map_package mp
WHERE dep.package_id = mp.staging_id;


-- ============================================================
-- 5) BUMP SEQUENCES FOR APPEND-ONLY TABLES BEFORE INSERT
-- ============================================================

SELECT setval(
  pg_get_serial_sequence('public.dataset_metrics','id'),
  COALESCE((SELECT MAX(id) FROM public.dataset_metrics), 0) + 1,
  false
);

SELECT setval(
  pg_get_serial_sequence('public.datasource_metrics','id'),
  COALESCE((SELECT MAX(id) FROM public.datasource_metrics), 0) + 1,
  false
);

SELECT setval(
  pg_get_serial_sequence('public.edit','id'),
  COALESCE((SELECT MAX(id) FROM public.edit), 0) + 1,
  false
);


-- ============================================================
-- 6) INSERT dataset_metrics (historical, generate fresh ids)
-- ============================================================

INSERT INTO public.dataset_metrics (
  id,
  commit_date_time, critical_findings,
  critical_findings_avoided_by_patching_past_year,
  critical_findings_in_backlog_between_sixty_and_ninety_days,
  critical_findings_in_backlog_between_thirty_and_sixty_days,
  critical_findings_in_backlog_over_ninety_days,
  datasource_count, datasource_event_count, different_patches,
  downlevel_packages, downlevel_packages_major, downlevel_packages_minor,
  downlevel_packages_patch, event_date_time,
  findings_avoided_by_patching_past_year,
  findings_in_backlog_between_sixty_and_ninety_days,
  findings_in_backlog_between_thirty_and_sixty_days,
  findings_in_backlog_over_ninety_days,
  forecast_maturity_date, high_findings,
  high_findings_avoided_by_patching_past_year,
  high_findings_in_backlog_between_sixty_and_ninety_days,
  high_findings_in_backlog_between_thirty_and_sixty_days,
  high_findings_in_backlog_over_ninety_days,
  is_current, is_forecast_recommendations_taken, is_forecast_same_course,
  job_id, low_findings,
  low_findings_avoided_by_patching_past_year,
  low_findings_in_backlog_between_sixty_and_ninety_days,
  low_findings_in_backlog_between_thirty_and_sixty_days,
  low_findings_in_backlog_over_ninety_days,
  medium_findings,
  medium_findings_avoided_by_patching_past_year,
  medium_findings_in_backlog_between_sixty_and_ninety_days,
  medium_findings_in_backlog_between_thirty_and_sixty_days,
  medium_findings_in_backlog_over_ninety_days,
  package_indexes, packages, packages_with_critical_findings,
  packages_with_findings, packages_with_high_findings,
  packages_with_low_findings, packages_with_medium_findings,
  patch_efficacy_score, patch_effort, patch_fox_patches,
  patch_impact, patches, recommendation_headline,
  recommendation_type, rps_score, same_patches, stale_packages,
  stale_packages_one_year, stale_packages_one_year_six_months,
  stale_packages_six_months, stale_packages_two_years,
  total_findings, txid, dataset_id
)
SELECT
  nextval(pg_get_serial_sequence('public.dataset_metrics','id')),
  commit_date_time, critical_findings,
  critical_findings_avoided_by_patching_past_year,
  critical_findings_in_backlog_between_sixty_and_ninety_days,
  critical_findings_in_backlog_between_thirty_and_sixty_days,
  critical_findings_in_backlog_over_ninety_days,
  datasource_count, datasource_event_count, different_patches,
  downlevel_packages, downlevel_packages_major, downlevel_packages_minor,
  downlevel_packages_patch, event_date_time,
  findings_avoided_by_patching_past_year,
  findings_in_backlog_between_sixty_and_ninety_days,
  findings_in_backlog_between_thirty_and_sixty_days,
  findings_in_backlog_over_ninety_days,
  forecast_maturity_date, high_findings,
  high_findings_avoided_by_patching_past_year,
  high_findings_in_backlog_between_sixty_and_ninety_days,
  high_findings_in_backlog_between_thirty_and_sixty_days,
  high_findings_in_backlog_over_ninety_days,
  is_current, is_forecast_recommendations_taken, is_forecast_same_course,
  job_id, low_findings,
  low_findings_avoided_by_patching_past_year,
  low_findings_in_backlog_between_sixty_and_ninety_days,
  low_findings_in_backlog_between_thirty_and_sixty_days,
  low_findings_in_backlog_over_ninety_days,
  medium_findings,
  medium_findings_avoided_by_patching_past_year,
  medium_findings_in_backlog_between_sixty_and_ninety_days,
  medium_findings_in_backlog_between_thirty_and_sixty_days,
  medium_findings_in_backlog_over_ninety_days,
  package_indexes, packages, packages_with_critical_findings,
  packages_with_findings, packages_with_high_findings,
  packages_with_low_findings, packages_with_medium_findings,
  patch_efficacy_score, patch_effort, patch_fox_patches,
  patch_impact, patches, recommendation_headline,
  recommendation_type, rps_score, same_patches, stale_packages,
  stale_packages_one_year, stale_packages_one_year_six_months,
  stale_packages_six_months, stale_packages_two_years,
  total_findings, txid, dataset_id
FROM staging.dataset_metrics;

CREATE TEMP TABLE map_dsm AS
SELECT s.id AS staging_id, p.id AS public_id
FROM staging.dataset_metrics s
JOIN public.dataset_metrics p
  ON p.dataset_id = s.dataset_id
 AND p.commit_date_time = s.commit_date_time
 AND p.txid = s.txid;

UPDATE staging.edit e
SET dataset_metrics_id = mdsm.public_id
FROM map_dsm mdsm
WHERE e.dataset_metrics_id = mdsm.staging_id;

UPDATE staging.package_family pf
SET dataset_metrics_id = mdsm.public_id
FROM map_dsm mdsm
WHERE pf.dataset_metrics_id = mdsm.staging_id;


-- ============================================================
-- 7) INSERT remaining children / metrics / joins
-- ============================================================

INSERT INTO public.finding_data (
  cpes, description, identifier, patched_in,
  published_at, reported_at, severity, finding_id
)
SELECT
  cpes, description, identifier, patched_in,
  published_at, reported_at, severity, finding_id
FROM staging.finding_data
ON CONFLICT DO NOTHING;

INSERT INTO public.edit (
  id,
  after, avoids_vulnerabilities_rank, before, commit_date_time,
  critical_findings, decrease_backlog_rank, decrease_vulnerability_count_rank,
  edit_type, event_date_time, grow_patch_efficacy_index, high_findings,
  increase_impact_rank, is_pf_recommended_edit, is_same_edit, is_user_edit,
  low_findings, medium_findings, reduce_cve_backlog_growth_index,
  reduce_cve_backlog_index, reduce_cve_growth_index, reduce_cves_index,
  reduce_downlevel_packages_growth_index, reduce_downlevel_packages_index,
  reduce_stale_packages_growth_index, reduce_stale_packages_index,
  remove_redundant_packages_index, same_edit_count,
  dataset_metrics_id, datasource_id
)
SELECT
  nextval(pg_get_serial_sequence('public.edit','id')),
  after, avoids_vulnerabilities_rank, before, commit_date_time,
  critical_findings, decrease_backlog_rank, decrease_vulnerability_count_rank,
  edit_type, event_date_time, grow_patch_efficacy_index, high_findings,
  increase_impact_rank, is_pf_recommended_edit, is_same_edit, is_user_edit,
  low_findings, medium_findings, reduce_cve_backlog_growth_index,
  reduce_cve_backlog_index, reduce_cve_growth_index, reduce_cves_index,
  reduce_downlevel_packages_growth_index, reduce_downlevel_packages_index,
  reduce_stale_packages_growth_index, reduce_stale_packages_index,
  remove_redundant_packages_index, same_edit_count,
  dataset_metrics_id, datasource_id
FROM staging.edit;

INSERT INTO public.datasource_metrics (
  id,
  commit_date_time, critical_findings,
  critical_findings_avoided_by_patching_past_year,
  critical_findings_in_backlog_between_sixty_and_ninety_days,
  critical_findings_in_backlog_between_thirty_and_sixty_days,
  critical_findings_in_backlog_over_ninety_days,
  datasource_event_count, different_patches, downlevel_packages,
  downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
  event_date_time, findings_avoided_by_patching_past_year,
  findings_in_backlog_between_sixty_and_ninety_days,
  findings_in_backlog_between_thirty_and_sixty_days,
  findings_in_backlog_over_ninety_days,
  high_findings, high_findings_avoided_by_patching_past_year,
  high_findings_in_backlog_between_sixty_and_ninety_days,
  high_findings_in_backlog_between_thirty_and_sixty_days,
  high_findings_in_backlog_over_ninety_days,
  job_id, low_findings,
  low_findings_avoided_by_patching_past_year,
  low_findings_in_backlog_between_sixty_and_ninety_days,
  low_findings_in_backlog_between_thirty_and_sixty_days,
  low_findings_in_backlog_over_ninety_days,
  medium_findings,
  medium_findings_avoided_by_patching_past_year,
  medium_findings_in_backlog_between_sixty_and_ninety_days,
  medium_findings_in_backlog_between_thirty_and_sixty_days,
  medium_findings_in_backlog_over_ninety_days,
  packages, packages_with_critical_findings, packages_with_findings,
  packages_with_high_findings, packages_with_low_findings,
  packages_with_medium_findings,
  patch_efficacy_score, patch_effort, patch_fox_patches,
  patch_impact, patches, purl, same_patches, stale_packages,
  stale_packages_one_year, stale_packages_one_year_six_months,
  stale_packages_six_months, stale_packages_two_years,
  total_findings, txid
)
SELECT
  nextval(pg_get_serial_sequence('public.datasource_metrics','id')),
  commit_date_time, critical_findings,
  critical_findings_avoided_by_patching_past_year,
  critical_findings_in_backlog_between_sixty_and_ninety_days,
  critical_findings_in_backlog_between_thirty_and_sixty_days,
  critical_findings_in_backlog_over_ninety_days,
  datasource_event_count, different_patches, downlevel_packages,
  downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
  event_date_time, findings_avoided_by_patching_past_year,
  findings_in_backlog_between_sixty_and_ninety_days,
  findings_in_backlog_between_thirty_and_sixty_days,
  findings_in_backlog_over_ninety_days,
  high_findings, high_findings_avoided_by_patching_past_year,
  high_findings_in_backlog_between_sixty_and_ninety_days,
  high_findings_in_backlog_between_thirty_and_sixty_days,
  high_findings_in_backlog_over_ninety_days,
  job_id, low_findings,
  low_findings_avoided_by_patching_past_year,
  low_findings_in_backlog_between_sixty_and_ninety_days,
  low_findings_in_backlog_between_thirty_and_sixty_days,
  low_findings_in_backlog_over_ninety_days,
  medium_findings,
  medium_findings_avoided_by_patching_past_year,
  medium_findings_in_backlog_between_sixty_and_ninety_days,
  medium_findings_in_backlog_between_thirty_and_sixty_days,
  medium_findings_in_backlog_over_ninety_days,
  packages, packages_with_critical_findings, packages_with_findings,
  packages_with_high_findings, packages_with_low_findings,
  packages_with_medium_findings,
  patch_efficacy_score, patch_effort, patch_fox_patches,
  patch_impact, patches, purl, same_patches, stale_packages,
  stale_packages_one_year, stale_packages_one_year_six_months,
  stale_packages_six_months, stale_packages_two_years,
  total_findings, txid
FROM staging.datasource_metrics;

TRUNCATE public.datasource_metrics_current;

INSERT INTO public.datasource_metrics_current (
  commit_date_time, critical_findings, datasource_event_count,
  different_patches, downlevel_packages, downlevel_packages_major,
  downlevel_packages_minor, downlevel_packages_patch, event_date_time,
  high_findings, job_id, low_findings, medium_findings, packages,
  packages_with_critical_findings, packages_with_findings,
  packages_with_high_findings, packages_with_low_findings,
  packages_with_medium_findings, patch_fox_patches, patches, purl,
  same_patches, stale_packages, total_findings, txid
)
SELECT DISTINCT ON (purl)
  commit_date_time, critical_findings, datasource_event_count,
  different_patches, downlevel_packages, downlevel_packages_major,
  downlevel_packages_minor, downlevel_packages_patch, event_date_time,
  high_findings, job_id, low_findings, medium_findings, packages,
  packages_with_critical_findings, packages_with_findings,
  packages_with_high_findings, packages_with_low_findings,
  packages_with_medium_findings, patch_fox_patches, patches, purl,
  same_patches, stale_packages, total_findings, txid
FROM public.datasource_metrics
ORDER BY purl, commit_date_time DESC;

INSERT INTO public.datasource_dataset (datasource_id, dataset_id)
SELECT datasource_id, dataset_id FROM staging.datasource_dataset
ON CONFLICT DO NOTHING;

INSERT INTO public.datasource_event_package (datasource_event_id, package_id)
SELECT datasource_event_id, package_id FROM staging.datasource_event_package
ON CONFLICT DO NOTHING;

INSERT INTO public.package_finding (package_id, finding_id)
SELECT package_id, finding_id FROM staging.package_finding
ON CONFLICT DO NOTHING;

INSERT INTO public.package_critical_finding (package_id, finding_id)
SELECT package_id, finding_id FROM staging.package_critical_finding
ON CONFLICT DO NOTHING;

INSERT INTO public.package_high_finding (package_id, finding_id)
SELECT package_id, finding_id FROM staging.package_high_finding
ON CONFLICT DO NOTHING;

INSERT INTO public.package_medium_finding (package_id, finding_id)
SELECT package_id, finding_id FROM staging.package_medium_finding
ON CONFLICT DO NOTHING;

INSERT INTO public.package_low_finding (package_id, finding_id)
SELECT package_id, finding_id FROM staging.package_low_finding
ON CONFLICT DO NOTHING;

INSERT INTO public.finding_to_reporter (finding_id, reporter_id)
SELECT finding_id, reporter_id FROM staging.finding_to_reporter
ON CONFLICT DO NOTHING;

INSERT INTO public.package_family (dataset_metrics_id, package_family)
SELECT dataset_metrics_id, package_family FROM staging.package_family
ON CONFLICT DO NOTHING;


-- ============================================================
-- 8) RESET SEQUENCES (final sanity)
-- ============================================================

SELECT setval(pg_get_serial_sequence('public.dataset','id'),
              COALESCE((SELECT MAX(id) FROM public.dataset),1), true);
SELECT setval(pg_get_serial_sequence('public.datasource','id'),
              COALESCE((SELECT MAX(id) FROM public.datasource),1), true);
SELECT setval(pg_get_serial_sequence('public.datasource_event','id'),
              COALESCE((SELECT MAX(id) FROM public.datasource_event),1), true);
SELECT setval(pg_get_serial_sequence('public.package','id'),
              COALESCE((SELECT MAX(id) FROM public.package),1), true);
SELECT setval(pg_get_serial_sequence('public.finding','id'),
              COALESCE((SELECT MAX(id) FROM public.finding),1), true);
SELECT setval(pg_get_serial_sequence('public.finding_data','id'),
              COALESCE((SELECT MAX(id) FROM public.finding_data),1), true);
SELECT setval(pg_get_serial_sequence('public.finding_reporter','id'),
              COALESCE((SELECT MAX(id) FROM public.finding_reporter),1), true);
SELECT setval(pg_get_serial_sequence('public.dataset_metrics','id'),
              COALESCE((SELECT MAX(id) FROM public.dataset_metrics),1), true);
SELECT setval(pg_get_serial_sequence('public.datasource_metrics','id'),
              COALESCE((SELECT MAX(id) FROM public.datasource_metrics),1), true);
SELECT setval(pg_get_serial_sequence('public.datasource_metrics_current','id'),
              COALESCE((SELECT MAX(id) FROM public.datasource_metrics_current),1), true);
SELECT setval(pg_get_serial_sequence('public.edit','id'),
              COALESCE((SELECT MAX(id) FROM public.edit),1), true);

SET session_replication_role = 'origin';
COMMIT;
