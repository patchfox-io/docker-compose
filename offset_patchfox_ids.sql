-- PostgreSQL ID Offset Script - Custom for PatchFox Schema
-- 
-- This script offsets all numeric IDs in your specific database schema
-- Designed for: Package, Finding, FindingData, FindingReporter, Edit, Datasource,
--               DatasourceMetrics, DatasourceMetricsCurrent, DatasourceEvent, 
--               Dataset, DatasetMetrics
--
-- Usage:
--   1. Set the offset amount below (line 18)
--   2. Import your dump: psql dbname < dump.sql
--   3. Run this script: psql dbname < offset_patchfox_ids.sql
--   4. Export: pg_dump dbname > dump_offset.sql

-- ============================================================================
-- CONFIGURATION
-- ============================================================================
-- NOTE: Change the offset_val value in EACH DO block below (lines 40, 110, 150)
-- Default offset: 1000000

\echo ''
\echo '========================================='
\echo 'PatchFox Schema ID Offset'
\echo '========================================='
\echo ''

-- ============================================================================
-- SAFETY: RUN IN TRANSACTION
-- ============================================================================
BEGIN;

-- ============================================================================
-- STEP 1: DISABLE FOREIGN KEY CHECKS
-- ============================================================================
SET session_replication_role = 'replica';

-- ============================================================================
-- STEP 2: OFFSET ALL PRIMARY KEYS
-- ============================================================================
DO $offset_pks$
DECLARE
    offset_val BIGINT := 1000000;  -- CHANGE THIS VALUE
    rows_updated BIGINT;
BEGIN
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'Offsetting Primary Keys by +%', offset_val;
    RAISE NOTICE '==========================================';
    
    -- Package
    UPDATE package SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] package.id: % rows', rows_updated;
    
    -- Finding
    UPDATE finding SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] finding.id: % rows', rows_updated;
    
    -- FindingData
    UPDATE finding_data SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] finding_data.id: % rows', rows_updated;
    
    -- FindingReporter
    -- UPDATE finding_reporter SET id = id + offset_val WHERE id IS NOT NULL;
    -- GET DIAGNOSTICS rows_updated = ROW_COUNT;
    -- RAISE NOTICE '[PK] finding_reporter.id: % rows', rows_updated;
    
    -- Edit
    UPDATE edit SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] edit.id: % rows', rows_updated;
    
    -- Datasource
    UPDATE datasource SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] datasource.id: % rows', rows_updated;
    
    -- DatasourceMetrics
    UPDATE datasource_metrics SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] datasource_metrics.id: % rows', rows_updated;
    
    -- DatasourceMetricsCurrent
    UPDATE datasource_metrics_current SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] datasource_metrics_current.id: % rows', rows_updated;
    
    -- DatasourceEvent
    UPDATE datasource_event SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] datasource_event.id: % rows', rows_updated;
    
    -- Dataset
    UPDATE dataset SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] dataset.id: % rows', rows_updated;
    
    -- DatasetMetrics
    UPDATE dataset_metrics SET id = id + offset_val WHERE id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[PK] dataset_metrics.id: % rows', rows_updated;
    
    RAISE NOTICE '==========================================';
END $offset_pks$;

-- ============================================================================
-- STEP 3: OFFSET ALL FOREIGN KEYS
-- ============================================================================
DO $offset_fks$
DECLARE
    offset_val BIGINT := 1000000;  -- CHANGE THIS VALUE
    rows_updated BIGINT;
BEGIN
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'Offsetting Foreign Keys by +%', offset_val;
    RAISE NOTICE '==========================================';
    
    -- finding_data.finding_id → finding.id
    UPDATE finding_data SET finding_id = finding_id + offset_val WHERE finding_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[FK] finding_data.finding_id: % rows', rows_updated;
    
    -- edit.dataset_metrics_id → dataset_metrics.id
    UPDATE edit SET dataset_metrics_id = dataset_metrics_id + offset_val WHERE dataset_metrics_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[FK] edit.dataset_metrics_id: % rows', rows_updated;
    
    -- edit.datasource_id → datasource.id
    UPDATE edit SET datasource_id = datasource_id + offset_val WHERE datasource_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[FK] edit.datasource_id: % rows', rows_updated;
    
    -- datasource_event.datasource_id → datasource.id
    UPDATE datasource_event SET datasource_id = datasource_id + offset_val WHERE datasource_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[FK] datasource_event.datasource_id: % rows', rows_updated;
    
    -- dataset_metrics.dataset_id → dataset.id
    UPDATE dataset_metrics SET dataset_id = dataset_id + offset_val WHERE dataset_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[FK] dataset_metrics.dataset_id: % rows', rows_updated;
    
    RAISE NOTICE '==========================================';
END $offset_fks$;

-- ============================================================================
-- STEP 4: OFFSET JOIN TABLE FOREIGN KEYS
-- ============================================================================
DO $offset_joins$
DECLARE
    offset_val BIGINT := 1000000;  -- CHANGE THIS VALUE
    rows_updated BIGINT;
