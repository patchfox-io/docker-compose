#!/usr/bin/env python3
"""
PatchFox Pipeline Monitor
A rich TUI dashboard for monitoring PatchFox job progress
"""

import time
import psycopg2
import docker
import requests
from datetime import datetime, timedelta
from dateutil import parser
from rich.live import Live
from rich.layout import Layout
from rich.panel import Panel
from rich.table import Table
from rich.progress import Progress, BarColumn, TextColumn
from rich.console import Console
from rich.text import Text
from rich import box
from rich.columns import Columns
from rich.align import Align
import psutil
from concurrent.futures import ThreadPoolExecutor, as_completed

console = Console()

# Configuration
DATA_SERVICE_URL = "http://localhost:1702"
ORCHESTRATE_URL = "http://localhost:1707"
POSTGRES_HOST = "localhost"
POSTGRES_PORT = 54321
POSTGRES_DB = "mrs_db"
POSTGRES_USER = "mr_data"
POSTGRES_PASSWORD = "omnomdata"

# Status enums from db-entities
DATASET_STATUSES = ['INITIALIZING', 'INGESTING', 'READY_FOR_PROCESSING', 'PROCESSING', 'PROCESSING_ERROR', 'IDLE']
DATASOURCE_STATUSES = ['INITIALIZING', 'INGESTING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING', 'PROCESSING', 'PROCESSING_ERROR', 'IDLE']
DATASOURCE_EVENT_STATUSES = ['INGESTING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING', 'PROCESSING', 'PROCESSED', 'PROCESSING_ERROR']

# History tracking for sparklines
cpu_history = []
mem_history = []
events_history = []


def get_db_connection():
    """Get database connection"""
    return psycopg2.connect(
        host=POSTGRES_HOST,
        port=POSTGRES_PORT,
        database=POSTGRES_DB,
        user=POSTGRES_USER,
        password=POSTGRES_PASSWORD
    )


def dq_query(table_name, params=None):
    """Query data-service DQ API - returns (content, total_elements)"""
    try:
        url = f"{DATA_SERVICE_URL}/api/v1/db/{table_name}/query"
        # For datasourceEvent queries, exclude payload to avoid decompression overhead
        if table_name == 'datasourceEvent':
            if params is None:
                params = {}
            params['excludePayload'] = 'true'
        response = requests.get(url, params=params, timeout=5)
        response.raise_for_status()
        data = response.json()
        title_page = data.get('data', {}).get('titlePage', {})
        content = title_page.get('content', [])
        total_elements = title_page.get('totalElements', len(content))
        return content, total_elements
    except Exception as e:
        console.print(f"[red]DQ API Error ({table_name}): {e}[/red]")
        return [], 0


def create_sparkline(data, width=20, height=5):
    """Create a simple text-based sparkline"""
    if not data or len(data) < 2:
        return "─" * width

    max_val = max(data) if max(data) > 0 else 1
    min_val = min(data)
    range_val = max_val - min_val if max_val > min_val else 1

    # Unicode block characters for sparklines
    bars = [" ", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]

    # Normalize and create sparkline
    sparkline = ""
    for val in data[-width:]:
        normalized = (val - min_val) / range_val
        bar_index = int(normalized * (len(bars) - 1))
        sparkline += bars[bar_index]

    return sparkline


def get_job_info():
    """Get all active job_ids from datasource_events with their metadata"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Get all job_ids with their event counts and dataset updated_at for duration
        cur.execute("""
            SELECT 
                de.job_id,
                COUNT(*) as event_count,
                d.updated_at as last_updated,
                d.status as dataset_status
            FROM datasource_event de
            JOIN datasource ds ON ds.id = de.datasource_id
            JOIN datasource_dataset dd ON dd.datasource_id = ds.id
            JOIN dataset d ON d.id = dd.dataset_id
            WHERE de.job_id IS NOT NULL
            GROUP BY de.job_id, d.updated_at, d.status
            ORDER BY 
                CASE 
                    WHEN MIN(de.status) IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING') THEN 0
                    ELSE 1
                END,
                d.updated_at DESC
        """)
        
        jobs = []
        for row in cur.fetchall():
            job_id, event_count, last_updated, dataset_status = row
            
            # Determine job status based on dataset status and event statuses
            if dataset_status == 'IDLE':
                job_status = 'DONE'
            else:
                # Check event statuses
                cur.execute("""
                    SELECT status, COUNT(*) 
                    FROM datasource_event 
                    WHERE job_id = %s 
                    GROUP BY status
                """, (job_id,))
                
                status_counts = dict(cur.fetchall())
                
                # Job is PROCESSING if any events are processing/ready
                if any(s in status_counts for s in ['PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING']):
                    job_status = 'PROCESSING'
                elif 'PROCESSING_ERROR' in status_counts:
                    job_status = 'ERROR'
                else:
                    job_status = 'DONE'
            
            jobs.append({
                'id': job_id,
                'status': job_status,
                'updated_at': last_updated,
                'event_count': event_count,
                'dataset_status': dataset_status
            })
        
        cur.close()
        conn.close()
        
        return jobs
    except Exception as e:
        console.print(f"[red]Error fetching jobs: {e}[/red]")
        return []


def get_job_datasource_counts(job_id):
    """Get datasource status counts for a specific job's dataset"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Get the dataset_id for this job
        cur.execute("""
            SELECT DISTINCT dd.dataset_id
            FROM datasource_event de
            JOIN datasource ds ON ds.id = de.datasource_id
            JOIN datasource_dataset dd ON dd.datasource_id = ds.id
            WHERE de.job_id = %s
            LIMIT 1
        """, (job_id,))
        
        result = cur.fetchone()
        if not result:
            cur.close()
            conn.close()
            return {status: 0 for status in DATASOURCE_STATUSES}
        
        dataset_id = result[0]
        
        # Get all datasources in this dataset with their statuses
        cur.execute("""
            SELECT ds.status, COUNT(*) 
            FROM datasource ds
            JOIN datasource_dataset dd ON dd.datasource_id = ds.id
            WHERE dd.dataset_id = %s
            GROUP BY ds.status
        """, (dataset_id,))
        
        counts = {status: 0 for status in DATASOURCE_STATUSES}
        for status, count in cur.fetchall():
            counts[status] = count
        
        cur.close()
        conn.close()
        
        return counts
    except Exception as e:
        console.print(f"[red]Error fetching datasource counts: {e}[/red]")
        return {status: 0 for status in DATASOURCE_STATUSES}


