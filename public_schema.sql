--
-- PostgreSQL database dump
--

\restrict fvpBbO0BXHILXiGcGexjayIdMXXjNg90BFV7Kxv9B6m0k7felR2UcJWTFVj2zIs

-- Dumped from database version 18.1 (Debian 18.1-1.pgdg13+2)
-- Dumped by pg_dump version 18.1 (Debian 18.1-1.pgdg13+2)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: public; Type: SCHEMA; Schema: -; Owner: pg_database_owner
--

CREATE SCHEMA public;


ALTER SCHEMA public OWNER TO pg_database_owner;

--
-- Name: SCHEMA public; Type: COMMENT; Schema: -; Owner: pg_database_owner
--

COMMENT ON SCHEMA public IS 'standard public schema';


--
-- Name: calculate_edit_statistics(bigint, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.calculate_edit_statistics(p_dataset_metrics_id bigint, p_commit_datetime timestamp with time zone) RETURNS TABLE(total_patches integer, same_patches integer, different_patches integer, pf_patches integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF p_dataset_metrics_id IS NULL THEN
        RAISE EXCEPTION 'Dataset metrics ID cannot be NULL';
    END IF;
    
    IF p_commit_datetime IS NULL THEN
        RAISE EXCEPTION 'Commit datetime cannot be NULL';
    END IF;
    
    RETURN QUERY
    SELECT 
        COUNT(*)::INTEGER as total_patches,
        COUNT(CASE WHEN e.is_same_edit = TRUE THEN 1 END)::INTEGER as same_patches,
        COUNT(CASE WHEN e.is_same_edit = FALSE OR e.is_same_edit IS NULL THEN 1 END)::INTEGER as different_patches,
        COUNT(CASE WHEN e.is_pf_recommended_edit = TRUE THEN 1 END)::INTEGER as pf_patches
    FROM edit e
    WHERE e.dataset_metrics_id = p_dataset_metrics_id
      AND e.commit_date_time = p_commit_datetime;
END;
$$;


ALTER FUNCTION public.calculate_edit_statistics(p_dataset_metrics_id bigint, p_commit_datetime timestamp with time zone) OWNER TO mr_data;

--
-- Name: create_and_associate_packages(bigint, character varying, character varying, character varying, character varying, character varying, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.create_and_associate_packages(in_datasource_event_id bigint, in_purl character varying, in_type character varying, in_namespace character varying, in_name character varying, in_version character varying, in_updated_at timestamp with time zone) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
    DECLARE
        package_pk bigint;
    
    BEGIN
        -- Create package if it doesn't exist
        IF NOT EXISTS (SELECT 1 FROM package WHERE package.purl = in_purl) THEN
            INSERT INTO package (
                purl,
                type,
                namespace,
                name,
                version,
                updated_at,
                number_versions_behind_head,
                number_major_versions_behind_head,
                number_minor_versions_behind_head,
                number_patch_versions_behind_head
            )
            VALUES (
                in_purl,
                in_type,
                in_namespace,
                in_name,
                in_version,
                in_updated_at,
                -1,
                -1,
                -1,
                -1
            );
        END IF;
        
        -- Get the package id
        SELECT p.id 
            FROM package p
            INTO package_pk
            WHERE p.purl = in_purl;
            
        -- Create association between package and datasource_event
        INSERT INTO datasource_event_package (datasource_event_id, package_id)
            VALUES (in_datasource_event_id, package_pk)
            ON CONFLICT DO NOTHING;
        
        -- Return just the package id
        RETURN package_pk;
    END;
$$;


ALTER FUNCTION public.create_and_associate_packages(in_datasource_event_id bigint, in_purl character varying, in_type character varying, in_namespace character varying, in_name character varying, in_version character varying, in_updated_at timestamp with time zone) OWNER TO mr_data;

--
-- Name: create_and_fetch_or_fetch_dataset(character varying, timestamp with time zone, uuid); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.create_and_fetch_or_fetch_dataset(in_name character varying, in_time timestamp with time zone, in_uuid uuid) RETURNS TABLE(id bigint, latest_job_id uuid, latest_txid uuid, name character varying, status character varying, updated_at timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
    BEGIN
    IF NOT EXISTS (SELECT 1 FROM dataset WHERE dataset.name = in_name) THEN
        INSERT INTO dataset (name, updated_at, latest_txid, status)
        VALUES (in_name, in_time, in_uuid, 'INITIALIZING');
    END IF;
    
    UPDATE dataset
        SET 
            updated_at = in_time, 
            latest_txid = in_uuid
        WHERE dataset.name = in_name;
    
    RETURN QUERY 
        SELECT 
            d.id, 
            d.latest_job_id, 
            d.latest_txid, 
            d.name, 
            d.status, 
            d.updated_at 
        FROM dataset d 
        WHERE d.name = in_name;
    END;
$$;


ALTER FUNCTION public.create_and_fetch_or_fetch_dataset(in_name character varying, in_time timestamp with time zone, in_uuid uuid) OWNER TO mr_data;

--
-- Name: create_and_fetch_or_fetch_datasource(character varying, character varying, character varying, timestamp with time zone, uuid, character varying, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.create_and_fetch_or_fetch_datasource(in_dataset_ids_str_encoded_array character varying, in_commit_branch character varying, in_domain character varying, in_event_received_at timestamp with time zone, in_txid uuid, in_datasource_packed_name character varying, in_datasource_purl character varying, in_datasource_type character varying, in_array_delimiter character varying) RETURNS TABLE(id bigint, commit_branch character varying, domain character varying, first_event_received_at timestamp with time zone, last_event_received_at timestamp with time zone, last_event_received_status character varying, latest_job_id uuid, latest_txid uuid, name character varying, number_event_processing_errors double precision, number_events_received double precision, package_indexes bigint[], purl character varying, status character varying, type character varying)
    LANGUAGE plpgsql
    AS $_$

    DECLARE
        dataset_pk bigint;
        datasource_pk bigint;
        tmp_number_events_received int;
        in_dataset_ids bigint[];

    BEGIN
		-- convert string_array args to array type
		-- this is because there is no array type in standard SQL and hibernate is a butt about it 
		-- also spring-data/hibernate is a butt about $$ delimeters so we are using single quote but that messes with
		-- the invocation of string_to_array which uses single quotes to define the delimiter for the array - hence 
		-- we are using a caller supplied argument. Normally ' will work but it does not seem to work in the context
		-- of invocation of a postgres function. 
		SELECT string_to_array(in_dataset_ids_str_encoded_array::text, in_array_delimiter::text) INTO in_dataset_ids;

        IF NOT EXISTS (SELECT 1 FROM datasource WHERE datasource.purl = in_datasource_purl) THEN
            INSERT INTO datasource (
                commit_branch,
                domain,
                first_event_received_at,
                last_event_received_at,
                last_event_received_status,
                latest_txid,
                name,
                number_event_processing_errors,
                number_events_received,
                purl,
                status,
                type
            )
            VALUES (
                in_commit_branch,
                in_domain,
                in_event_received_at,
                in_event_received_at,
                'ACCEPTED',
                in_txid,
                in_datasource_packed_name,
                0,
                1,
                in_datasource_purl,
                'INGESTING',
                in_datasource_type
            );
        END IF;
        
        -- create association between datasource and dataset records 
        SELECT d.id 
            FROM datasource d
            INTO datasource_pk
            WHERE d.purl = in_datasource_purl;

        FOR index IN 1..array_length(in_dataset_ids, 1) LOOP
            INSERT 
                INTO datasource_dataset (datasource_id, dataset_id)
                VALUES (datasource_pk, in_dataset_ids[index])
                ON CONFLICT DO NOTHING;
        END LOOP;

        -- grab current number_events_received value
        SELECT d.number_events_received
            FROM datasource d
            INTO tmp_number_events_received
            WHERE d.purl = in_datasource_purl;        

        UPDATE datasource
            SET 
                last_event_received_at = in_event_received_at,
                last_event_received_status = 'ACCEPTED',
                latest_txid = in_txid,
                number_events_received = tmp_number_events_received + 1
            WHERE datasource.purl = in_datasource_purl;
        
        RETURN QUERY 
            SELECT 
                ds."id",
                ds.commit_branch,
                ds.domain,
                ds.first_event_received_at,
                ds.last_event_received_at,
                ds.last_event_received_status,
                ds.latest_job_id,
                ds.latest_txid,
                ds.name,
                ds.number_event_processing_errors,
                ds.number_events_received,
                ds.package_indexes,
                ds.purl,
                ds.status,
                ds.type 
            FROM datasource ds 
            WHERE ds.purl = in_datasource_purl;

    END;
$_$;


ALTER FUNCTION public.create_and_fetch_or_fetch_datasource(in_dataset_ids_str_encoded_array character varying, in_commit_branch character varying, in_domain character varying, in_event_received_at timestamp with time zone, in_txid uuid, in_datasource_packed_name character varying, in_datasource_purl character varying, in_datasource_type character varying, in_array_delimiter character varying) OWNER TO mr_data;

--
-- Name: create_datasource_event_commit_datetime_index(); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.create_datasource_event_commit_datetime_index()
    LANGUAGE plpgsql
    AS $$
BEGIN
  CREATE INDEX IF NOT EXISTS idx_datasource_event_commit_datetime ON datasource_event(commit_date_time);
  RAISE NOTICE 'Index on datasource_event.commit_date_time created or already exists';
END;
$$;


ALTER PROCEDURE public.create_datasource_event_commit_datetime_index() OWNER TO mr_data;

--
-- Name: create_datasource_metrics_record(bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.create_datasource_metrics_record(p_datasource_event_id bigint, p_previous_datasource_metrics_id bigint, p_current_dataset_metrics_id bigint, p_previous_dataset_metrics_id bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_datasource_metrics_id BIGINT;
BEGIN
    -- If no previous dataset metrics, just use current values (first record scenario)
    IF p_previous_dataset_metrics_id IS NULL THEN
        INSERT INTO datasource_metrics (
            datasource_event_count, commit_date_time, event_date_time, txid, job_id, purl,
            total_findings, critical_findings, high_findings, medium_findings, low_findings,
            findings_avoided_by_patching_past_year, critical_findings_avoided_by_patching_past_year,
            high_findings_avoided_by_patching_past_year, medium_findings_avoided_by_patching_past_year,
            low_findings_avoided_by_patching_past_year,
            findings_in_backlog_between_thirty_and_sixty_days, critical_findings_in_backlog_between_thirty_and_sixty_days,
            high_findings_in_backlog_between_thirty_and_sixty_days, medium_findings_in_backlog_between_thirty_and_sixty_days,
            low_findings_in_backlog_between_thirty_and_sixty_days,
            findings_in_backlog_between_sixty_and_ninety_days, critical_findings_in_backlog_between_sixty_and_ninety_days,
            high_findings_in_backlog_between_sixty_and_ninety_days, medium_findings_in_backlog_between_sixty_and_ninety_days,
            low_findings_in_backlog_between_sixty_and_ninety_days,
            findings_in_backlog_over_ninety_days, critical_findings_in_backlog_over_ninety_days,
            high_findings_in_backlog_over_ninety_days, medium_findings_in_backlog_over_ninety_days,
            low_findings_in_backlog_over_ninety_days,
            packages, packages_with_findings, packages_with_critical_findings, packages_with_high_findings,
            packages_with_medium_findings, packages_with_low_findings,
            downlevel_packages, downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
            stale_packages, stale_packages_six_months, stale_packages_one_year, stale_packages_one_year_six_months,
            stale_packages_two_years, patches, same_patches, different_patches, patch_fox_patches,
            patch_efficacy_score, patch_impact, patch_effort
        )
        SELECT 
            curr_dsm.datasource_event_count, de.commit_date_time, de.event_date_time, de.txid, de.job_id, d.purl,
            curr_dsm.total_findings, curr_dsm.critical_findings, curr_dsm.high_findings, curr_dsm.medium_findings, curr_dsm.low_findings,
            curr_dsm.findings_avoided_by_patching_past_year, curr_dsm.critical_findings_avoided_by_patching_past_year,
            curr_dsm.high_findings_avoided_by_patching_past_year, curr_dsm.medium_findings_avoided_by_patching_past_year,
            curr_dsm.low_findings_avoided_by_patching_past_year,
            curr_dsm.findings_in_backlog_between_thirty_and_sixty_days, curr_dsm.critical_findings_in_backlog_between_thirty_and_sixty_days,
            curr_dsm.high_findings_in_backlog_between_thirty_and_sixty_days, curr_dsm.medium_findings_in_backlog_between_thirty_and_sixty_days,
            curr_dsm.low_findings_in_backlog_between_thirty_and_sixty_days,
            curr_dsm.findings_in_backlog_between_sixty_and_ninety_days, curr_dsm.critical_findings_in_backlog_between_sixty_and_ninety_days,
            curr_dsm.high_findings_in_backlog_between_sixty_and_ninety_days, curr_dsm.medium_findings_in_backlog_between_sixty_and_ninety_days,
            curr_dsm.low_findings_in_backlog_between_sixty_and_ninety_days,
            curr_dsm.findings_in_backlog_over_ninety_days, curr_dsm.critical_findings_in_backlog_over_ninety_days,
            curr_dsm.high_findings_in_backlog_over_ninety_days, curr_dsm.medium_findings_in_backlog_over_ninety_days,
            curr_dsm.low_findings_in_backlog_over_ninety_days,
            curr_dsm.packages, curr_dsm.packages_with_findings, curr_dsm.packages_with_critical_findings, curr_dsm.packages_with_high_findings,
            curr_dsm.packages_with_medium_findings, curr_dsm.packages_with_low_findings,
            curr_dsm.downlevel_packages, curr_dsm.downlevel_packages_major, curr_dsm.downlevel_packages_minor, curr_dsm.downlevel_packages_patch,
            curr_dsm.stale_packages, curr_dsm.stale_packages_six_months, curr_dsm.stale_packages_one_year, curr_dsm.stale_packages_one_year_six_months,
            curr_dsm.stale_packages_two_years, curr_dsm.patches, curr_dsm.same_patches, curr_dsm.different_patches, curr_dsm.patch_fox_patches,
            curr_dsm.patch_efficacy_score, curr_dsm.patch_impact, curr_dsm.patch_effort
        FROM datasource_event de
        JOIN datasource d ON de.datasource_id = d.id
        JOIN dataset_metrics curr_dsm ON curr_dsm.id = p_current_dataset_metrics_id
        WHERE de.id = p_datasource_event_id
        RETURNING id INTO new_datasource_metrics_id;
    ELSE
        -- Delta calculation: just the difference between current and previous
        INSERT INTO datasource_metrics (
            datasource_event_count, commit_date_time, event_date_time, txid, job_id, purl,
            total_findings, critical_findings, high_findings, medium_findings, low_findings,
            findings_avoided_by_patching_past_year, critical_findings_avoided_by_patching_past_year,
            high_findings_avoided_by_patching_past_year, medium_findings_avoided_by_patching_past_year,
            low_findings_avoided_by_patching_past_year,
            findings_in_backlog_between_thirty_and_sixty_days, critical_findings_in_backlog_between_thirty_and_sixty_days,
            high_findings_in_backlog_between_thirty_and_sixty_days, medium_findings_in_backlog_between_thirty_and_sixty_days,
            low_findings_in_backlog_between_thirty_and_sixty_days,
            findings_in_backlog_between_sixty_and_ninety_days, critical_findings_in_backlog_between_sixty_and_ninety_days,
            high_findings_in_backlog_between_sixty_and_ninety_days, medium_findings_in_backlog_between_sixty_and_ninety_days,
            low_findings_in_backlog_between_sixty_and_ninety_days,
            findings_in_backlog_over_ninety_days, critical_findings_in_backlog_over_ninety_days,
            high_findings_in_backlog_over_ninety_days, medium_findings_in_backlog_over_ninety_days,
            low_findings_in_backlog_over_ninety_days,
            packages, packages_with_findings, packages_with_critical_findings, packages_with_high_findings,
            packages_with_medium_findings, packages_with_low_findings,
            downlevel_packages, downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
            stale_packages, stale_packages_six_months, stale_packages_one_year, stale_packages_one_year_six_months,
            stale_packages_two_years, patches, same_patches, different_patches, patch_fox_patches,
            patch_efficacy_score, patch_impact, patch_effort
        )
        SELECT 
            (curr_dsm.datasource_event_count - prev_dsm.datasource_event_count),
            de.commit_date_time, de.event_date_time, de.txid, de.job_id, d.purl,
            (curr_dsm.total_findings - prev_dsm.total_findings),
            (curr_dsm.critical_findings - prev_dsm.critical_findings),
            (curr_dsm.high_findings - prev_dsm.high_findings),
            (curr_dsm.medium_findings - prev_dsm.medium_findings),
            (curr_dsm.low_findings - prev_dsm.low_findings),
            (curr_dsm.findings_avoided_by_patching_past_year - prev_dsm.findings_avoided_by_patching_past_year),
            (curr_dsm.critical_findings_avoided_by_patching_past_year - prev_dsm.critical_findings_avoided_by_patching_past_year),
            (curr_dsm.high_findings_avoided_by_patching_past_year - prev_dsm.high_findings_avoided_by_patching_past_year),
            (curr_dsm.medium_findings_avoided_by_patching_past_year - prev_dsm.medium_findings_avoided_by_patching_past_year),
            (curr_dsm.low_findings_avoided_by_patching_past_year - prev_dsm.low_findings_avoided_by_patching_past_year),
            (curr_dsm.findings_in_backlog_between_thirty_and_sixty_days - prev_dsm.findings_in_backlog_between_thirty_and_sixty_days),
            (curr_dsm.critical_findings_in_backlog_between_thirty_and_sixty_days - prev_dsm.critical_findings_in_backlog_between_thirty_and_sixty_days),
            (curr_dsm.high_findings_in_backlog_between_thirty_and_sixty_days - prev_dsm.high_findings_in_backlog_between_thirty_and_sixty_days),
            (curr_dsm.medium_findings_in_backlog_between_thirty_and_sixty_days - prev_dsm.medium_findings_in_backlog_between_thirty_and_sixty_days),
            (curr_dsm.low_findings_in_backlog_between_thirty_and_sixty_days - prev_dsm.low_findings_in_backlog_between_thirty_and_sixty_days),
            (curr_dsm.findings_in_backlog_between_sixty_and_ninety_days - prev_dsm.findings_in_backlog_between_sixty_and_ninety_days),
            (curr_dsm.critical_findings_in_backlog_between_sixty_and_ninety_days - prev_dsm.critical_findings_in_backlog_between_sixty_and_ninety_days),
            (curr_dsm.high_findings_in_backlog_between_sixty_and_ninety_days - prev_dsm.high_findings_in_backlog_between_sixty_and_ninety_days),
            (curr_dsm.medium_findings_in_backlog_between_sixty_and_ninety_days - prev_dsm.medium_findings_in_backlog_between_sixty_and_ninety_days),
            (curr_dsm.low_findings_in_backlog_between_sixty_and_ninety_days - prev_dsm.low_findings_in_backlog_between_sixty_and_ninety_days),
            (curr_dsm.findings_in_backlog_over_ninety_days - prev_dsm.findings_in_backlog_over_ninety_days),
            (curr_dsm.critical_findings_in_backlog_over_ninety_days - prev_dsm.critical_findings_in_backlog_over_ninety_days),
            (curr_dsm.high_findings_in_backlog_over_ninety_days - prev_dsm.high_findings_in_backlog_over_ninety_days),
            (curr_dsm.medium_findings_in_backlog_over_ninety_days - prev_dsm.medium_findings_in_backlog_over_ninety_days),
            (curr_dsm.low_findings_in_backlog_over_ninety_days - prev_dsm.low_findings_in_backlog_over_ninety_days),
            (curr_dsm.packages - prev_dsm.packages),
            (curr_dsm.packages_with_findings - prev_dsm.packages_with_findings),
            (curr_dsm.packages_with_critical_findings - prev_dsm.packages_with_critical_findings),
            (curr_dsm.packages_with_high_findings - prev_dsm.packages_with_high_findings),
            (curr_dsm.packages_with_medium_findings - prev_dsm.packages_with_medium_findings),
            (curr_dsm.packages_with_low_findings - prev_dsm.packages_with_low_findings),
            (curr_dsm.downlevel_packages - prev_dsm.downlevel_packages),
            (curr_dsm.downlevel_packages_major - prev_dsm.downlevel_packages_major),
            (curr_dsm.downlevel_packages_minor - prev_dsm.downlevel_packages_minor),
            (curr_dsm.downlevel_packages_patch - prev_dsm.downlevel_packages_patch),
            (curr_dsm.stale_packages - prev_dsm.stale_packages),
            (curr_dsm.stale_packages_six_months - prev_dsm.stale_packages_six_months),
            (curr_dsm.stale_packages_one_year - prev_dsm.stale_packages_one_year),
            (curr_dsm.stale_packages_one_year_six_months - prev_dsm.stale_packages_one_year_six_months),
            (curr_dsm.stale_packages_two_years - prev_dsm.stale_packages_two_years),
            (curr_dsm.patches - prev_dsm.patches),
            (curr_dsm.same_patches - prev_dsm.same_patches),
            (curr_dsm.different_patches - prev_dsm.different_patches),
            (curr_dsm.patch_fox_patches - prev_dsm.patch_fox_patches),
            (curr_dsm.patch_efficacy_score - prev_dsm.patch_efficacy_score),
            (curr_dsm.patch_impact - prev_dsm.patch_impact),
            (curr_dsm.patch_effort - prev_dsm.patch_effort)
        FROM datasource_event de
        JOIN datasource d ON de.datasource_id = d.id
        JOIN dataset_metrics curr_dsm ON curr_dsm.id = p_current_dataset_metrics_id
        JOIN dataset_metrics prev_dsm ON prev_dsm.id = p_previous_dataset_metrics_id
        WHERE de.id = p_datasource_event_id
        RETURNING id INTO new_datasource_metrics_id;
    END IF;
    
    RETURN new_datasource_metrics_id;
END;
$$;


ALTER FUNCTION public.create_datasource_metrics_record(p_datasource_event_id bigint, p_previous_datasource_metrics_id bigint, p_current_dataset_metrics_id bigint, p_previous_dataset_metrics_id bigint) OWNER TO mr_data;

--
-- Name: create_edit_indexes(); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.create_edit_indexes()
    LANGUAGE plpgsql
    AS $$
BEGIN
  CREATE INDEX IF NOT EXISTS idx_edit_before_after_commit_time 
  ON edit (before, after, commit_date_time);

  CREATE INDEX IF NOT EXISTS idx_edit_dataset_metrics_commit_time 
  ON edit (dataset_metrics_id, commit_date_time);

  CREATE INDEX IF NOT EXISTS idx_edit_commit_date_time 
  ON edit (commit_date_time);
  
  RAISE NOTICE 'Edit indexes created successfully';
END;
$$;


ALTER PROCEDURE public.create_edit_indexes() OWNER TO mr_data;

--
-- Name: create_findings_performance_indexes(); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.create_findings_performance_indexes()
    LANGUAGE plpgsql
    AS $$
BEGIN
  -- Indexes for dataset metrics procedure
  CREATE INDEX IF NOT EXISTS idx_package_purl ON package(purl);
  CREATE INDEX IF NOT EXISTS idx_package_finding_package_id ON package_finding(package_id);
  CREATE INDEX IF NOT EXISTS idx_package_finding_finding_id ON package_finding(finding_id);
  CREATE INDEX IF NOT EXISTS idx_finding_data_finding_id ON finding_data(finding_id);
  CREATE INDEX IF NOT EXISTS idx_finding_data_severity ON finding_data(severity);
  
  -- Indexes for edit finding counts procedure
  CREATE INDEX IF NOT EXISTS idx_datasource_purl ON datasource(purl);
  CREATE INDEX IF NOT EXISTS idx_edit_datasource_commit_after ON edit(datasource_id, commit_date_time, after);
  CREATE INDEX IF NOT EXISTS idx_edit_id ON edit(id);
  
  RAISE NOTICE 'All performance indexes created successfully';
END;
$$;


ALTER PROCEDURE public.create_findings_performance_indexes() OWNER TO mr_data;

--
-- Name: deduplicate_commit_datetimes(character varying); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.deduplicate_commit_datetimes(IN event_ids_string character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
    duplicate_group RECORD;
    event_record RECORD;
    offset_ms INTEGER;
    event_ids_array BIGINT[];
BEGIN
    -- Ensure index exists for performance
    CALL create_datasource_event_commit_datetime_index();
    
    -- Convert comma-delimited string to array
    event_ids_array := string_to_array(event_ids_string, ',')::BIGINT[];
    
    -- Process each group of records that share the same commit_date_time
    FOR duplicate_group IN 
        SELECT commit_date_time, array_agg(id ORDER BY id) as ids
        FROM datasource_event 
        WHERE id = ANY(event_ids_array)
        GROUP BY commit_date_time
        HAVING COUNT(*) > 1
    LOOP
        -- For each duplicate group, update all but the first record
        offset_ms := 1;
        
        FOR event_record IN 
            SELECT unnest(duplicate_group.ids[2:]) as event_id
        LOOP
            UPDATE datasource_event 
            SET commit_date_time = duplicate_group.commit_date_time + INTERVAL '1 millisecond' * offset_ms
            WHERE id = event_record.event_id;
            
            offset_ms := offset_ms + 1;
        END LOOP;
        
        RAISE NOTICE 'Updated % records with commit_date_time %', 
                     array_length(duplicate_group.ids, 1) - 1, 
                     duplicate_group.commit_date_time;
    END LOOP;
END;
$$;


ALTER PROCEDURE public.deduplicate_commit_datetimes(IN event_ids_string character varying) OWNER TO mr_data;

--
-- Name: detect_and_create_package_edits_fast(bigint, bigint, timestamp with time zone, timestamp with time zone, character varying, character varying, character varying, character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.detect_and_create_package_edits_fast(p_dataset_metrics_id bigint, p_datasource_event_id bigint, p_current_commit_datetime timestamp with time zone, p_historical_commit_datetime timestamp with time zone, p_datasource_purl character varying, p_current_package_purls character varying, p_current_package_families character varying, p_historical_package_purls character varying DEFAULT NULL::character varying, p_historical_package_families character varying DEFAULT NULL::character varying, p_already_seen_current_commit boolean DEFAULT false, p_historical_and_current_same boolean DEFAULT false) RETURNS TABLE(edit_type character varying, before_purl character varying, after_purl character varying, is_same_edit boolean, same_edit_count integer, is_pf_recommended_edit boolean)
    LANGUAGE plpgsql
    AS $$
DECLARE
    current_purl_array VARCHAR[];
    current_family_array VARCHAR[];
    historical_purl_array VARCHAR[];
    historical_family_array VARCHAR[];
    current_array_length INTEGER;
    historical_array_length INTEGER;
    datasource_exists_in_historical BOOLEAN := FALSE;
BEGIN
    -- Convert comma-delimited strings to arrays
    current_purl_array := string_to_array(p_current_package_purls, ',');
    current_family_array := string_to_array(p_current_package_families, ',');
    
    IF p_historical_package_purls IS NOT NULL AND p_historical_package_purls != '' THEN
        historical_purl_array := string_to_array(p_historical_package_purls, ',');
        historical_family_array := string_to_array(p_historical_package_families, ',');
        datasource_exists_in_historical := TRUE;
    END IF;
    
    current_array_length := COALESCE(array_length(current_purl_array, 1), 0);
    historical_array_length := COALESCE(array_length(historical_purl_array, 1), 0);
    
    -- CASE 1: First cycle through loop - everything is CREATE
    IF NOT p_already_seen_current_commit AND p_historical_and_current_same THEN
        RETURN QUERY
        WITH current_packages AS (
            SELECT unnest(current_purl_array) AS purl
        )
        SELECT 
            'CREATE'::VARCHAR(10) as edit_type,
            ''::VARCHAR as before_purl,
            cp.purl::VARCHAR as after_purl,
            FALSE::BOOLEAN as is_same_edit,
            0::INTEGER as same_edit_count,
            FALSE::BOOLEAN as is_pf_recommended_edit
        FROM current_packages cp
        WHERE cp.purl IS NOT NULL AND cp.purl != '';
        RETURN;
    END IF;
    
    -- CASE 2a: New datasource - everything is CREATE  
    IF NOT datasource_exists_in_historical OR historical_array_length = 0 THEN
        RETURN QUERY
        WITH current_packages AS (
            SELECT unnest(current_purl_array) AS purl
        )
        SELECT 
            'CREATE'::VARCHAR(10) as edit_type,
            ''::VARCHAR as before_purl,
            cp.purl::VARCHAR as after_purl,
            FALSE::BOOLEAN as is_same_edit,
            0::INTEGER as same_edit_count,
            FALSE::BOOLEAN as is_pf_recommended_edit
        FROM current_packages cp
        WHERE cp.purl IS NOT NULL AND cp.purl != '';
        RETURN;
    END IF;
    
    -- CASE 2b: Existing datasource - Use fast set-based operations
    RETURN QUERY
    -- WITH current_packages AS (
    --     SELECT 
    --         unnest(current_purl_array) AS purl,
    --         unnest(current_family_array) AS family
    -- ),
    -- historical_packages AS (
    --     SELECT 
    --         unnest(historical_purl_array) AS purl,
    --         unnest(historical_family_array) AS family
    -- ),
    WITH current_packages AS (
        SELECT 
            purl_element AS purl,
            family_element AS family
        FROM 
            unnest(current_purl_array) WITH ORDINALITY AS t1(purl_element, purl_ord)
        JOIN 
            unnest(current_family_array) WITH ORDINALITY AS t2(family_element, family_ord)
            ON t1.purl_ord = t2.family_ord
    ),
    historical_packages AS (
        SELECT 
            purl_element AS purl,
            family_element AS family
        FROM 
            unnest(historical_purl_array) WITH ORDINALITY AS t1(purl_element, purl_ord)
        JOIN 
            unnest(historical_family_array) WITH ORDINALITY AS t2(family_element, family_ord)
            ON t1.purl_ord = t2.family_ord
    ), 
    packages_needing_edits AS (
        SELECT cp.purl, cp.family
        FROM current_packages cp
        LEFT JOIN historical_packages hp ON cp.purl = hp.purl
        WHERE cp.purl IS NOT NULL AND cp.purl != ''
          AND hp.purl IS NULL
    ),
    edit_analysis AS (
        SELECT 
            pne.purl as current_purl,
            pne.family as current_family,
            hp.purl as matching_historical_purl,
            CASE 
                WHEN hp.purl IS NOT NULL THEN 'UPDATE'
                ELSE 'CREATE'
            END as edit_type_determined,
            CASE 
                WHEN hp.purl IS NOT NULL THEN hp.purl
                ELSE ''
            END as before_purl_determined
        FROM packages_needing_edits pne
        LEFT JOIN historical_packages hp ON pne.family = hp.family
    ),
    delete_candidates AS (
        SELECT hp.purl as historical_purl
        FROM historical_packages hp
        LEFT JOIN current_packages cp ON hp.purl = cp.purl
        WHERE hp.purl IS NOT NULL AND hp.purl != ''
          AND cp.purl IS NULL
    ),
    actual_deletes AS (
        SELECT dc.historical_purl
        FROM delete_candidates dc
        LEFT JOIN edit_analysis ea ON dc.historical_purl = ea.before_purl_determined
        WHERE ea.before_purl_determined IS NULL
    ),
    all_edits AS (
        SELECT 
            ea.edit_type_determined as edit_type,
            ea.before_purl_determined as before_purl,
            ea.current_purl as after_purl
        FROM edit_analysis ea
        
        UNION ALL
        
        SELECT 
            'DELETE' as edit_type,
            ad.historical_purl as before_purl,
            '' as after_purl
        FROM actual_deletes ad
    )
    SELECT 
        ae.edit_type::VARCHAR(10) as edit_type,
        ae.before_purl::VARCHAR as before_purl,
        ae.after_purl::VARCHAR as after_purl,
        FALSE::BOOLEAN as is_same_edit,
        0::INTEGER as same_edit_count,
        FALSE::BOOLEAN as is_pf_recommended_edit
    FROM all_edits ae;
    
    RETURN;
END;
$$;


ALTER FUNCTION public.detect_and_create_package_edits_fast(p_dataset_metrics_id bigint, p_datasource_event_id bigint, p_current_commit_datetime timestamp with time zone, p_historical_commit_datetime timestamp with time zone, p_datasource_purl character varying, p_current_package_purls character varying, p_current_package_families character varying, p_historical_package_purls character varying, p_historical_package_families character varying, p_already_seen_current_commit boolean, p_historical_and_current_same boolean) OWNER TO mr_data;

--
-- Name: filter_purls_with_findings(text); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.filter_purls_with_findings(p_purls_string text) RETURNS text[]
    LANGUAGE plpgsql
    AS $$
DECLARE
    result_array TEXT[];
BEGIN
    -- Use unnest to force index usage instead of ANY(array)
    WITH purl_list AS (
        SELECT unnest(string_to_array(p_purls_string, ',')) AS purl
    )
    SELECT array_agg(DISTINCT p.purl) INTO result_array
    FROM purl_list pl
    INNER JOIN package p ON p.purl = pl.purl
    INNER JOIN package_finding pf ON p.id = pf.package_id;
    
    -- Return the result array (handle NULL case)
    RETURN COALESCE(result_array, ARRAY[]::TEXT[]);
END;
$$;


ALTER FUNCTION public.filter_purls_with_findings(p_purls_string text) OWNER TO mr_data;

--
-- Name: get_dsm_ids_and_commit_datetimes(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.get_dsm_ids_and_commit_datetimes(commit_datetime_in timestamp with time zone) RETURNS TABLE(id bigint, commit_datetime timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT dsm.id, dsm.commit_date_time FROM dataset_metrics dsm
    WHERE is_current
    AND dsm.commit_date_time < commit_datetime_in 
    ORDER BY dsm.commit_date_time ASC;
END;
$$;


ALTER FUNCTION public.get_dsm_ids_and_commit_datetimes(commit_datetime_in timestamp with time zone) OWNER TO mr_data;

--
-- Name: get_edit_pairs(timestamp with time zone); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.get_edit_pairs(commit_dt timestamp with time zone) RETURNS TABLE(before_value character varying, after_value character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Return distinct before/after pairs for edits with the given commit date
    RETURN QUERY
    SELECT DISTINCT e.before, e.after
    FROM edit e
    WHERE e.commit_date_time = commit_dt;
END;
$$;


ALTER FUNCTION public.get_edit_pairs(commit_dt timestamp with time zone) OWNER TO mr_data;

--
-- Name: get_edit_pairs_for_cache(bigint, timestamp with time zone); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.get_edit_pairs_for_cache(p_dataset_metrics_id bigint, p_commit_datetime timestamp with time zone) RETURNS TABLE(before_value character varying, after_value character varying)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT DISTINCT e.before, e.after
    FROM edit e
    WHERE e.dataset_metrics_id = p_dataset_metrics_id 
      AND e.commit_date_time = p_commit_datetime;
END;
$$;


ALTER FUNCTION public.get_edit_pairs_for_cache(p_dataset_metrics_id bigint, p_commit_datetime timestamp with time zone) OWNER TO mr_data;

--
-- Name: get_n_months_of_dse_history(integer, boolean); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.get_n_months_of_dse_history(n integer, one_per_day boolean DEFAULT false) RETURNS bigint[]
    LANGUAGE plpgsql
    AS $$
DECLARE
  n_months_ago timestamptz;
  ds_ids bigint[];
  dse_ids bigint[] := '{}'; -- Initialize as empty array
  temp_ids bigint[];        -- Temporary array for each iteration
BEGIN
  SELECT NOW() - (n || ' MONTHS')::INTERVAL INTO n_months_ago;
  
  SELECT array_agg(ds.id) FROM datasource ds INTO ds_ids;
  
  FOR i IN 1..array_length(ds_ids, 1) LOOP
    IF one_per_day THEN
      WITH daily_events AS ( -- Get last event per day for current datasource
        SELECT 
          dse.id,
          dse.datasource_id,
          dse.commit_date_time,
          DATE(dse.commit_date_time) AS event_date,
          ROW_NUMBER() OVER (
            PARTITION BY DATE(dse.commit_date_time) 
            ORDER BY dse.commit_date_time DESC
          ) AS rn
        FROM datasource_event dse
        WHERE dse.datasource_id = ds_ids[i]
        AND (
          dse.commit_date_time >= n_months_ago
-- ****** PUT THIS BACK IN WHEN YOU ARE DONE TROUBLESHOOTING ******
          OR
          dse.commit_date_time = (
            SELECT MAX(dse_inner.commit_date_time)
            FROM datasource_event dse_inner
            WHERE dse_inner.datasource_id = ds_ids[i]
            AND dse_inner.commit_date_time < n_months_ago
          )
        )
      )
      SELECT array_agg(id)
      FROM daily_events
      WHERE rn = 1 -- Only select the last event of each day
      INTO temp_ids;
    ELSE -- Get all events for current datasource (original behavior)
      SELECT array_agg(dse.id)
      FROM datasource_event dse
      INNER JOIN datasource ds
      ON ds.id = dse.datasource_id
      WHERE
        ds.id = ds_ids[i]
        AND
        (
          dse.commit_date_time >= n_months_ago
          OR
          dse.id = (
            SELECT dse_inner.id
            FROM datasource_event dse_inner
            WHERE dse_inner.datasource_id = ds.id
            AND NOT EXISTS (
              SELECT 1
              FROM datasource_event newer
              WHERE newer.datasource_id = ds.id
              AND newer.commit_date_time >= n_months_ago
            )
            ORDER BY dse_inner.commit_date_time DESC
            LIMIT 1
          )
        )
      INTO temp_ids;
    END IF;
    
    IF temp_ids IS NOT NULL THEN -- Append the results to our main array
      dse_ids := dse_ids || temp_ids;
    END IF;
  END LOOP;

  UPDATE datasource_event dse 
    SET status = 'READY_FOR_PROCESSING', job_id = 'd2c6c2f4-af25-4fdd-886f-79762847ffff' 
    WHERE dse.id = ANY(dse_ids);

  RETURN dse_ids;
END;
$$;


ALTER FUNCTION public.get_n_months_of_dse_history(n integer, one_per_day boolean) OWNER TO mr_data;

--
-- Name: insert_package_edits_fast(bigint, bigint, timestamp with time zone, timestamp with time zone, character varying, character varying, character varying, character varying, character varying, boolean, boolean); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.insert_package_edits_fast(IN p_dataset_metrics_id bigint, IN p_datasource_event_id bigint, IN p_current_commit_datetime timestamp with time zone, IN p_historical_commit_datetime timestamp with time zone, IN p_datasource_purl character varying, IN p_current_package_purls character varying, IN p_current_package_families character varying, IN p_historical_package_purls character varying DEFAULT NULL::character varying, IN p_historical_package_families character varying DEFAULT NULL::character varying, IN p_already_seen_current_commit boolean DEFAULT false, IN p_historical_and_current_same boolean DEFAULT false)
    LANGUAGE plpgsql
    AS $$
DECLARE
    edit_rec RECORD;
    event_commit_dt TIMESTAMP WITH TIME ZONE;
    event_event_dt TIMESTAMP WITH TIME ZONE;
    datasource_id_val BIGINT;
    edit_count INTEGER := 0;
BEGIN
    SELECT de.commit_date_time, de.event_date_time, de.datasource_id
    INTO event_commit_dt, event_event_dt, datasource_id_val
    FROM datasource_event de
    WHERE de.id = p_datasource_event_id;
    
    IF datasource_id_val IS NULL THEN
        RAISE EXCEPTION 'Datasource event not found for ID: %', p_datasource_event_id;
    END IF;
    
    FOR edit_rec IN 
        SELECT * FROM detect_and_create_package_edits_fast(
            p_dataset_metrics_id,
            p_datasource_event_id, 
            p_current_commit_datetime,
            p_historical_commit_datetime,
            p_datasource_purl,
            p_current_package_purls,
            p_current_package_families,
            p_historical_package_purls,
            p_historical_package_families,
            p_already_seen_current_commit,
            p_historical_and_current_same
        )
    LOOP
        INSERT INTO edit (
            dataset_metrics_id,
            datasource_id,
            commit_date_time,
            event_date_time,
            edit_type,
            before,
            after,
            is_user_edit,
            is_same_edit,
            same_edit_count,
            is_pf_recommended_edit,
            critical_findings,
            high_findings,
            medium_findings,
            low_findings
        ) VALUES (
            p_dataset_metrics_id,
            datasource_id_val,
            event_commit_dt,
            event_event_dt,
            edit_rec.edit_type,
            edit_rec.before_purl,
            edit_rec.after_purl,
            TRUE,
            FALSE,
            0,
            edit_rec.is_pf_recommended_edit,
            0,
            0,
            0,
            0
        );
        
        edit_count := edit_count + 1;
    END LOOP;
    
END;
$$;


ALTER PROCEDURE public.insert_package_edits_fast(IN p_dataset_metrics_id bigint, IN p_datasource_event_id bigint, IN p_current_commit_datetime timestamp with time zone, IN p_historical_commit_datetime timestamp with time zone, IN p_datasource_purl character varying, IN p_current_package_purls character varying, IN p_current_package_families character varying, IN p_historical_package_purls character varying, IN p_historical_package_families character varying, IN p_already_seen_current_commit boolean, IN p_historical_and_current_same boolean) OWNER TO mr_data;

--
-- Name: process_package_edits_and_statistics(bigint, bigint, timestamp with time zone, timestamp with time zone, character varying, character varying, character varying, character varying, character varying, boolean, boolean); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.process_package_edits_and_statistics(p_dataset_metrics_id bigint, p_datasource_event_id bigint, p_current_commit_datetime timestamp with time zone, p_historical_commit_datetime timestamp with time zone, p_datasource_purl character varying, p_current_package_purls character varying, p_current_package_families character varying, p_historical_package_purls character varying DEFAULT NULL::character varying, p_historical_package_families character varying DEFAULT NULL::character varying, p_already_seen_current_commit boolean DEFAULT false, p_historical_and_current_same boolean DEFAULT false) RETURNS TABLE(total_patches integer, same_patches integer, different_patches integer, pf_patches integer)
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Step 1: Fast insert of package edits (without same-edit detection)
    CALL insert_package_edits_fast(
        p_dataset_metrics_id,
        p_datasource_event_id,
        p_current_commit_datetime,
        p_historical_commit_datetime,
        p_datasource_purl,
        p_current_package_purls,
        p_current_package_families,
        p_historical_package_purls,
        p_historical_package_families,
        p_already_seen_current_commit,
        p_historical_and_current_same
    );
    
    -- Step 2: OPTIMIZED batch update same-edit and PF detection
    CALL update_same_and_pf_edits_batch(p_dataset_metrics_id, p_current_commit_datetime);
    
    -- Step 3: Calculate and return the statistics
    RETURN QUERY
    SELECT * FROM calculate_edit_statistics(p_dataset_metrics_id, p_current_commit_datetime);
END;
$$;


ALTER FUNCTION public.process_package_edits_and_statistics(p_dataset_metrics_id bigint, p_datasource_event_id bigint, p_current_commit_datetime timestamp with time zone, p_historical_commit_datetime timestamp with time zone, p_datasource_purl character varying, p_current_package_purls character varying, p_current_package_families character varying, p_historical_package_purls character varying, p_historical_package_families character varying, p_already_seen_current_commit boolean, p_historical_and_current_same boolean) OWNER TO mr_data;

--
-- Name: store_finding_data(character varying, character varying, character varying, character varying, character varying, timestamp with time zone, character varying, character varying, character varying); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.store_finding_data(finding_reporters_arg_str_encoded_array character varying, cpes_arg_str_encoded_array character varying, description_arg character varying, identifier_arg character varying, patched_in_arg_str_encoded_array character varying, reported_at_arg timestamp with time zone, severity_arg character varying, purl_arg character varying, array_delimiter_arg character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    finding_reporters_arg varchar[];
    cpes_arg varchar[];
    patched_in_arg varchar[];
    finding_pk bigint;
    package_pk bigint;
BEGIN
    -- Convert string arrays to array type
    finding_reporters_arg := string_to_array(finding_reporters_arg_str_encoded_array, array_delimiter_arg);
    cpes_arg := string_to_array(cpes_arg_str_encoded_array, array_delimiter_arg);
    patched_in_arg := string_to_array(patched_in_arg_str_encoded_array, array_delimiter_arg);

    -- Step 1: Bulk insert finding_reporters (avoid loop)
    INSERT INTO finding_reporter (name) 
    SELECT DISTINCT unnest(finding_reporters_arg)
    ON CONFLICT DO NOTHING;

    -- Step 2: Insert finding if it does not exist and get ID
    INSERT INTO finding (identifier) 
    VALUES (identifier_arg)
    ON CONFLICT (identifier) DO NOTHING;
    
    SELECT id INTO finding_pk FROM finding WHERE identifier = identifier_arg;

    -- Step 3: Insert finding_data with finding_id
    INSERT INTO finding_data (cpes, description, identifier, patched_in, reported_at, severity, finding_id) 
    VALUES (
        cpes_arg, 
        description_arg, 
        identifier_arg,
        patched_in_arg,
        reported_at_arg,
        severity_arg,
        finding_pk
    )
    ON CONFLICT (identifier) DO UPDATE SET finding_id = EXCLUDED.finding_id;

    -- Step 4: Bulk insert finding to reporter relationships
    INSERT INTO finding_to_reporter (finding_id, reporter_id)
    SELECT finding_pk, fr.id
    FROM finding_reporter fr 
    WHERE fr.name = ANY(finding_reporters_arg)
    ON CONFLICT DO NOTHING;

    -- Step 5: Get package ID and insert package_finding relationship
    SELECT id INTO package_pk FROM package WHERE purl = purl_arg;
    
    IF package_pk IS NOT NULL THEN
        INSERT INTO package_finding (package_id, finding_id)
        VALUES (package_pk, finding_pk)
        ON CONFLICT DO NOTHING;

        -- Step 6: Insert into appropriate severity table
        IF severity_arg = 'CRITICAL' THEN
            INSERT INTO package_critical_finding (package_id, finding_id)
            VALUES (package_pk, finding_pk)
            ON CONFLICT DO NOTHING;
        ELSEIF severity_arg = 'HIGH' THEN
            INSERT INTO package_high_finding (package_id, finding_id)
            VALUES (package_pk, finding_pk)
            ON CONFLICT DO NOTHING;
        ELSEIF severity_arg = 'MEDIUM' THEN
            INSERT INTO package_medium_finding (package_id, finding_id)
            VALUES (package_pk, finding_pk)
            ON CONFLICT DO NOTHING;
        ELSEIF severity_arg = 'LOW' THEN
            INSERT INTO package_low_finding (package_id, finding_id)
            VALUES (package_pk, finding_pk)
            ON CONFLICT DO NOTHING;
        ELSE
            RAISE NOTICE 'Unexpected severity value: %. Skipping severity-specific index.', severity_arg;
        END IF;
    END IF;

END;
$$;


ALTER FUNCTION public.store_finding_data(finding_reporters_arg_str_encoded_array character varying, cpes_arg_str_encoded_array character varying, description_arg character varying, identifier_arg character varying, patched_in_arg_str_encoded_array character varying, reported_at_arg timestamp with time zone, severity_arg character varying, purl_arg character varying, array_delimiter_arg character varying) OWNER TO mr_data;

--
-- Name: tabulate_package_index_data_batched(character varying, bigint, character varying); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.tabulate_package_index_data_batched(purls_arg_str_encoded_array character varying, datasource_metrics_id_arg bigint, array_delimiter_arg character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    purls_arg varchar[];
    dataset_metrics_tmp record;
    batch_counts record;
BEGIN
    -- Convert string to array once
    SELECT string_to_array(purls_arg_str_encoded_array, array_delimiter_arg) INTO purls_arg;
    
    -- Get the dataset metrics record once
    SELECT * FROM dataset_metrics dsm INTO dataset_metrics_tmp WHERE dsm.id = datasource_metrics_id_arg;
    
    -- Process this batch using a set-based approach
    SELECT
        COUNT(CASE WHEN p.number_versions_behind_head > 0 THEN 1 END) AS downlevel_count,
        COUNT(CASE WHEN p.number_major_versions_behind_head > 0 THEN 1 END) AS downlevel_major_count,
        COUNT(CASE WHEN p.number_minor_versions_behind_head > 0 THEN 1 END) AS downlevel_minor_count,
        COUNT(CASE WHEN p.number_patch_versions_behind_head > 0 THEN 1 END) AS downlevel_patch_count,
        COUNT(CASE WHEN p.most_recent_version_published_at < NOW()::DATE - interval '6 months' THEN 1 END) AS stale_six_months_count,
        COUNT(CASE WHEN p.most_recent_version_published_at < NOW()::DATE - interval '12 months' THEN 1 END) AS stale_one_year_count,
        COUNT(CASE WHEN p.most_recent_version_published_at < NOW()::DATE - interval '18 months' THEN 1 END) AS stale_eighteen_months_count,
        COUNT(CASE WHEN p.most_recent_version_published_at < NOW()::DATE - interval '24 months' THEN 1 END) AS stale_two_years_count
    INTO batch_counts
    FROM package p
    WHERE p.purl = ANY(purls_arg) AND p.most_recent_version IS NOT NULL;
    
    -- Update the metrics by adding to existing values (accumulating)
    UPDATE dataset_metrics dsm
    SET
        downlevel_packages = dsm.downlevel_packages + batch_counts.downlevel_count,
        downlevel_packages_major = dsm.downlevel_packages_major + batch_counts.downlevel_major_count,
        downlevel_packages_minor = dsm.downlevel_packages_minor + batch_counts.downlevel_minor_count,
        downlevel_packages_patch = dsm.downlevel_packages_patch + batch_counts.downlevel_patch_count,
        stale_packages = dsm.stale_packages + batch_counts.stale_six_months_count,
        stale_packages_six_months = dsm.stale_packages_six_months + batch_counts.stale_six_months_count,
        stale_packages_one_year = dsm.stale_packages_one_year + batch_counts.stale_one_year_count,
        stale_packages_one_year_six_months = dsm.stale_packages_one_year_six_months + batch_counts.stale_eighteen_months_count,
        stale_packages_two_years = dsm.stale_packages_two_years + batch_counts.stale_two_years_count
    WHERE dsm.id = dataset_metrics_tmp.id;
END;
$$;


ALTER FUNCTION public.tabulate_package_index_data_batched(purls_arg_str_encoded_array character varying, datasource_metrics_id_arg bigint, array_delimiter_arg character varying) OWNER TO mr_data;

--
-- Name: update_dataset_metrics_findings_counts(text, bigint); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.update_dataset_metrics_findings_counts(IN p_purls_string text, IN p_dataset_metrics_id bigint)
    LANGUAGE plpgsql
    AS $$
BEGIN

  -- Single query optimization - eliminate temporary table and use direct CTE
  WITH purl_list AS (
    SELECT unnest(string_to_array(p_purls_string, ',')) AS purl
  ),
  relevant_packages AS (
    SELECT DISTINCT p.id
    FROM package p
    INNER JOIN purl_list pl ON p.purl = pl.purl
  ),
  findings_data AS (
    SELECT 
      rp.id as package_id,
      fd.severity
    FROM relevant_packages rp
    INNER JOIN package_finding pf ON rp.id = pf.package_id
    INNER JOIN finding f ON pf.finding_id = f.id
    INNER JOIN finding_data fd ON f.id = fd.finding_id
  ),
  aggregated_metrics AS (
    SELECT
      -- Package counts (distinct packages with findings of each severity)
      COUNT(DISTINCT package_id) AS packages_with_findings_count,
      COUNT(DISTINCT CASE WHEN severity = 'CRITICAL' THEN package_id END) AS packages_with_critical_findings_count,
      COUNT(DISTINCT CASE WHEN severity = 'HIGH' THEN package_id END) AS packages_with_high_findings_count,
      COUNT(DISTINCT CASE WHEN severity = 'MEDIUM' THEN package_id END) AS packages_with_medium_findings_count,
      COUNT(DISTINCT CASE WHEN severity = 'LOW' THEN package_id END) AS packages_with_low_findings_count,
      
      -- Finding counts (total findings by severity)
      COUNT(*) AS total_findings_count,
      COUNT(CASE WHEN severity = 'CRITICAL' THEN 1 END) AS critical_findings_count,
      COUNT(CASE WHEN severity = 'HIGH' THEN 1 END) AS high_findings_count,
      COUNT(CASE WHEN severity = 'MEDIUM' THEN 1 END) AS medium_findings_count,
      COUNT(CASE WHEN severity = 'LOW' THEN 1 END) AS low_findings_count
    FROM findings_data
  )
  UPDATE dataset_metrics 
  SET
    packages_with_findings = COALESCE(am.packages_with_findings_count, 0),
    packages_with_critical_findings = COALESCE(am.packages_with_critical_findings_count, 0),
    packages_with_high_findings = COALESCE(am.packages_with_high_findings_count, 0),
    packages_with_medium_findings = COALESCE(am.packages_with_medium_findings_count, 0),
    packages_with_low_findings = COALESCE(am.packages_with_low_findings_count, 0),
    total_findings = COALESCE(am.total_findings_count, 0),
    critical_findings = COALESCE(am.critical_findings_count, 0),
    high_findings = COALESCE(am.high_findings_count, 0),
    medium_findings = COALESCE(am.medium_findings_count, 0),
    low_findings = COALESCE(am.low_findings_count, 0)
  FROM aggregated_metrics am
  WHERE id = p_dataset_metrics_id;
END;
$$;


ALTER PROCEDURE public.update_dataset_metrics_findings_counts(IN p_purls_string text, IN p_dataset_metrics_id bigint) OWNER TO mr_data;

--
-- Name: update_dataset_metrics_patches(bigint, bigint, bigint, bigint, bigint); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.update_dataset_metrics_patches(dataset_metrics_id bigint, p_patches bigint, p_same_patches bigint, p_different_patches bigint, p_patch_fox_patches bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE dataset_metrics 
  SET
    patches = p_patches,
    same_patches = p_same_patches,
    different_patches = p_different_patches,
    patch_fox_patches = p_patch_fox_patches
  WHERE id = dataset_metrics_id;
END;
$$;


ALTER FUNCTION public.update_dataset_metrics_patches(dataset_metrics_id bigint, p_patches bigint, p_same_patches bigint, p_different_patches bigint, p_patch_fox_patches bigint) OWNER TO mr_data;

--
-- Name: update_datasource_events_processing_completed_status(uuid); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.update_datasource_events_processing_completed_status(IN p_job_id uuid)
    LANGUAGE plpgsql
    AS $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- Check if an index exists on the job_id column
  SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE 
      tablename = 'datasource_event' AND
      indexname = 'idx_datasource_event_job_id'
  ) INTO index_exists;
  
  -- If no index exists on job_id, create one
  IF NOT index_exists THEN
    CREATE INDEX idx_datasource_event_job_id ON datasource_event(job_id);
  END IF;

  -- Check if an index exists on the job_id column
  SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE 
      tablename = 'datasource_event' AND
      indexname = 'idx_datasource_event_job_status'
  ) INTO index_exists;
  
  -- If no index exists on job_id, create one
  IF NOT index_exists THEN
    CREATE INDEX idx_datasource_event_job_status ON datasource_event(job_id, status);
  END IF;

  UPDATE datasource_event
  SET 
    recommended = true,
    status = 'PROCESSED'
  WHERE 
    job_id = p_job_id
    AND status != 'PROCESSING_ERROR';
END;
$$;


ALTER PROCEDURE public.update_datasource_events_processing_completed_status(IN p_job_id uuid) OWNER TO mr_data;

--
-- Name: update_datasource_events_processing_status(uuid); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.update_datasource_events_processing_status(IN p_job_id uuid)
    LANGUAGE plpgsql
    AS $$
DECLARE
  index_exists BOOLEAN;
BEGIN
  -- Check if an index exists on the job_id column
  SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE 
      tablename = 'datasource_event' AND
      indexname = 'idx_datasource_event_job_id'
  ) INTO index_exists;
  
  -- If no index exists on job_id, create one
  IF NOT index_exists THEN
    CREATE INDEX idx_datasource_event_job_id ON datasource_event(job_id);
  END IF;

  -- Check if an index exists on the job_id column
  SELECT EXISTS (
    SELECT 1
    FROM pg_indexes
    WHERE 
      tablename = 'datasource_event' AND
      indexname = 'idx_datasource_event_job_status'
  ) INTO index_exists;
  
  -- If no index exists on job_id, create one
  IF NOT index_exists THEN
    CREATE INDEX idx_datasource_event_job_status ON datasource_event(job_id, status);
  END IF;

  UPDATE datasource_event
  SET 
    forecasted = true,
    status = 'PROCESSING'
  WHERE 
    job_id = p_job_id
    AND status != 'PROCESSING_ERROR';
END;
$$;


ALTER PROCEDURE public.update_datasource_events_processing_status(IN p_job_id uuid) OWNER TO mr_data;

--
-- Name: update_datasource_metrics_current(bigint); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.update_datasource_metrics_current(p_datasource_metrics_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    -- Use PostgreSQLs ON CONFLICT to handle insert or update in one statement
    INSERT INTO datasource_metrics_current (
        datasource_event_count, commit_date_time, event_date_time, txid, job_id, purl,
        total_findings, critical_findings, high_findings, medium_findings, low_findings,
        packages, packages_with_findings, packages_with_critical_findings, packages_with_high_findings,
        packages_with_medium_findings, packages_with_low_findings,
        downlevel_packages, downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
        stale_packages, patches, same_patches, different_patches, patch_fox_patches
    )
    SELECT 
        datasource_event_count, commit_date_time, event_date_time, txid, job_id, purl,
        total_findings, critical_findings, high_findings, medium_findings, low_findings,
        packages, packages_with_findings, packages_with_critical_findings, packages_with_high_findings,
        packages_with_medium_findings, packages_with_low_findings,
        downlevel_packages, downlevel_packages_major, downlevel_packages_minor, downlevel_packages_patch,
        stale_packages, patches, same_patches, different_patches, patch_fox_patches
    FROM datasource_metrics dm
    WHERE dm.id = p_datasource_metrics_id
    ON CONFLICT (purl) DO UPDATE SET
        commit_date_time = EXCLUDED.commit_date_time,
        event_date_time = EXCLUDED.event_date_time,
        txid = EXCLUDED.txid,
        job_id = EXCLUDED.job_id,
        -- Accumulate deltas to maintain cumulative totals for findings and packages
        datasource_event_count = GREATEST(0, datasource_metrics_current.datasource_event_count + EXCLUDED.datasource_event_count),
        total_findings = GREATEST(0, datasource_metrics_current.total_findings + EXCLUDED.total_findings),
        critical_findings = GREATEST(0, datasource_metrics_current.critical_findings + EXCLUDED.critical_findings),
        high_findings = GREATEST(0, datasource_metrics_current.high_findings + EXCLUDED.high_findings),
        medium_findings = GREATEST(0, datasource_metrics_current.medium_findings + EXCLUDED.medium_findings),
        low_findings = GREATEST(0, datasource_metrics_current.low_findings + EXCLUDED.low_findings),
        packages = GREATEST(0, datasource_metrics_current.packages + EXCLUDED.packages),
        packages_with_findings = GREATEST(0, datasource_metrics_current.packages_with_findings + EXCLUDED.packages_with_findings),
        packages_with_critical_findings = GREATEST(0, datasource_metrics_current.packages_with_critical_findings + EXCLUDED.packages_with_critical_findings),
        packages_with_high_findings = GREATEST(0, datasource_metrics_current.packages_with_high_findings + EXCLUDED.packages_with_high_findings),
        packages_with_medium_findings = GREATEST(0, datasource_metrics_current.packages_with_medium_findings + EXCLUDED.packages_with_medium_findings),
        packages_with_low_findings = GREATEST(0, datasource_metrics_current.packages_with_low_findings + EXCLUDED.packages_with_low_findings),
        downlevel_packages = GREATEST(0, datasource_metrics_current.downlevel_packages + EXCLUDED.downlevel_packages),
        downlevel_packages_major = GREATEST(0, datasource_metrics_current.downlevel_packages_major + EXCLUDED.downlevel_packages_major),
        downlevel_packages_minor = GREATEST(0, datasource_metrics_current.downlevel_packages_minor + EXCLUDED.downlevel_packages_minor),
        downlevel_packages_patch = GREATEST(0, datasource_metrics_current.downlevel_packages_patch + EXCLUDED.downlevel_packages_patch),
        stale_packages = GREATEST(0, datasource_metrics_current.stale_packages + EXCLUDED.stale_packages),
        -- Set patches values to -1 (not applicable at datasource level)
        patches = -1,
        same_patches = -1,
        different_patches = -1,
        patch_fox_patches = -1;
END;
$$;


ALTER FUNCTION public.update_datasource_metrics_current(p_datasource_metrics_id bigint) OWNER TO mr_data;

--
-- Name: update_edit_and_dataset_metrics_findings(character varying, timestamp with time zone, character varying, character varying, bigint); Type: FUNCTION; Schema: public; Owner: mr_data
--

CREATE FUNCTION public.update_edit_and_dataset_metrics_findings(edit_package_purls_list character varying, edit_commit_dt timestamp with time zone, edit_datasource_purl character varying, dataset_package_purls_list character varying, dataset_metrics_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  start_time TIMESTAMP := clock_timestamp();
  call_id UUID := gen_random_uuid();
  datasource_id_arg BIGINT;
  package_id_array BIGINT[];
  edit_package_id_array BIGINT[];
BEGIN

CREATE TABLE IF NOT EXISTS procedure_timing (
    id SERIAL PRIMARY KEY,
    procedure_call_id UUID,
    step_name TEXT,
    elapsed_ms NUMERIC,
    timestamp TIMESTAMP DEFAULT clock_timestamp()
);

  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Starting procedure', 0);

  -- Get the datasource ID from the provided PURL
  SELECT id INTO datasource_id_arg FROM datasource WHERE purl = edit_datasource_purl;
  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Got datasource ID', EXTRACT(epoch FROM (clock_timestamp() - start_time)) * 1000);

  IF datasource_id_arg IS NULL THEN
    RAISE NOTICE 'Datasource with PURL % not found', edit_datasource_purl;
    RETURN;
  END IF;

  -- Convert edit PURLs to package ID array
  SELECT ARRAY(
    SELECT p.id 
    FROM unnest(string_to_array(edit_package_purls_list, ',')) AS purl_input
    INNER JOIN package p ON p.purl = purl_input
  ) INTO edit_package_id_array;
  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Converted edit PURLs', EXTRACT(epoch FROM (clock_timestamp() - start_time)) * 1000);

  -- Update edit findings using direct array lookups
  UPDATE edit e
  SET 
    critical_findings = (SELECT COUNT(*) FROM package_critical_finding pcf WHERE pcf.package_id = p.id),
    high_findings = (SELECT COUNT(*) FROM package_high_finding phf WHERE phf.package_id = p.id),
    medium_findings = (SELECT COUNT(*) FROM package_medium_finding pmf WHERE pmf.package_id = p.id),
    low_findings = (SELECT COUNT(*) FROM package_low_finding plf WHERE plf.package_id = p.id)
  FROM package p
  WHERE e.after = p.purl
    AND e.datasource_id = datasource_id_arg
    AND e.commit_date_time = edit_commit_dt
    AND p.id = ANY(edit_package_id_array);
  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Updated edit findings', EXTRACT(epoch FROM (clock_timestamp() - start_time)) * 1000);

  -- Convert dataset PURLs to package ID array
  SELECT ARRAY(
    SELECT p.id 
    FROM unnest(string_to_array(dataset_package_purls_list, ',')) AS purl_input
    INNER JOIN package p ON p.purl = purl_input
  ) INTO package_id_array;
  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Converted package PURLs', EXTRACT(epoch FROM (clock_timestamp() - start_time)) * 1000);

  -- Update dataset metrics using direct array-based counts
  UPDATE dataset_metrics 
  SET
    -- Package counts (distinct packages with findings of each severity)
    packages_with_critical_findings = (
      SELECT COUNT(DISTINCT package_id) 
      FROM package_critical_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    packages_with_high_findings = (
      SELECT COUNT(DISTINCT package_id) 
      FROM package_high_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    packages_with_medium_findings = (
      SELECT COUNT(DISTINCT package_id) 
      FROM package_medium_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    packages_with_low_findings = (
      SELECT COUNT(DISTINCT package_id) 
      FROM package_low_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    packages_with_findings = (
      SELECT COUNT(DISTINCT package_id) 
      FROM (
        SELECT package_id FROM package_critical_finding WHERE package_id = ANY(package_id_array)
        UNION
        SELECT package_id FROM package_high_finding WHERE package_id = ANY(package_id_array)
        UNION
        SELECT package_id FROM package_medium_finding WHERE package_id = ANY(package_id_array)
        UNION
        SELECT package_id FROM package_low_finding WHERE package_id = ANY(package_id_array)
      ) all_packages_with_findings
    ),
    -- Finding counts (total findings by severity)
    critical_findings = (
      SELECT COUNT(*) 
      FROM package_critical_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    high_findings = (
      SELECT COUNT(*) 
      FROM package_high_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    medium_findings = (
      SELECT COUNT(*) 
      FROM package_medium_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    low_findings = (
      SELECT COUNT(*) 
      FROM package_low_finding 
      WHERE package_id = ANY(package_id_array)
    ),
    total_findings = (
      SELECT 
        COALESCE((SELECT COUNT(*) FROM package_critical_finding WHERE package_id = ANY(package_id_array)), 0) +
        COALESCE((SELECT COUNT(*) FROM package_high_finding WHERE package_id = ANY(package_id_array)), 0) +
        COALESCE((SELECT COUNT(*) FROM package_medium_finding WHERE package_id = ANY(package_id_array)), 0) +
        COALESCE((SELECT COUNT(*) FROM package_low_finding WHERE package_id = ANY(package_id_array)), 0)
    )
  WHERE id = dataset_metrics_id;
  INSERT INTO procedure_timing (procedure_call_id, step_name, elapsed_ms) 
  VALUES (call_id, 'Updated dataset_metrics and END PROC', EXTRACT(epoch FROM (clock_timestamp() - start_time)) * 1000);

END;
$$;


ALTER FUNCTION public.update_edit_and_dataset_metrics_findings(edit_package_purls_list character varying, edit_commit_dt timestamp with time zone, edit_datasource_purl character varying, dataset_package_purls_list character varying, dataset_metrics_id bigint) OWNER TO mr_data;

--
-- Name: update_edit_finding_counts(character varying, timestamp with time zone, character varying); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.update_edit_finding_counts(IN package_purls_list character varying, IN commit_dt timestamp with time zone, IN datasource_purl character varying)
    LANGUAGE plpgsql
    AS $$
DECLARE
 datasource_id_arg BIGINT;
BEGIN
 -- Get the datasource ID from the provided PURL
 SELECT id INTO datasource_id_arg FROM datasource WHERE purl = datasource_purl;
 
 IF datasource_id_arg IS NULL THEN
   RAISE NOTICE 'Datasource with PURL % not found', datasource_purl;
   RETURN;
 END IF;

 -- Single bulk update - but keep the original logic of matching packages to edits
 WITH package_purls AS (
   SELECT unnest(string_to_array(package_purls_list, ',')) AS purl
 ),
 edit_package_matches AS (
   SELECT 
     e.id as edit_id,
     pp.purl as package_purl
   FROM package_purls pp
   INNER JOIN edit e ON e.after = pp.purl  -- This is the key fix!
   WHERE e.datasource_id = datasource_id_arg
     AND e.commit_date_time = commit_dt
 ),
 finding_counts_by_edit AS (
   SELECT 
     epm.edit_id,
     SUM(CASE WHEN fd.severity = 'CRITICAL' THEN 1 ELSE 0 END) AS critical_count,
     SUM(CASE WHEN fd.severity = 'HIGH' THEN 1 ELSE 0 END) AS high_count,
     SUM(CASE WHEN fd.severity = 'MEDIUM' THEN 1 ELSE 0 END) AS medium_count,
     SUM(CASE WHEN fd.severity = 'LOW' THEN 1 ELSE 0 END) AS low_count
   FROM edit_package_matches epm
   INNER JOIN package p ON p.purl = epm.package_purl
   INNER JOIN package_finding pf ON p.id = pf.package_id
   INNER JOIN finding f ON f.id = pf.finding_id
   INNER JOIN finding_data fd ON fd.finding_id = f.id
   GROUP BY epm.edit_id
 )
 UPDATE edit e
 SET 
   critical_findings = COALESCE(fc.critical_count, 0),
   high_findings = COALESCE(fc.high_count, 0),
   medium_findings = COALESCE(fc.medium_count, 0),
   low_findings = COALESCE(fc.low_count, 0)
 FROM finding_counts_by_edit fc
 WHERE e.id = fc.edit_id;

END;
$$;


ALTER PROCEDURE public.update_edit_finding_counts(IN package_purls_list character varying, IN commit_dt timestamp with time zone, IN datasource_purl character varying) OWNER TO mr_data;

--
-- Name: update_same_and_pf_edits_batch(bigint, timestamp with time zone); Type: PROCEDURE; Schema: public; Owner: mr_data
--

CREATE PROCEDURE public.update_same_and_pf_edits_batch(IN p_dataset_metrics_id bigint, IN p_commit_datetime timestamp with time zone)
    LANGUAGE plpgsql
    AS $$
DECLARE
    cutoff_date TIMESTAMP WITH TIME ZONE;
BEGIN
    cutoff_date := p_commit_datetime - INTERVAL '90 days';
    
    -- Single bulk update using CTEs to eliminate the loop entirely
    WITH current_edits AS (
        SELECT id, edit_type, before, after
        FROM edit 
        WHERE dataset_metrics_id = p_dataset_metrics_id
          AND commit_date_time = p_commit_datetime
    ),
    historical_edit_counts AS (
        SELECT 
            ce.id as current_edit_id,
            ce.edit_type,
            ce.before as current_before,
            ce.after as current_after,
            COUNT(he.id) as same_count,
            -- Check for PF edits (same edit within same dataset)
            COUNT(CASE WHEN he.dataset_metrics_id = p_dataset_metrics_id THEN 1 END) > 0 as has_pf_edit
        FROM current_edits ce
        LEFT JOIN edit he ON (
            -- Match logic based on edit type
            CASE 
                WHEN ce.edit_type = 'CREATE' THEN 
                    (he.before = '' OR he.before IS NULL) AND he.after = ce.after
                WHEN ce.edit_type = 'UPDATE' THEN 
                    he.before = ce.before AND he.after = ce.after
                WHEN ce.edit_type = 'DELETE' THEN 
                    he.before = ce.before AND (he.after = '' OR he.after IS NULL)
                ELSE FALSE
            END
            AND he.commit_date_time < p_commit_datetime
            AND he.commit_date_time >= cutoff_date
        )
        GROUP BY ce.id, ce.edit_type, ce.before, ce.after
    )
    UPDATE edit e
    SET 
        is_same_edit = (hec.same_count > 0),
        same_edit_count = hec.same_count,
        is_pf_recommended_edit = hec.has_pf_edit
    FROM historical_edit_counts hec
    WHERE e.id = hec.current_edit_id;
END;
$$;


ALTER PROCEDURE public.update_same_and_pf_edits_batch(IN p_dataset_metrics_id bigint, IN p_commit_datetime timestamp with time zone) OWNER TO mr_data;

SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: dataset; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.dataset (
    id bigint NOT NULL,
    latest_job_id uuid,
    latest_txid uuid,
    name character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    CONSTRAINT dataset_status_check CHECK (((status)::text = ANY ((ARRAY['INITIALIZING'::character varying, 'INGESTING'::character varying, 'READY_FOR_PROCESSING'::character varying, 'PROCESSING'::character varying, 'PROCESSING_ERROR'::character varying, 'IDLE'::character varying])::text[])))
);


ALTER TABLE public.dataset OWNER TO mr_data;

--
-- Name: dataset_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.dataset ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.dataset_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: dataset_metrics; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.dataset_metrics (
    id bigint NOT NULL,
    commit_date_time timestamp(6) with time zone NOT NULL,
    critical_findings bigint,
    critical_findings_avoided_by_patching_past_year bigint,
    critical_findings_in_backlog_between_sixty_and_ninety_days double precision,
    critical_findings_in_backlog_between_thirty_and_sixty_days double precision,
    critical_findings_in_backlog_over_ninety_days double precision,
    datasource_count bigint NOT NULL,
    datasource_event_count bigint NOT NULL,
    different_patches bigint,
    downlevel_packages bigint,
    downlevel_packages_major bigint,
    downlevel_packages_minor bigint,
    downlevel_packages_patch bigint,
    event_date_time timestamp(6) with time zone NOT NULL,
    findings_avoided_by_patching_past_year bigint,
    findings_in_backlog_between_sixty_and_ninety_days double precision,
    findings_in_backlog_between_thirty_and_sixty_days double precision,
    findings_in_backlog_over_ninety_days double precision,
    forecast_maturity_date timestamp(6) with time zone,
    high_findings bigint,
    high_findings_avoided_by_patching_past_year bigint,
    high_findings_in_backlog_between_sixty_and_ninety_days double precision,
    high_findings_in_backlog_between_thirty_and_sixty_days double precision,
    high_findings_in_backlog_over_ninety_days double precision,
    is_current boolean NOT NULL,
    is_forecast_recommendations_taken boolean NOT NULL,
    is_forecast_same_course boolean NOT NULL,
    job_id uuid NOT NULL,
    low_findings bigint,
    low_findings_avoided_by_patching_past_year bigint,
    low_findings_in_backlog_between_sixty_and_ninety_days double precision,
    low_findings_in_backlog_between_thirty_and_sixty_days double precision,
    low_findings_in_backlog_over_ninety_days double precision,
    medium_findings bigint,
    medium_findings_avoided_by_patching_past_year bigint,
    medium_findings_in_backlog_between_sixty_and_ninety_days double precision,
    medium_findings_in_backlog_between_thirty_and_sixty_days double precision,
    medium_findings_in_backlog_over_ninety_days double precision,
    package_indexes bigint[],
    packages bigint,
    packages_with_critical_findings bigint,
    packages_with_findings bigint,
    packages_with_high_findings bigint,
    packages_with_low_findings bigint,
    packages_with_medium_findings bigint,
    patch_efficacy_score double precision,
    patch_effort double precision,
    patch_fox_patches bigint,
    patch_impact double precision,
    patches bigint,
    recommendation_headline character varying(255),
    recommendation_type character varying(255),
    rps_score double precision,
    same_patches bigint,
    stale_packages bigint,
    stale_packages_one_year bigint,
    stale_packages_one_year_six_months bigint,
    stale_packages_six_months bigint,
    stale_packages_two_years bigint,
    total_findings bigint,
    txid uuid NOT NULL,
    dataset_id bigint NOT NULL,
    CONSTRAINT dataset_metrics_recommendation_type_check CHECK (((recommendation_type)::text = ANY ((ARRAY['REDUCE_CVES'::character varying, 'REDUCE_CVE_GROWTH'::character varying, 'REDUCE_CVE_BACKLOG'::character varying, 'REDUCE_CVE_BACKLOG_GROWTH'::character varying, 'REDUCE_STALE_PACKAGES'::character varying, 'REDUCE_STALE_PACKAGES_GROWTH'::character varying, 'REDUCE_DOWNLEVEL_PACKAGES'::character varying, 'REDUCE_DOWNLEVEL_PACKAGES_GROWTH'::character varying, 'GROW_PATCH_EFFICACY'::character varying, 'REMOVE_REDUNDANT_PACKAGES'::character varying])::text[])))
);


ALTER TABLE public.dataset_metrics OWNER TO mr_data;

--
-- Name: dataset_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.dataset_metrics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.dataset_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: datasource; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource (
    id bigint NOT NULL,
    commit_branch character varying(255),
    domain character varying(255) NOT NULL,
    first_event_received_at timestamp(6) with time zone NOT NULL,
    last_event_received_at timestamp(6) with time zone NOT NULL,
    last_event_received_status character varying(255) NOT NULL,
    latest_job_id uuid,
    latest_txid uuid,
    name character varying(255) NOT NULL,
    number_event_processing_errors double precision NOT NULL,
    number_events_received double precision NOT NULL,
    package_indexes bigint[],
    purl character varying(255) NOT NULL,
    status character varying(255) NOT NULL,
    type character varying(255) NOT NULL,
    CONSTRAINT datasource_status_check CHECK (((status)::text = ANY ((ARRAY['INITIALIZING'::character varying, 'INGESTING'::character varying, 'READY_FOR_PROCESSING'::character varying, 'READY_FOR_NEXT_PROCESSING'::character varying, 'PROCESSING'::character varying, 'PROCESSING_ERROR'::character varying, 'IDLE'::character varying])::text[])))
);


ALTER TABLE public.datasource OWNER TO mr_data;

--
-- Name: datasource_dataset; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource_dataset (
    datasource_id bigint NOT NULL,
    dataset_id bigint NOT NULL
);


ALTER TABLE public.datasource_dataset OWNER TO mr_data;

--
-- Name: datasource_event; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource_event (
    id bigint NOT NULL,
    analyzed boolean,
    commit_branch character varying(255),
    commit_date_time timestamp(6) with time zone,
    commit_hash character varying(255),
    event_date_time timestamp(6) with time zone NOT NULL,
    forecasted boolean,
    job_id uuid,
    oss_enriched boolean,
    package_index_enriched boolean,
    payload bytea NOT NULL,
    processing_error character varying(255),
    purl character varying(255) NOT NULL,
    recommended boolean,
    status character varying(255) NOT NULL,
    txid uuid NOT NULL,
    datasource_id bigint NOT NULL,
    CONSTRAINT datasource_event_status_check CHECK (((status)::text = ANY ((ARRAY['INGESTING'::character varying, 'READY_FOR_PROCESSING'::character varying, 'READY_FOR_NEXT_PROCESSING'::character varying, 'PROCESSING'::character varying, 'PROCESSED'::character varying, 'PROCESSING_ERROR'::character varying])::text[])))
);


ALTER TABLE public.datasource_event OWNER TO mr_data;

--
-- Name: datasource_event_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.datasource_event ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datasource_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: datasource_event_package; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource_event_package (
    datasource_event_id bigint NOT NULL,
    package_id bigint NOT NULL
);


ALTER TABLE public.datasource_event_package OWNER TO mr_data;

--
-- Name: datasource_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.datasource ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datasource_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: datasource_metrics; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource_metrics (
    id bigint NOT NULL,
    commit_date_time timestamp(6) with time zone NOT NULL,
    critical_findings bigint,
    critical_findings_avoided_by_patching_past_year bigint,
    critical_findings_in_backlog_between_sixty_and_ninety_days double precision,
    critical_findings_in_backlog_between_thirty_and_sixty_days double precision,
    critical_findings_in_backlog_over_ninety_days double precision,
    datasource_event_count bigint NOT NULL,
    different_patches bigint,
    downlevel_packages bigint,
    downlevel_packages_major bigint,
    downlevel_packages_minor bigint,
    downlevel_packages_patch bigint,
    event_date_time timestamp(6) with time zone NOT NULL,
    findings_avoided_by_patching_past_year bigint,
    findings_in_backlog_between_sixty_and_ninety_days double precision,
    findings_in_backlog_between_thirty_and_sixty_days double precision,
    findings_in_backlog_over_ninety_days double precision,
    high_findings bigint,
    high_findings_avoided_by_patching_past_year bigint,
    high_findings_in_backlog_between_sixty_and_ninety_days double precision,
    high_findings_in_backlog_between_thirty_and_sixty_days double precision,
    high_findings_in_backlog_over_ninety_days double precision,
    job_id uuid NOT NULL,
    low_findings bigint,
    low_findings_avoided_by_patching_past_year bigint,
    low_findings_in_backlog_between_sixty_and_ninety_days double precision,
    low_findings_in_backlog_between_thirty_and_sixty_days double precision,
    low_findings_in_backlog_over_ninety_days double precision,
    medium_findings bigint,
    medium_findings_avoided_by_patching_past_year bigint,
    medium_findings_in_backlog_between_sixty_and_ninety_days double precision,
    medium_findings_in_backlog_between_thirty_and_sixty_days double precision,
    medium_findings_in_backlog_over_ninety_days double precision,
    packages bigint,
    packages_with_critical_findings bigint,
    packages_with_findings bigint,
    packages_with_high_findings bigint,
    packages_with_low_findings bigint,
    packages_with_medium_findings bigint,
    patch_efficacy_score double precision,
    patch_effort double precision,
    patch_fox_patches bigint,
    patch_impact double precision,
    patches bigint,
    purl character varying(255) NOT NULL,
    same_patches bigint,
    stale_packages bigint,
    stale_packages_one_year bigint,
    stale_packages_one_year_six_months bigint,
    stale_packages_six_months bigint,
    stale_packages_two_years bigint,
    total_findings bigint,
    txid uuid NOT NULL
);


ALTER TABLE public.datasource_metrics OWNER TO mr_data;

--
-- Name: datasource_metrics_current; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.datasource_metrics_current (
    id bigint NOT NULL,
    commit_date_time timestamp(6) with time zone NOT NULL,
    critical_findings bigint,
    datasource_event_count bigint NOT NULL,
    different_patches bigint,
    downlevel_packages bigint,
    downlevel_packages_major bigint,
    downlevel_packages_minor bigint,
    downlevel_packages_patch bigint,
    event_date_time timestamp(6) with time zone NOT NULL,
    high_findings bigint,
    job_id uuid NOT NULL,
    low_findings bigint,
    medium_findings bigint,
    packages bigint,
    packages_with_critical_findings bigint,
    packages_with_findings bigint,
    packages_with_high_findings bigint,
    packages_with_low_findings bigint,
    packages_with_medium_findings bigint,
    patch_fox_patches bigint,
    patches bigint,
    purl character varying(255) NOT NULL,
    same_patches bigint,
    stale_packages bigint,
    total_findings bigint,
    txid uuid NOT NULL
);


ALTER TABLE public.datasource_metrics_current OWNER TO mr_data;

--
-- Name: datasource_metrics_current_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.datasource_metrics_current ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datasource_metrics_current_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: datasource_metrics_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.datasource_metrics ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.datasource_metrics_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: edit; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.edit (
    id bigint NOT NULL,
    after character varying(255) NOT NULL,
    avoids_vulnerabilities_rank integer,
    before character varying(255) NOT NULL,
    commit_date_time timestamp(6) with time zone NOT NULL,
    critical_findings integer,
    decrease_backlog_rank integer,
    decrease_vulnerability_count_rank integer,
    edit_type character varying(255) NOT NULL,
    event_date_time timestamp(6) with time zone NOT NULL,
    grow_patch_efficacy_index integer,
    high_findings integer,
    increase_impact_rank integer,
    is_pf_recommended_edit boolean,
    is_same_edit boolean,
    is_user_edit boolean,
    low_findings integer,
    medium_findings integer,
    reduce_cve_backlog_growth_index integer,
    reduce_cve_backlog_index integer,
    reduce_cve_growth_index integer,
    reduce_cves_index integer,
    reduce_downlevel_packages_growth_index integer,
    reduce_downlevel_packages_index integer,
    reduce_stale_packages_growth_index integer,
    reduce_stale_packages_index integer,
    remove_redundant_packages_index integer,
    same_edit_count integer,
    dataset_metrics_id bigint,
    datasource_id bigint NOT NULL,
    CONSTRAINT edit_edit_type_check CHECK (((edit_type)::text = ANY ((ARRAY['CREATE'::character varying, 'UPDATE'::character varying, 'DELETE'::character varying])::text[])))
);


ALTER TABLE public.edit OWNER TO mr_data;

--
-- Name: edit_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.edit ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.edit_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.finding (
    id bigint NOT NULL,
    identifier character varying(255) NOT NULL
);


ALTER TABLE public.finding OWNER TO mr_data;

--
-- Name: finding_data; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.finding_data (
    id bigint NOT NULL,
    cpes character varying(255)[] NOT NULL,
    description character varying(8192) NOT NULL,
    identifier character varying(255) NOT NULL,
    patched_in character varying(255)[],
    published_at timestamp(6) with time zone,
    reported_at timestamp(6) with time zone NOT NULL,
    severity character varying(255) NOT NULL,
    finding_id bigint
);


ALTER TABLE public.finding_data OWNER TO mr_data;

--
-- Name: finding_data_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.finding_data ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.finding_data_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: finding_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.finding ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.finding_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: finding_reporter; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.finding_reporter (
    id bigint NOT NULL,
    name character varying(255) NOT NULL
);


ALTER TABLE public.finding_reporter OWNER TO mr_data;

--
-- Name: finding_reporter_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.finding_reporter ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.finding_reporter_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: finding_to_reporter; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.finding_to_reporter (
    finding_id bigint NOT NULL,
    reporter_id bigint NOT NULL
);


ALTER TABLE public.finding_to_reporter OWNER TO mr_data;

--
-- Name: package; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package (
    id bigint NOT NULL,
    most_recent_version character varying(255),
    most_recent_version_published_at timestamp(6) with time zone,
    name character varying(255) NOT NULL,
    namespace character varying(255),
    number_major_versions_behind_head integer,
    number_minor_versions_behind_head integer,
    number_patch_versions_behind_head integer,
    number_versions_behind_head integer,
    purl character varying(255) NOT NULL,
    this_version_published_at timestamp(6) with time zone,
    type character varying(255) NOT NULL,
    updated_at timestamp(6) with time zone NOT NULL,
    version character varying(255)
);


ALTER TABLE public.package OWNER TO mr_data;

--
-- Name: package_critical_finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_critical_finding (
    package_id bigint NOT NULL,
    finding_id bigint NOT NULL
);


ALTER TABLE public.package_critical_finding OWNER TO mr_data;

--
-- Name: package_family; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_family (
    dataset_metrics_id bigint NOT NULL,
    package_family character varying(255)
);


ALTER TABLE public.package_family OWNER TO mr_data;

--
-- Name: package_finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_finding (
    package_id bigint NOT NULL,
    finding_id bigint NOT NULL
);


ALTER TABLE public.package_finding OWNER TO mr_data;

--
-- Name: package_high_finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_high_finding (
    package_id bigint NOT NULL,
    finding_id bigint NOT NULL
);


ALTER TABLE public.package_high_finding OWNER TO mr_data;

--
-- Name: package_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

ALTER TABLE public.package ALTER COLUMN id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.package_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: package_low_finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_low_finding (
    package_id bigint NOT NULL,
    finding_id bigint NOT NULL
);


ALTER TABLE public.package_low_finding OWNER TO mr_data;

--
-- Name: package_medium_finding; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.package_medium_finding (
    package_id bigint NOT NULL,
    finding_id bigint NOT NULL
);


ALTER TABLE public.package_medium_finding OWNER TO mr_data;

--
-- Name: procedure_timing; Type: TABLE; Schema: public; Owner: mr_data
--

CREATE TABLE public.procedure_timing (
    id integer NOT NULL,
    procedure_call_id uuid,
    step_name text,
    elapsed_ms numeric,
    "timestamp" timestamp without time zone DEFAULT clock_timestamp()
);


ALTER TABLE public.procedure_timing OWNER TO mr_data;

--
-- Name: procedure_timing_id_seq; Type: SEQUENCE; Schema: public; Owner: mr_data
--

CREATE SEQUENCE public.procedure_timing_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE public.procedure_timing_id_seq OWNER TO mr_data;

--
-- Name: procedure_timing_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: mr_data
--

ALTER SEQUENCE public.procedure_timing_id_seq OWNED BY public.procedure_timing.id;


--
-- Name: procedure_timing id; Type: DEFAULT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.procedure_timing ALTER COLUMN id SET DEFAULT nextval('public.procedure_timing_id_seq'::regclass);


--
-- Name: dataset_metrics dataset_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.dataset_metrics
    ADD CONSTRAINT dataset_metrics_pkey PRIMARY KEY (id);


--
-- Name: dataset dataset_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.dataset
    ADD CONSTRAINT dataset_pkey PRIMARY KEY (id);


--
-- Name: datasource_dataset datasource_dataset_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_dataset
    ADD CONSTRAINT datasource_dataset_pkey PRIMARY KEY (datasource_id, dataset_id);


--
-- Name: datasource_event_package datasource_event_package_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event_package
    ADD CONSTRAINT datasource_event_package_pkey PRIMARY KEY (datasource_event_id, package_id);


--
-- Name: datasource_event datasource_event_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event
    ADD CONSTRAINT datasource_event_pkey PRIMARY KEY (id);


--
-- Name: datasource_metrics_current datasource_metrics_current_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_metrics_current
    ADD CONSTRAINT datasource_metrics_current_pkey PRIMARY KEY (id);


--
-- Name: datasource_metrics datasource_metrics_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_metrics
    ADD CONSTRAINT datasource_metrics_pkey PRIMARY KEY (id);


--
-- Name: datasource datasource_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource
    ADD CONSTRAINT datasource_pkey PRIMARY KEY (id);


--
-- Name: edit edit_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.edit
    ADD CONSTRAINT edit_pkey PRIMARY KEY (id);


--
-- Name: finding_data finding_data_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_data
    ADD CONSTRAINT finding_data_pkey PRIMARY KEY (id);


--
-- Name: finding finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding
    ADD CONSTRAINT finding_pkey PRIMARY KEY (id);


--
-- Name: finding_reporter finding_reporter_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_reporter
    ADD CONSTRAINT finding_reporter_pkey PRIMARY KEY (id);


--
-- Name: finding_to_reporter finding_to_reporter_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_to_reporter
    ADD CONSTRAINT finding_to_reporter_pkey PRIMARY KEY (finding_id, reporter_id);


--
-- Name: package_critical_finding package_critical_finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_critical_finding
    ADD CONSTRAINT package_critical_finding_pkey PRIMARY KEY (package_id, finding_id);


--
-- Name: package_finding package_finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_finding
    ADD CONSTRAINT package_finding_pkey PRIMARY KEY (package_id, finding_id);


--
-- Name: package_high_finding package_high_finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_high_finding
    ADD CONSTRAINT package_high_finding_pkey PRIMARY KEY (package_id, finding_id);


--
-- Name: package_low_finding package_low_finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_low_finding
    ADD CONSTRAINT package_low_finding_pkey PRIMARY KEY (package_id, finding_id);


--
-- Name: package_medium_finding package_medium_finding_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_medium_finding
    ADD CONSTRAINT package_medium_finding_pkey PRIMARY KEY (package_id, finding_id);


--
-- Name: package package_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package
    ADD CONSTRAINT package_pkey PRIMARY KEY (id);


--
-- Name: procedure_timing procedure_timing_pkey; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.procedure_timing
    ADD CONSTRAINT procedure_timing_pkey PRIMARY KEY (id);


--
-- Name: finding_data uk2d8ejytc10tl6wyrb1dunbtyc; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_data
    ADD CONSTRAINT uk2d8ejytc10tl6wyrb1dunbtyc UNIQUE (finding_id);


--
-- Name: finding_data uk35sf8rkdct2lab74djx2hxg9o; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_data
    ADD CONSTRAINT uk35sf8rkdct2lab74djx2hxg9o UNIQUE (identifier);


--
-- Name: datasource uk4ytprj4jxce9ehrfrlkw2wd2m; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource
    ADD CONSTRAINT uk4ytprj4jxce9ehrfrlkw2wd2m UNIQUE (latest_txid);


--
-- Name: datasource_event uk9rk4qcepxi407i1xk8hcb1bqv; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event
    ADD CONSTRAINT uk9rk4qcepxi407i1xk8hcb1bqv UNIQUE (txid);


--
-- Name: finding ukbefks5h7axw1f021ili6ig5gf; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding
    ADD CONSTRAINT ukbefks5h7axw1f021ili6ig5gf UNIQUE (identifier);


--
-- Name: datasource_event ukbtuv83h1r04qfg9n76piebn60; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event
    ADD CONSTRAINT ukbtuv83h1r04qfg9n76piebn60 UNIQUE (purl);


--
-- Name: dataset ukdbnlaexy1pt73fsudb1m8ora6; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.dataset
    ADD CONSTRAINT ukdbnlaexy1pt73fsudb1m8ora6 UNIQUE (name);


--
-- Name: dataset uki2dieloqteg3ceet6kw79h9v7; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.dataset
    ADD CONSTRAINT uki2dieloqteg3ceet6kw79h9v7 UNIQUE (latest_txid);


--
-- Name: datasource_metrics_current ukloskftubucy7luo3e4ytqs5cl; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_metrics_current
    ADD CONSTRAINT ukloskftubucy7luo3e4ytqs5cl UNIQUE (purl);


--
-- Name: datasource ukof8qr0mqdcouqsk15m12ehej6; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource
    ADD CONSTRAINT ukof8qr0mqdcouqsk15m12ehej6 UNIQUE (purl);


--
-- Name: finding_reporter ukosiadfd1g6rbnya333xr30cxm; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_reporter
    ADD CONSTRAINT ukosiadfd1g6rbnya333xr30cxm UNIQUE (name);


--
-- Name: package ukrejo9lw7d4akwa49xtt7xk37p; Type: CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package
    ADD CONSTRAINT ukrejo9lw7d4akwa49xtt7xk37p UNIQUE (purl);


--
-- Name: idx_datasource_event_commit_datetime; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_datasource_event_commit_datetime ON public.datasource_event USING btree (commit_date_time);


--
-- Name: idx_datasource_event_job_id; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_datasource_event_job_id ON public.datasource_event USING btree (job_id);


--
-- Name: idx_datasource_event_job_status; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_datasource_event_job_status ON public.datasource_event USING btree (job_id, status);


--
-- Name: idx_datasource_purl; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_datasource_purl ON public.datasource USING btree (purl);


--
-- Name: idx_edit_before_after_commit_time; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_edit_before_after_commit_time ON public.edit USING btree (before, after, commit_date_time);


--
-- Name: idx_edit_commit_date_time; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_edit_commit_date_time ON public.edit USING btree (commit_date_time);


--
-- Name: idx_edit_dataset_metrics_commit_time; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_edit_dataset_metrics_commit_time ON public.edit USING btree (dataset_metrics_id, commit_date_time);


--
-- Name: idx_edit_datasource_commit_after; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_edit_datasource_commit_after ON public.edit USING btree (datasource_id, commit_date_time, after);


--
-- Name: idx_edit_id; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_edit_id ON public.edit USING btree (id);


--
-- Name: idx_finding_data_finding_id; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_finding_data_finding_id ON public.finding_data USING btree (finding_id);


--
-- Name: idx_finding_data_severity; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_finding_data_severity ON public.finding_data USING btree (severity);


--
-- Name: idx_package_finding_finding_id; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_package_finding_finding_id ON public.package_finding USING btree (finding_id);


--
-- Name: idx_package_finding_package_id; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_package_finding_package_id ON public.package_finding USING btree (package_id);


--
-- Name: idx_package_purl; Type: INDEX; Schema: public; Owner: mr_data
--

CREATE INDEX idx_package_purl ON public.package USING btree (purl);


--
-- Name: package_high_finding fk22eapq2uqq3eebp90g8fpdhgb; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_high_finding
    ADD CONSTRAINT fk22eapq2uqq3eebp90g8fpdhgb FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: package_low_finding fk3b5xal3khcmgipup6yqp4uhr3; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_low_finding
    ADD CONSTRAINT fk3b5xal3khcmgipup6yqp4uhr3 FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: package_medium_finding fk5g3df1iktrlr8pfq5o7ynjwlb; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_medium_finding
    ADD CONSTRAINT fk5g3df1iktrlr8pfq5o7ynjwlb FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: package_high_finding fk66phtd6y6vdkt73qymi9gpn3w; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_high_finding
    ADD CONSTRAINT fk66phtd6y6vdkt73qymi9gpn3w FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: datasource_dataset fk7liqdn7ex1923voy24w0nmokn; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_dataset
    ADD CONSTRAINT fk7liqdn7ex1923voy24w0nmokn FOREIGN KEY (dataset_id) REFERENCES public.dataset(id);


--
-- Name: package_critical_finding fk8d5qldho6u1463k5bpltbn2vt; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_critical_finding
    ADD CONSTRAINT fk8d5qldho6u1463k5bpltbn2vt FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: package_low_finding fk91f8cmlfqckrn5ayelua0ys8a; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_low_finding
    ADD CONSTRAINT fk91f8cmlfqckrn5ayelua0ys8a FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: package_finding fkautup2fkcxxh4hhpbgwxd3tdk; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_finding
    ADD CONSTRAINT fkautup2fkcxxh4hhpbgwxd3tdk FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: edit fkb6mfda095jvjgg8t5h8wtrxdd; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.edit
    ADD CONSTRAINT fkb6mfda095jvjgg8t5h8wtrxdd FOREIGN KEY (datasource_id) REFERENCES public.datasource(id);


--
-- Name: finding_data fkddg6696ut28f1dtowyqot4id4; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_data
    ADD CONSTRAINT fkddg6696ut28f1dtowyqot4id4 FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: datasource_event_package fkedfdxljpgwbbkl4x7q37cn1m2; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event_package
    ADD CONSTRAINT fkedfdxljpgwbbkl4x7q37cn1m2 FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: datasource_event fkgqig4ob825l95hak9mc0pew8o; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event
    ADD CONSTRAINT fkgqig4ob825l95hak9mc0pew8o FOREIGN KEY (datasource_id) REFERENCES public.datasource(id);


--
-- Name: datasource_event_package fkh6pt0e2lcxktax08ag8wp8n1l; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_event_package
    ADD CONSTRAINT fkh6pt0e2lcxktax08ag8wp8n1l FOREIGN KEY (datasource_event_id) REFERENCES public.datasource_event(id);


--
-- Name: finding_to_reporter fkkcajw2tb501mvh5fcfgr1oxle; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_to_reporter
    ADD CONSTRAINT fkkcajw2tb501mvh5fcfgr1oxle FOREIGN KEY (reporter_id) REFERENCES public.finding_reporter(id);


--
-- Name: finding_to_reporter fkkxoa2wlxthh5yyh8vpoeip38f; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.finding_to_reporter
    ADD CONSTRAINT fkkxoa2wlxthh5yyh8vpoeip38f FOREIGN KEY (finding_id) REFERENCES public.finding(id);


--
-- Name: datasource_dataset fkm906qfvo0q9ngge56rjxcjvw; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.datasource_dataset
    ADD CONSTRAINT fkm906qfvo0q9ngge56rjxcjvw FOREIGN KEY (datasource_id) REFERENCES public.datasource(id);


--
-- Name: package_family fkmc734oxqn8oiw87y8bqm59bqe; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_family
    ADD CONSTRAINT fkmc734oxqn8oiw87y8bqm59bqe FOREIGN KEY (dataset_metrics_id) REFERENCES public.dataset_metrics(id);


--
-- Name: package_critical_finding fkms00t455aiy6abg4q23lhk9xl; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_critical_finding
    ADD CONSTRAINT fkms00t455aiy6abg4q23lhk9xl FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: package_finding fko7b3csqgdqnu2tsqcqxekcxkb; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_finding
    ADD CONSTRAINT fko7b3csqgdqnu2tsqcqxekcxkb FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: edit fkpfldg25ff81qjvbhhltjvfffx; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.edit
    ADD CONSTRAINT fkpfldg25ff81qjvbhhltjvfffx FOREIGN KEY (dataset_metrics_id) REFERENCES public.dataset_metrics(id);


--
-- Name: package_medium_finding fks0gognebg5carp0sf8dqqaq9y; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.package_medium_finding
    ADD CONSTRAINT fks0gognebg5carp0sf8dqqaq9y FOREIGN KEY (package_id) REFERENCES public.package(id);


--
-- Name: dataset_metrics fksbpex37f81x77rq4der0dhskq; Type: FK CONSTRAINT; Schema: public; Owner: mr_data
--

ALTER TABLE ONLY public.dataset_metrics
    ADD CONSTRAINT fksbpex37f81x77rq4der0dhskq FOREIGN KEY (dataset_id) REFERENCES public.dataset(id);


--
-- PostgreSQL database dump complete
--

\unrestrict fvpBbO0BXHILXiGcGexjayIdMXXjNg90BFV7Kxv9B6m0k7felR2UcJWTFVj2zIs