BEGIN
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'Offsetting Join Tables by +%', offset_val;
    RAISE NOTICE '==========================================';
    
    -- package_finding
    UPDATE package_finding 
    SET package_id = package_id + offset_val,
        finding_id = finding_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] package_finding: % rows', rows_updated;
    
    -- package_critical_finding
    UPDATE package_critical_finding 
    SET package_id = package_id + offset_val,
        finding_id = finding_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] package_critical_finding: % rows', rows_updated;
    
    -- package_high_finding
    UPDATE package_high_finding 
    SET package_id = package_id + offset_val,
        finding_id = finding_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] package_high_finding: % rows', rows_updated;
    
    -- package_medium_finding
    UPDATE package_medium_finding 
    SET package_id = package_id + offset_val,
        finding_id = finding_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] package_medium_finding: % rows', rows_updated;
    
    -- package_low_finding
    UPDATE package_low_finding 
    SET package_id = package_id + offset_val,
        finding_id = finding_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] package_low_finding: % rows', rows_updated;
    
    -- finding_to_reporter
    UPDATE finding_to_reporter 
    SET finding_id = finding_id + offset_val; --,
        --reporter_id = reporter_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] finding_to_reporter: % rows', rows_updated;
    
    -- datasource_dataset
    UPDATE datasource_dataset 
    SET datasource_id = datasource_id + offset_val,
        dataset_id = dataset_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] datasource_dataset: % rows', rows_updated;
    
    -- datasource_event_package
    UPDATE datasource_event_package 
    SET datasource_event_id = datasource_event_id + offset_val,
        package_id = package_id + offset_val;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[JOIN] datasource_event_package: % rows', rows_updated;
    
    -- package_family (element collection)
    UPDATE package_family SET dataset_metrics_id = dataset_metrics_id + offset_val WHERE dataset_metrics_id IS NOT NULL;
    GET DIAGNOSTICS rows_updated = ROW_COUNT;
    RAISE NOTICE '[ELEM] package_family: % rows', rows_updated;
    
    RAISE NOTICE '==========================================';
END $offset_joins$;

-- ============================================================================
-- STEP 5: RE-ENABLE FOREIGN KEY CHECKS
-- ============================================================================
SET session_replication_role = 'origin';

-- ============================================================================
-- STEP 6: VALIDATE FOREIGN KEY INTEGRITY
-- ============================================================================
DO $validate$
DECLARE
    violation_count INTEGER;