def get_job_datasource_event_counts(job_id):
    """Get datasource_event status counts and enrichment flags for a specific job"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()
        
        # Status counts
        cur.execute("""
            SELECT status, COUNT(*) 
            FROM datasource_event 
            WHERE job_id = %s
            GROUP BY status
        """, (job_id,))
        
        status_counts = {status: 0 for status in DATASOURCE_EVENT_STATUSES}
        for status, count in cur.fetchall():
            status_counts[status] = count
        
        # Enrichment flag counts
        cur.execute("""
            SELECT 
                COUNT(*) as total,
                COUNT(*) FILTER (WHERE oss_enriched = true) as oss_done,
                COUNT(*) FILTER (WHERE package_index_enriched = true) as pkg_done,
                COUNT(*) FILTER (WHERE analyzed = true) as analyzed_done,
                COUNT(*) FILTER (WHERE forecasted = true) as forecasted_done,
                COUNT(*) FILTER (WHERE recommended = true) as recommended_done
            FROM datasource_event 
            WHERE job_id = %s
              AND status IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING')
        """, (job_id,))
        
        enrichment_row = cur.fetchone()
        enrichment = {
            'total': enrichment_row[0] if enrichment_row else 0,
            'oss_done': enrichment_row[1] if enrichment_row else 0,
            'pkg_done': enrichment_row[2] if enrichment_row else 0,
            'analyzed_done': enrichment_row[3] if enrichment_row else 0,
            'forecasted_done': enrichment_row[4] if enrichment_row else 0,
            'recommended_done': enrichment_row[5] if enrichment_row else 0
        }
        
        cur.close()
        conn.close()
        
        return status_counts, enrichment
    except Exception as e:
        console.print(f"[red]Error fetching datasource_event counts: {e}[/red]")
        return {status: 0 for status in DATASOURCE_EVENT_STATUSES}, {'total': 0, 'oss_done': 0, 'pkg_done': 0, 'analyzed_done': 0, 'forecasted_done': 0, 'recommended_done': 0}


def get_dataset_info():
    """Get comprehensive dataset processing status using DQ API"""
    try:
        # Get dataset info
        datasets, _ = dq_query('dataset')
        if not datasets:
            return None

        dataset = datasets[0]
        dataset_id = dataset['id']
        dataset_name = dataset['name']
        dataset_status = dataset['status']
        dataset_updated_at = dataset.get('updatedAt')

        # Query database directly for all active job IDs and their counts
        try:
            conn = get_db_connection()
            cur = conn.cursor()
            cur.execute("""
                SELECT job_id, COUNT(*) as count
                FROM datasource_event
                WHERE status IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING')
                  AND job_id IS NOT NULL
                GROUP BY job_id
                ORDER BY count DESC
            """)
            job_id_rows = cur.fetchall()
            cur.close()
            conn.close()

            job_id_counts = {row[0]: row[1] for row in job_id_rows}
            active_job_ids = [row[0] for row in job_id_rows]
        except Exception as e:
            console.print(f"[red]Error fetching job IDs: {e}[/red]")
            job_id_counts = {}
            active_job_ids = []

        if active_job_ids:
            # Parallelize all datasourceEvent queries
            queries = [
                ('processing', {'status': 'PROCESSING'}),
                ('ready', {'status': 'READY_FOR_PROCESSING'}),
                ('ready_next', {'status': 'READY_FOR_NEXT_PROCESSING'}),
                ('processed', {'status': 'PROCESSED'}),
                ('error', {'status': 'PROCESSING_ERROR'}),
                ('oss_done', {'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING', 'ossEnriched': 'true'}),
                ('pkg_done', {'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING', 'packageIndexEnriched': 'true'}),
                ('analyzed_done', {'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING', 'analyzed': 'true'}),
                ('forecasted_done', {'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING', 'forecasted': 'true'}),
                ('recommended_done', {'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING', 'recommended': 'true'}),
            ]

            results = {}
            with ThreadPoolExecutor(max_workers=10) as executor:
                future_to_key = {executor.submit(dq_query, 'datasourceEvent', params): key for key, params in queries}
                for future in as_completed(future_to_key):
                    key = future_to_key[future]
                    try:
                        _, count = future.result()
                        results[key] = count
                    except Exception as e:
                        console.print(f"[red]Error in query {key}: {e}[/red]")
                        results[key] = 0

            processing_count = results.get('processing', 0)
            ready_count = results.get('ready', 0)
            ready_next_count = results.get('ready_next', 0)
            processed_count = results.get('processed', 0)
            error_count = results.get('error', 0)
            oss_done = results.get('oss_done', 0)
            pkg_done = results.get('pkg_done', 0)
            analyzed_done = results.get('analyzed_done', 0)
            forecasted_done = results.get('forecasted_done', 0)
            recommended_done = results.get('recommended_done', 0)

            total_job_events = processing_count + ready_count + ready_next_count + processed_count + error_count

            active_event_counts = {
                'PROCESSING': processing_count,
                'READY_FOR_PROCESSING': ready_count,
                'READY_FOR_NEXT_PROCESSING': ready_next_count,
                'PROCESSING_ERROR': error_count
            }
            all_event_counts = {
                'PROCESSING': processing_count,
                'READY_FOR_PROCESSING': ready_count,
                'READY_FOR_NEXT_PROCESSING': ready_next_count,
                'PROCESSED': processed_count,
                'PROCESSING_ERROR': error_count
            }

            total_active = processing_count + ready_count + ready_next_count
            progress = (total_active, oss_done, pkg_done, analyzed_done, forecasted_done, recommended_done)
        else:
            active_job_ids = []
            job_id_counts = {}
            active_event_counts = {}
            all_event_counts = {}
            total_job_events = 0
            progress = (0, 0, 0, 0, 0, 0)
            error_count = 0

        # Get datasource count
        datasources, total_datasources = dq_query('datasource')
        datasource_count = total_datasources

        # Get findings and package metrics from latest dataset_metrics snapshot
        metrics, _ = dq_query('datasetMetrics', {
            'isCurrent': 'true',
            'sort': 'commitDateTime.desc',
            'size': '1'
        })

        # Get most recent commit's metrics
        # Get most recent commit's metrics
        if metrics:
            metrics_row = metrics[0]
        else:
            metrics_row = None

        if metrics_row:
            critical_finding_count = metrics_row.get('criticalFindings') or 0
            high_finding_count = metrics_row.get('highFindings') or 0
            medium_finding_count = metrics_row.get('mediumFindings') or 0
            low_finding_count = metrics_row.get('lowFindings') or 0
            total_findings = metrics_row.get('totalFindings') or 0
            package_count = metrics_row.get('packages') or 0
            packages_with_findings = metrics_row.get('packagesWithFindings') or 0
            major_behind = metrics_row.get('downlevelPackagesMajor') or 0
            minor_behind = metrics_row.get('downlevelPackagesMinor') or 0
            patch_behind = metrics_row.get('downlevelPackagesPatch') or 0
            stale_packages = metrics_row.get('stalePackagesTwoYears') or 0
            packages_with_updates = package_count - major_behind - minor_behind - patch_behind
            rps_score = metrics_row.get('rpsScore')
            pes_score = metrics_row.get('patchEfficacyScore')
            package_metrics = (package_count, major_behind, minor_behind, patch_behind, stale_packages, packages_with_updates)
            
            # Extract backlog metrics
            backlog_30_60 = metrics_row.get('findingsInBacklogBetweenThirtyAndSixtyDays') or 0
            backlog_60_90 = metrics_row.get('findingsInBacklogBetweenSixtyAndNinetyDays') or 0
            backlog_90_plus = metrics_row.get('findingsInBacklogOverNinetyDays') or 0
            
            critical_backlog_30_60 = metrics_row.get('criticalFindingsInBacklogBetweenThirtyAndSixtyDays') or 0
            critical_backlog_60_90 = metrics_row.get('criticalFindingsInBacklogBetweenSixtyAndNinetyDays') or 0
            critical_backlog_90_plus = metrics_row.get('criticalFindingsInBacklogOverNinetyDays') or 0
            
            high_backlog_30_60 = metrics_row.get('highFindingsInBacklogBetweenThirtyAndSixtyDays') or 0
            high_backlog_60_90 = metrics_row.get('highFindingsInBacklogBetweenSixtyAndNinetyDays') or 0
            high_backlog_90_plus = metrics_row.get('highFindingsInBacklogOverNinetyDays') or 0
            
            medium_backlog_30_60 = metrics_row.get('mediumFindingsInBacklogBetweenThirtyAndSixtyDays') or 0
            medium_backlog_60_90 = metrics_row.get('mediumFindingsInBacklogBetweenSixtyAndNinetyDays') or 0
            medium_backlog_90_plus = metrics_row.get('mediumFindingsInBacklogOverNinetyDays') or 0
            
            low_backlog_30_60 = metrics_row.get('lowFindingsInBacklogBetweenThirtyAndSixtyDays') or 0
            low_backlog_60_90 = metrics_row.get('lowFindingsInBacklogBetweenSixtyAndNinetyDays') or 0
            low_backlog_90_plus = metrics_row.get('lowFindingsInBacklogOverNinetyDays') or 0
            
            finding_backlog = {
                'total': backlog_30_60 + backlog_60_90 + backlog_90_plus,
                'critical': critical_backlog_30_60 + critical_backlog_60_90 + critical_backlog_90_plus,
                'high': high_backlog_30_60 + high_backlog_60_90 + high_backlog_90_plus,
                'medium': medium_backlog_30_60 + medium_backlog_60_90 + medium_backlog_90_plus,
                'low': low_backlog_30_60 + low_backlog_60_90 + low_backlog_90_plus
            }
            
            # Get package types from package_indexes
            try:
                conn = get_db_connection()
                cur = conn.cursor()
                cur.execute("""
                    WITH latest_metrics AS (
                        SELECT package_indexes
                        FROM dataset_metrics 
                        WHERE is_current = true
                        ORDER BY commit_date_time DESC 
                        LIMIT 1
                    )
                    SELECT p.type, COUNT(*) as count
                    FROM latest_metrics,
                         unnest(package_indexes) AS package_id
                    JOIN package p ON p.id = package_id
                    GROUP BY p.type
                    ORDER BY count DESC
                """)
                package_types = {row[0]: row[1] for row in cur.fetchall()}
                cur.close()
                conn.close()
            except Exception as e:
                console.print(f"[red]Error fetching package types: {e}[/red]")
                package_types = {}
            
            # Get finding instances (not just types) by unnesting package_indexes
            try:
                conn = get_db_connection()
                cur = conn.cursor()
                cur.execute("""
                    WITH latest_metrics AS (
                        SELECT package_indexes
                        FROM dataset_metrics 
                        WHERE is_current = true
                        ORDER BY commit_date_time DESC 
                        LIMIT 1
                    )
                    SELECT 
                        COUNT(f.id) as total,
                        COUNT(f.id) FILTER (WHERE fd.severity = 'CRITICAL') as critical,
                        COUNT(f.id) FILTER (WHERE fd.severity = 'HIGH') as high,
                        COUNT(f.id) FILTER (WHERE fd.severity = 'MEDIUM') as medium,
                        COUNT(f.id) FILTER (WHERE fd.severity = 'LOW') as low
                    FROM latest_metrics,
                         unnest(package_indexes) AS package_id
                    JOIN package p ON p.id = package_id
                    JOIN package_finding pf ON pf.package_id = p.id
                    JOIN finding f ON f.id = pf.finding_id
                    JOIN finding_data fd ON fd.finding_id = f.id
                """)
                instance_row = cur.fetchone()
                cur.close()
                conn.close()
                
                if instance_row:
                    finding_instances = {
                        'total': instance_row[0] or 0,
                        'critical': instance_row[1] or 0,
                        'high': instance_row[2] or 0,
                        'medium': instance_row[3] or 0,
                        'low': instance_row[4] or 0
                    }
                else:
                    finding_instances = {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
            except Exception as e:
                console.print(f"[red]Error fetching finding instances: {e}[/red]")
                finding_instances = {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
        else:
            # Fallback if no dataset_metrics exist
            critical_finding_count = 0
            high_finding_count = 0
            medium_finding_count = 0
            low_finding_count = 0
            total_findings = 0
            package_count = 0
            packages_with_findings = 0
            rps_score = None
            pes_score = None
            package_metrics = (0, 0, 0, 0, 0, 0)
            finding_instances = {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
            finding_backlog = {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0}
            package_types = {}

        return {
            'id': dataset_id,
            'name': dataset_name,
            'status': dataset_status,
            'updated_at': dataset_updated_at,
            'active_job_ids': active_job_ids,
            'job_id_counts': job_id_counts,
            'active_event_counts': active_event_counts,
            'all_event_counts': all_event_counts,
            'total_events': total_job_events,
            'progress': progress,
            'error_count': error_count,
            'datasource_count': datasource_count,
            'package_count': package_count,
            'findings': {
                'total': total_findings,
                'critical': critical_finding_count,
                'high': high_finding_count,
                'medium': medium_finding_count,
                'low': low_finding_count
            },
            'finding_instances': finding_instances,
            'finding_backlog': finding_backlog,
            'package_types': package_types,
            'package_metrics': package_metrics,
            'rps_score': rps_score,
            'pes_score': pes_score
        }
    except Exception as e:
        return {'error': str(e)}


def get_peristalsis_state():
    """Get peristalsis (orchestrate) activation state"""
    try:
        url = f"{ORCHESTRATE_URL}/api/v1/peristalsis"
        response = requests.get(url, timeout=5)
        response.raise_for_status()
        data = response.json()
        return data.get('data', {}).get('activated', False)
    except Exception as e:
        console.print(f"[red]Peristalsis API Error: {e}[/red]")
        return None


def get_postgres_stats():
    """Get postgres connection and query stats"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        # Get connections grouped by application and state
        cur.execute("""
            SELECT
                COALESCE(application_name, 'unknown') as app_name,
                state,
                count(*)
            FROM pg_stat_activity
            WHERE datname = 'mrs_db'
            GROUP BY application_name, state
            ORDER BY application_name, state;
        """)
        conn_by_app = cur.fetchall()

        cur.execute("""
            SELECT COUNT(*)
            FROM pg_stat_activity
            WHERE datname = 'mrs_db' AND state = 'active' AND pid <> pg_backend_pid();
        """)
        active_queries = cur.fetchone()[0]

        cur.close()
        conn.close()

        return {
            'conn_by_app': conn_by_app,
            'active_queries': active_queries
        }
    except Exception as e:
        return {'error': str(e)}


def get_container_stats():
    """Get docker container stats"""
    try:
        client = docker.from_env()
        containers = client.containers.list()

        def get_single_container_stats(container):
            """Get stats for a single container"""
            try:
                # Call stats twice - first call often returns stale data
                container.stats(stream=False)
                container_stats = container.stats(stream=False)

                # Calculate CPU percentage
                cpu_delta = container_stats['cpu_stats']['cpu_usage']['total_usage'] - \
                           container_stats['precpu_stats']['cpu_usage']['total_usage']
                system_delta = container_stats['cpu_stats']['system_cpu_usage'] - \
                              container_stats['precpu_stats']['system_cpu_usage']
                cpu_percent = 0.0
                if system_delta > 0 and cpu_delta > 0:
                    num_cpus = container_stats['cpu_stats'].get('online_cpus')
                    if not num_cpus:
                        num_cpus = len(container_stats['cpu_stats']['cpu_usage'].get('percpu_usage', []))
                    if num_cpus == 0:
                        num_cpus = 1
                    cpu_percent = (cpu_delta / system_delta) * num_cpus * 100

                # Calculate memory usage (exclude page cache like docker stats does)
                mem_usage = container_stats['memory_stats'].get('usage', 0)
                mem_stats = container_stats['memory_stats'].get('stats', {})
                # Subtract inactive file cache to match docker stats display
                inactive_file = mem_stats.get('inactive_file', 0)
                mem_usage_actual = mem_usage - inactive_file
                mem_limit = container_stats['memory_stats'].get('limit', 1)
                mem_percent = (mem_usage_actual / mem_limit) * 100 if mem_limit > 0 else 0

                service_name = container.name.replace('docker-compose-', '').replace('-service-1', '').replace('-1', '')

                return {
                    'name': service_name,
                    'status': container.status,
                    'cpu_percent': cpu_percent,
                    'mem_usage_mb': mem_usage_actual / (1024 * 1024),
                    'mem_percent': mem_percent
                }
            except Exception as e:
                return {'name': container.name, 'error': str(e)}

        # Parallelize container stats collection
        stats = []
        with ThreadPoolExecutor(max_workers=len(containers)) as executor:
            futures = [executor.submit(get_single_container_stats, c) for c in containers]
            for future in as_completed(futures):
                try:
                    stats.append(future.result())
                except Exception as e:
                    console.print(f"[red]Error getting container stats: {e}[/red]")

        return stats
    except Exception as e:
        return [{'error': str(e)}]