BEGIN
    RAISE NOTICE '==========================================';
    RAISE NOTICE 'Validating Foreign Key Relationships...';
    RAISE NOTICE '==========================================';
    
    -- finding_data.finding_id → finding.id
    SELECT COUNT(*) INTO violation_count
    FROM finding_data fd
    WHERE fd.finding_id IS NOT NULL 
      AND NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = fd.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: finding_data.finding_id has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ finding_data.finding_id → finding.id';
    
    -- edit.dataset_metrics_id → dataset_metrics.id
    SELECT COUNT(*) INTO violation_count
    FROM edit e
    WHERE e.dataset_metrics_id IS NOT NULL 
      AND NOT EXISTS (SELECT 1 FROM dataset_metrics dm WHERE dm.id = e.dataset_metrics_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: edit.dataset_metrics_id has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ edit.dataset_metrics_id → dataset_metrics.id';
    
    -- edit.datasource_id → datasource.id
    SELECT COUNT(*) INTO violation_count
    FROM edit e
    WHERE e.datasource_id IS NOT NULL 
      AND NOT EXISTS (SELECT 1 FROM datasource d WHERE d.id = e.datasource_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: edit.datasource_id has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ edit.datasource_id → datasource.id';
    
    -- datasource_event.datasource_id → datasource.id
    SELECT COUNT(*) INTO violation_count
    FROM datasource_event de
    WHERE de.datasource_id IS NOT NULL 
      AND NOT EXISTS (SELECT 1 FROM datasource d WHERE d.id = de.datasource_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: datasource_event.datasource_id has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ datasource_event.datasource_id → datasource.id';
    
    -- dataset_metrics.dataset_id → dataset.id
    SELECT COUNT(*) INTO violation_count
    FROM dataset_metrics dm
    WHERE dm.dataset_id IS NOT NULL 
      AND NOT EXISTS (SELECT 1 FROM dataset d WHERE d.id = dm.dataset_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: dataset_metrics.dataset_id has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ dataset_metrics.dataset_id → dataset.id';
    
    -- Validate join tables
    -- package_finding
    SELECT COUNT(*) INTO violation_count
    FROM package_finding pf
    WHERE NOT EXISTS (SELECT 1 FROM package p WHERE p.id = pf.package_id)
       OR NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = pf.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_finding has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_finding → package.id + finding.id';
    
    -- package_critical_finding
    SELECT COUNT(*) INTO violation_count
    FROM package_critical_finding pcf
    WHERE NOT EXISTS (SELECT 1 FROM package p WHERE p.id = pcf.package_id)
       OR NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = pcf.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_critical_finding has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_critical_finding → package.id + finding.id';
    
    -- package_high_finding
    SELECT COUNT(*) INTO violation_count
    FROM package_high_finding phf
    WHERE NOT EXISTS (SELECT 1 FROM package p WHERE p.id = phf.package_id)
       OR NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = phf.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_high_finding has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_high_finding → package.id + finding.id';
    
    -- package_medium_finding
    SELECT COUNT(*) INTO violation_count
    FROM package_medium_finding pmf
    WHERE NOT EXISTS (SELECT 1 FROM package p WHERE p.id = pmf.package_id)
       OR NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = pmf.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_medium_finding has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_medium_finding → package.id + finding.id';
    
    -- package_low_finding
    SELECT COUNT(*) INTO violation_count
    FROM package_low_finding plf
    WHERE NOT EXISTS (SELECT 1 FROM package p WHERE p.id = plf.package_id)
       OR NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = plf.finding_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_low_finding has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_low_finding → package.id + finding.id';
    
    -- finding_to_reporter
    SELECT COUNT(*) INTO violation_count
    FROM finding_to_reporter ftr
    WHERE NOT EXISTS (SELECT 1 FROM finding f WHERE f.id = ftr.finding_id)
       OR NOT EXISTS (SELECT 1 FROM finding_reporter fr WHERE fr.id = ftr.reporter_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: finding_to_reporter has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ finding_to_reporter → finding.id + finding_reporter.id';
    
    -- datasource_dataset
    SELECT COUNT(*) INTO violation_count
    FROM datasource_dataset dd
    WHERE NOT EXISTS (SELECT 1 FROM datasource d WHERE d.id = dd.datasource_id)
       OR NOT EXISTS (SELECT 1 FROM dataset ds WHERE ds.id = dd.dataset_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: datasource_dataset has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ datasource_dataset → datasource.id + dataset.id';
    
    -- datasource_event_package
    SELECT COUNT(*) INTO violation_count
    FROM datasource_event_package dep
    WHERE NOT EXISTS (SELECT 1 FROM datasource_event de WHERE de.id = dep.datasource_event_id)
       OR NOT EXISTS (SELECT 1 FROM package p WHERE p.id = dep.package_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: datasource_event_package has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ datasource_event_package → datasource_event.id + package.id';
    
    -- package_family
    SELECT COUNT(*) INTO violation_count
    FROM package_family pf
    WHERE NOT EXISTS (SELECT 1 FROM dataset_metrics dm WHERE dm.id = pf.dataset_metrics_id);
    IF violation_count > 0 THEN
        RAISE EXCEPTION 'FK VIOLATION: package_family has % orphaned rows', violation_count;
    END IF;
    RAISE NOTICE '✓ package_family → dataset_metrics.id';
    
    RAISE NOTICE '==========================================';
    RAISE NOTICE '✓ All Foreign Key Relationships Valid!';
    RAISE NOTICE '==========================================';
END $validate$;

-- ============================================================================
-- COMMIT THE TRANSACTION
-- ============================================================================
COMMIT;

\echo ''
\echo '========================================='
\echo '✅ SUCCESS: All IDs have been offset!'
\echo '========================================='
\echo ''

-- ============================================================================
-- VERIFICATION: Show new ID ranges
-- ============================================================================
DO $verify$
DECLARE
    min_val BIGINT;
    max_val BIGINT;
    count_val BIGINT;
BEGIN
    RAISE NOTICE 'New ID Ranges:';
    RAISE NOTICE '----------------------------------------';
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM package;
    RAISE NOTICE 'package: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM finding;
    RAISE NOTICE 'finding: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM finding_data;
    RAISE NOTICE 'finding_data: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM finding_reporter;
    RAISE NOTICE 'finding_reporter: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM edit;
    RAISE NOTICE 'edit: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM datasource;
    RAISE NOTICE 'datasource: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM datasource_metrics;
    RAISE NOTICE 'datasource_metrics: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM datasource_metrics_current;
    RAISE NOTICE 'datasource_metrics_current: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM datasource_event;
    RAISE NOTICE 'datasource_event: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM dataset;
    RAISE NOTICE 'dataset: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    SELECT COUNT(*), MIN(id), MAX(id) INTO count_val, min_val, max_val FROM dataset_metrics;
    RAISE NOTICE 'dataset_metrics: count=%, min=%, max=%', count_val, COALESCE(min_val::TEXT, 'NULL'), COALESCE(max_val::TEXT, 'NULL');
    
    RAISE NOTICE '----------------------------------------';
END $verify$;

\echo ''
\echo 'Export the modified database with:'
\echo '  pg_dump dbname > dump_offset.sql'
\echo ''