def get_host_stats():
    """Get host system stats"""
    try:
        cpu_percent = psutil.cpu_percent(interval=0.1)
        mem = psutil.virtual_memory()
        disk = psutil.disk_usage('/')

        # Track history for sparklines
        cpu_history.append(cpu_percent)
        mem_history.append(mem.percent)
        if len(cpu_history) > 50:
            cpu_history.pop(0)
        if len(mem_history) > 50:
            mem_history.pop(0)

        return {
            'cpu_percent': cpu_percent,
            'mem_percent': mem.percent,
            'mem_available_gb': mem.available / (1024**3),
            'disk_percent': disk.percent,
            'disk_free_gb': disk.free / (1024**3),
            'cpu_sparkline': create_sparkline(cpu_history),
            'mem_sparkline': create_sparkline(mem_history)
        }
    except Exception as e:
        return {'error': str(e)}


def create_pipeline_status_panel(dataset_info, peristalsis_state=None):
    """Create comprehensive pipeline status panel organized by jobs"""
    if not dataset_info or 'error' in dataset_info:
        return Panel(f"⚠️  Unable to fetch dataset info: {dataset_info.get('error', 'Unknown error')}",
                    title="Pipeline Status", border_style="red")

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=30)
    table.add_column()

    # ===== ORCHESTRATE SECTION =====
    table.add_row("[bold yellow]═══ ORCHESTRATE ═══[/]", "")
    if peristalsis_state is not None:
        peristalsis_color = "green" if peristalsis_state else "red"
        peristalsis_text = "ON" if peristalsis_state else "OFF"
        table.add_row("  Peristalsis:", f"[{peristalsis_color}]{peristalsis_text}[/]")
    else:
        table.add_row("  Peristalsis:", "[dim]Unknown[/]")
    table.add_row("", "")

    # Get all jobs
    jobs = get_job_info()
    
    if not jobs:
        table.add_row("[dim]No active jobs[/]", "")
        return Panel(table, title="> Pipeline Status", border_style="green", box=box.ROUNDED)

    # ===== JOB SECTIONS =====
    for idx, job in enumerate(jobs):
        job_id = job['id']
        job_status = job['status']
        updated_at = job['updated_at']
        
        # Job header
        job_status_color = "yellow" if job_status == 'PROCESSING' else "green" if job_status == 'IDLE' else "cyan"
        table.add_row(f"[bold {job_status_color}]═══ JOB {idx + 1} - {job_status} ═══[/]", "")
        
        # Job Status subsection
        table.add_row("  [bold]Job Status:[/]", "")
        table.add_row("    Job ID:", f"[cyan]{job_id}[/]")
        
        # Job duration
        if updated_at:
            try:
                now = datetime.now(updated_at.tzinfo) if updated_at.tzinfo else datetime.now()
                duration = now - updated_at
                total_seconds = int(duration.total_seconds())
                hours = total_seconds // 3600
                minutes = (total_seconds % 3600) // 60
                seconds = total_seconds % 60
                
                if hours > 0:
                    duration_str = f"{hours}h {minutes}m {seconds}s"
                elif minutes > 0:
                    duration_str = f"{minutes}m {seconds}s"
                else:
                    duration_str = f"{seconds}s"
                
                table.add_row("    Duration:", f"[yellow]{duration_str}[/]")
            except:
                pass
        
        table.add_row("", "")
        
        # Dataset subsection
        table.add_row("  [bold]Dataset:[/]", "")
        dataset_status = job.get('dataset_status', dataset_info['status'])
        dataset_status_color = {
            'READY_FOR_PROCESSING': 'yellow',
            'PROCESSING': 'blue',
            'IDLE': 'green',
            'ERROR': 'red'
        }.get(dataset_status, 'white')
        table.add_row("    Name:", f"[bold]{dataset_info['name']}[/]")
        table.add_row("    Status:", f"[{dataset_status_color}]{dataset_status}[/]")
        table.add_row("", "")
        
        # Datasources subsection
        table.add_row("  [bold]Datasources:[/]", "")
        datasource_counts = get_job_datasource_counts(job_id)
        for status in DATASOURCE_STATUSES:
            count = datasource_counts.get(status, 0)
            status_color = "yellow" if status == 'PROCESSING' else "cyan" if 'READY' in status else "red" if 'ERROR' in status else "green"
            table.add_row(f"    {status}:", f"[{status_color}]{count:,}[/]")
        table.add_row("", "")
        
        # Datasource Events subsection
        table.add_row("  [bold]Datasource Events:[/]", "")
        event_counts, enrichment = get_job_datasource_event_counts(job_id)
        
        # Status breakdown
        for status in DATASOURCE_EVENT_STATUSES:
            count = event_counts.get(status, 0)
            status_color = "yellow" if status == 'PROCESSING' else "cyan" if 'READY' in status else "green" if status == 'PROCESSED' else "red"
            table.add_row(f"    {status}:", f"[{status_color}]{count:,}[/]")
        
        table.add_row("", "")
        
        # Enrichment progress
        total = enrichment['total']
        if total > 0:
            oss_done = enrichment['oss_done']
            pkg_done = enrichment['pkg_done']
            analyzed_done = enrichment['analyzed_done']
            forecasted_done = enrichment['forecasted_done']
            recommended_done = enrichment['recommended_done']
            
            oss_pct = (oss_done / total * 100)
            pkg_pct = (pkg_done / total * 100)
            analyzed_pct = (analyzed_done / total * 100)
            forecasted_pct = (forecasted_done / total * 100)
            recommended_pct = (recommended_done / total * 100)
            
            table.add_row(
                "    🔍 OSS Enriched:",
                f"[{'green' if oss_pct == 100 else 'yellow'}]{oss_done:,}/{total:,}[/] ({oss_pct:.1f}%)"
            )
            table.add_row(
                "    📦 Package Indexed:",
                f"[{'green' if pkg_pct == 100 else 'yellow'}]{pkg_done:,}/{total:,}[/] ({pkg_pct:.1f}%)"
            )
            table.add_row(
                "    🧪 Analyzed:",
                f"[{'green' if analyzed_pct == 100 else 'yellow'}]{analyzed_done:,}/{total:,}[/] ({analyzed_pct:.1f}%)"
            )
            table.add_row(
                "    🔮 Forecasted:",
                f"[{'green' if forecasted_pct == 100 else 'yellow'}]{forecasted_done:,}/{total:,}[/] ({forecasted_pct:.1f}%)"
            )
            table.add_row(
                "    💡 Recommended:",
                f"[{'green' if recommended_pct == 100 else 'yellow'}]{recommended_done:,}/{total:,}[/] ({recommended_pct:.1f}%)"
            )
        
        # Add spacing between jobs
        if idx < len(jobs) - 1:
            table.add_row("", "")

    return Panel(table, title="> Pipeline Status", border_style="green", box=box.ROUNDED)




def create_package_health_panel(dataset_info):
    """Create package health metrics panel with vulnerability findings"""
    if not dataset_info or 'error' in dataset_info:
        return Panel("⚠️  Unable to fetch package metrics", title="Package Health", border_style="red")

    metrics = dataset_info['package_metrics']
    total_packages, major_behind, minor_behind, patch_behind, stale_packages, packages_with_updates = metrics

    findings = dataset_info['findings']
    finding_instances = dataset_info.get('finding_instances', {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0})
    finding_backlog = dataset_info.get('finding_backlog', {'total': 0, 'critical': 0, 'high': 0, 'medium': 0, 'low': 0})
    package_types = dataset_info.get('package_types', {})

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=25)
    table.add_column(justify="right", width=12)
    table.add_column(justify="right", width=12)
    table.add_column(justify="right", width=12)

    # FINDINGS SECTION
    table.add_row("[bold yellow]═══ FINDINGS ═══[/]", "", "", "")
    table.add_row("", "", "", "")
    
    # Column headers
    table.add_row("", "[bold cyan]By Type[/]", "[bold cyan]By Instance[/]", "[bold cyan]Backlog[/]")
    table.add_row("🔴 Critical:", f"[bold red]{findings['critical']:,}[/]", f"[bold red]{finding_instances['critical']:,}[/]", f"[bold red]{int(finding_backlog['critical']):,}[/]")
    table.add_row("🟠 High:", f"[red]{findings['high']:,}[/]", f"[red]{finding_instances['high']:,}[/]", f"[red]{int(finding_backlog['high']):,}[/]")
    table.add_row("🟡 Medium:", f"[yellow]{findings['medium']:,}[/]", f"[yellow]{finding_instances['medium']:,}[/]", f"[yellow]{int(finding_backlog['medium']):,}[/]")
    table.add_row("🟢 Low:", f"[green]{findings['low']:,}[/]", f"[green]{finding_instances['low']:,}[/]", f"[green]{int(finding_backlog['low']):,}[/]")
    table.add_row("[ Total:", f"[bold cyan]{findings['total']:,}[/]", f"[bold cyan]{finding_instances['total']:,}[/]", f"[bold cyan]{int(finding_backlog['total']):,}[/]")
    table.add_row("", "", "", "")
    table.add_row("", "", "", "")

    # PACKAGES SECTION
    table.add_row("[bold yellow]═══ PACKAGES ═══[/]", "", "", "")
    table.add_row("", "", "", "")
    
    # Total packages first
    table.add_row("* Total Packages:", f"[bold cyan]{total_packages:,}[/]", "", "")
    table.add_row("", "", "", "")
    
    # Get package types sorted by count
    sorted_types = sorted(package_types.items(), key=lambda x: x[1], reverse=True)
    
    # Show package types in left column
    for pkg_type, pkg_count in sorted_types:
        table.add_row(f"  {pkg_type}:", f"[cyan]{pkg_count:,}[/]", "", "")
    
    table.add_row("", "", "", "")
    
    # Health metrics in left column
    table.add_row("🔴 Major Behind:", f"[red]{major_behind:,}[/]", "", "")
    table.add_row("🟡 Minor Behind:", f"[yellow]{minor_behind:,}[/]", "", "")
    table.add_row("🟢 Patch Behind:", f"[green]{patch_behind:,}[/]", "", "")
    table.add_row("", "", "", "")
    table.add_row("T Stale (>2yr):", f"[dim]{stale_packages:,}[/]", "", "")
    table.add_row("✨ Has Updates:", f"[cyan]{packages_with_updates:,}[/]", "", "")

    # Add RPS and PES scores
    table.add_row("", "")
    rps = dataset_info.get('rps_score')
    pes = dataset_info.get('pes_score')

    if rps is not None:
        rps_color = 'green' if rps >= 70 else 'yellow' if rps >= 40 else 'red'
        table.add_row("📊 RPS Score:", f"[{rps_color}]{rps:.1f}[/]")
    else:
        table.add_row("📊 RPS Score:", "[dim]N/A[/]")

    if pes is not None:
        pes_color = 'green' if pes >= 70 else 'yellow' if pes >= 40 else 'red'
        table.add_row("📊 PES Score:", f"[{pes_color}]{pes:.1f}[/]")
    else:
        table.add_row("📊 PES Score:", "[dim]N/A[/]")

    # Calculate percentage downlevel
    if total_packages > 0:
        downlevel_pct = ((major_behind + minor_behind + patch_behind) / total_packages) * 100
        table.add_row("", "")
        table.add_row("📉 Downlevel %:", f"[{'red' if downlevel_pct > 50 else 'yellow' if downlevel_pct > 25 else 'green'}]{downlevel_pct:.1f}%[/]")

    return Panel(table, title="[ Dataset Metrics", border_style="yellow", box=box.ROUNDED)




def create_containers_panel(container_stats):
    """Create container stats panel"""
    table = Table(box=box.SIMPLE, show_header=True, header_style="bold cyan")
    table.add_column("Service", style="cyan", width=20)
    table.add_column("Status", style="green", width=12)
    table.add_column("CPU %", justify="right", width=10)
    table.add_column("Memory", justify="right", width=20)

    if container_stats and 'error' not in container_stats[0]:
        for stat in sorted(container_stats, key=lambda x: x['name']):
            status_emoji = "✅" if stat['status'] == 'running' else "❌"

            cpu_color = "green" if stat['cpu_percent'] < 50 else "yellow" if stat['cpu_percent'] < 80 else "red"
            mem_color = "green" if stat['mem_percent'] < 50 else "yellow" if stat['mem_percent'] < 80 else "red"

            table.add_row(
                stat['name'],
                f"{status_emoji} {stat['status']}",
                f"[{cpu_color}]{stat['cpu_percent']:.1f}%[/]",
                f"[{mem_color}]{stat['mem_usage_mb']:,.0f}MB ({stat['mem_percent']:.1f}%)[/]"
            )
    else:
        error_msg = container_stats[0].get('error', 'Unknown error') if container_stats else 'No stats'
        table.add_row(f"Error: {error_msg}", "", "", "")

    return Panel(table, title="D Container Stats", border_style="blue", box=box.ROUNDED)


def create_postgres_panel(pg_stats):
    """Create postgres stats panel"""
    if 'error' in pg_stats:
        return Panel(f"[red]Error: {pg_stats['error']}[/]", title="P PostgreSQL", border_style="red")

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=15)
    table.add_column(justify="right")

    conn_by_app = pg_stats.get('conn_by_app', [])

    # Group connections by state, aggregating by service
    state_totals = {}
    state_services = {}

    for app_name, state, count in conn_by_app:
        # Aggregate by state total
        state_totals[state] = state_totals.get(state, 0) + count

        # Track service breakdown
        if state not in state_services:
            state_services[state] = {}
        short_name = app_name.replace('-service', '').replace('analyze', 'anl').replace('orchestrate', 'orch').replace('unknown', 'unk')
        state_services[state][short_name] = state_services[state].get(short_name, 0) + count

    # Display each state with app breakdown
    for state in ['active', 'idle', 'idle in transaction']:
        state_label = state.replace('active', 'Active').replace('idle', 'Idle').replace('idle in transaction', 'Idle in TX')
        state_color = 'yellow' if state == 'active' else 'red' if 'transaction' in state else 'green'

        if state in state_totals:
            # Show breakdown for active and idle in transaction, but not idle
            if state == 'idle':
                table.add_row(f"{state_label}:", f"[{state_color}]{state_totals[state]}[/]")
            else:
                breakdown = ', '.join([f"{svc}:{cnt}" for svc, cnt in sorted(state_services[state].items())])
                table.add_row(f"{state_label}:", f"[{state_color}]{state_totals[state]}[/] [dim]({breakdown})[/]")
        else:
            table.add_row(f"{state_label}:", "[dim]0[/]")

    table.add_row("", "")
    table.add_row("Active Queries:", f"[cyan]{pg_stats.get('active_queries', 0)}[/]")

    return Panel(table, title="P PostgreSQL", border_style="magenta", box=box.ROUNDED)


def create_host_panel(host_stats):
    """Create host system stats panel with sparklines"""
    if 'error' in host_stats:
        return Panel(f"⚠️  {host_stats['error']}", title="Host System", border_style="red")

    table = Table.grid(padding=(0, 1))
    table.add_column(style="cyan", width=15)
    table.add_column(width=10, justify="right")
    table.add_column(width=25)

    cpu_color = "green" if host_stats['cpu_percent'] < 50 else "yellow" if host_stats['cpu_percent'] < 80 else "red"
    mem_color = "green" if host_stats['mem_percent'] < 50 else "yellow" if host_stats['mem_percent'] < 80 else "red"
    disk_color = "green" if host_stats['disk_percent'] < 50 else "yellow" if host_stats['disk_percent'] < 80 else "red"

    table.add_row(
        "CPU CPU:",
        f"[{cpu_color}]{host_stats['cpu_percent']:.1f}%[/]",
        f"[dim]{host_stats['cpu_sparkline']}[/]"
    )
    table.add_row(
        "MEM Memory:",
        f"[{mem_color}]{host_stats['mem_percent']:.1f}%[/]",
        f"[dim]{host_stats['mem_sparkline']}[/]"
    )
    table.add_row(
        "DSK Disk:",
        f"[{disk_color}]{host_stats['disk_percent']:.1f}%[/]",
        f"[dim]{host_stats['disk_free_gb']:.1f}GB free[/]"
    )

    return Panel(table, title="H  Host System", border_style="cyan", box=box.ROUNDED)


def create_dashboard(next_refresh_in, dataset_info=None, container_stats=None, pg_stats=None, host_stats=None, peristalsis_state=None, updating=False):
    """Create the main dashboard layout"""
    # Only fetch data if not provided (i.e., on actual refresh)
    if dataset_info is None:
        dataset_info = get_dataset_info()
    if container_stats is None:
        container_stats = get_container_stats()
    if pg_stats is None:
        pg_stats = get_postgres_stats()
    if host_stats is None:
        host_stats = get_host_stats()
    if peristalsis_state is None:
        peristalsis_state = get_peristalsis_state()

    layout = Layout()

    # Main structure
    layout.split_column(
        Layout(name="header", size=3),
        Layout(name="main"),
        Layout(name="footer", size=1)
    )

    # Split main into columns (all equal width)
    layout["main"].split_row(
        Layout(name="left", ratio=1),
        Layout(name="middle", ratio=1),
        Layout(name="right", ratio=1)
    )

    # Create countdown display or updating message
    if updating:
        countdown = f"[bold yellow blink]** UPDATING **[/]"
    else:
        seconds = int(next_refresh_in)
        milliseconds = int((next_refresh_in - seconds) * 1000)
        countdown = f"[bold cyan]NEXT UPDATE IN: {seconds}.{milliseconds:03d}s[/]"

    # Update all panels
    layout["header"].update(
        Panel(
            Align.center(
                Text.from_markup(f"[bold magenta]PATCHFOX PIPELINE MONITOR[/bold magenta]  |  {countdown}"),
                vertical="middle"
            ),
            border_style="magenta",
            box=box.HEAVY
        )
    )

    # Left column
    layout["left"].update(create_pipeline_status_panel(dataset_info, peristalsis_state))

    # Middle column
    layout["middle"].update(create_package_health_panel(dataset_info))

    # Right column
    layout["right"].split_column(
        Layout(name="containers"),
        Layout(name="postgres", size=10),
        Layout(name="host", size=8)
    )

    layout["containers"].update(create_containers_panel(container_stats))
    layout["postgres"].update(create_postgres_panel(pg_stats))
    layout["host"].update(create_host_panel(host_stats))

    layout["footer"].update(
        Panel(
            Text(f"T {datetime.now().strftime('%Y-%m-%d %H:%M:%S')} | ~ Refresh in {next_refresh_in:.1f}s | Press Ctrl+C to exit",
                 style="dim", justify="center"),
            border_style="dim"
        )
    )

    return layout


def main():
    """Main function"""
    console.print("\n[bold magenta]Starting PatchFox Monitor...[/bold magenta]\n")

    try:
        refresh_interval = 2.0  # seconds
        update_rate = 10  # updates per second for smooth countdown

        # Fetch initial data
        dataset_info = get_dataset_info()
        container_stats = get_container_stats()
        pg_stats = get_postgres_stats()
        host_stats = get_host_stats()
        peristalsis_state = get_peristalsis_state()

        with Live(create_dashboard(refresh_interval, dataset_info, container_stats, pg_stats, host_stats, peristalsis_state, updating=False),
                  refresh_per_second=update_rate, console=console, screen=True) as live:
            while True:
                start_time = time.time()

                # Update countdown every 0.1 seconds WITHOUT fetching new data
                while time.time() - start_time < refresh_interval:
                    elapsed = time.time() - start_time
                    remaining = refresh_interval - elapsed
                    live.update(create_dashboard(remaining, dataset_info, container_stats, pg_stats, host_stats, peristalsis_state, updating=False))
                    time.sleep(0.1)

                # Show UPDATING message
                live.update(create_dashboard(0, dataset_info, container_stats, pg_stats, host_stats, peristalsis_state, updating=True))

                # Fetch fresh data after countdown completes
                dataset_info = get_dataset_info()
                container_stats = get_container_stats()
                pg_stats = get_postgres_stats()
                host_stats = get_host_stats()
                peristalsis_state = get_peristalsis_state()

                # Display with refreshed data and reset timer to full interval
                live.update(create_dashboard(refresh_interval, dataset_info, container_stats, pg_stats, host_stats, peristalsis_state, updating=False))

    except KeyboardInterrupt:
        console.print("\n\n[bold yellow]👋 Shutting down monitor...[/bold yellow]\n")


if __name__ == "__main__":
    main()
