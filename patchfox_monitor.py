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

console = Console()

# Configuration
DATA_SERVICE_URL = "http://localhost:1702"
ORCHESTRATE_URL = "http://localhost:1707"
POSTGRES_HOST = "localhost"
POSTGRES_PORT = 54321
POSTGRES_DB = "mrs_db"
POSTGRES_USER = "mr_data"
POSTGRES_PASSWORD = "omnomdata"

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
        # Can't use DQ API for GROUP BY, so use direct DB connection
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
            # Get counts for each status separately using totalElements
            _, processing_count = dq_query('datasourceEvent', {'status': 'PROCESSING'})
            _, ready_count = dq_query('datasourceEvent', {'status': 'READY_FOR_PROCESSING'})
            _, ready_next_count = dq_query('datasourceEvent', {'status': 'READY_FOR_NEXT_PROCESSING'})
            _, processed_count = dq_query('datasourceEvent', {'status': 'PROCESSED'})
            _, error_count = dq_query('datasourceEvent', {'status': 'PROCESSING_ERROR'})

            # Total events = sum of all statuses
            total_job_events = processing_count + ready_count + ready_next_count + processed_count + error_count

            # Get enrichment progress counts using boolean field filters
            _, oss_done = dq_query('datasourceEvent', {
                'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING',
                'ossEnriched': 'true'
            })
            _, pkg_done = dq_query('datasourceEvent', {
                'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING',
                'packageIndexEnriched': 'true'
            })
            _, analyzed_done = dq_query('datasourceEvent', {
                'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING',
                'analyzed': 'true'
            })
            _, forecasted_done = dq_query('datasourceEvent', {
                'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING',
                'forecasted': 'true'
            })
            _, recommended_done = dq_query('datasourceEvent', {
                'status': 'PROCESSING,READY_FOR_PROCESSING,READY_FOR_NEXT_PROCESSING',
                'recommended': 'true'
            })

            # Build status counts
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
            'isCurrent': 'true'
        })

        # Sort by commitDateTime DESC to get most recent commit's metrics
        if metrics:
            metrics.sort(key=lambda x: x.get('commitDateTime', ''), reverse=True)
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

        stats = []
        for container in containers:
            # Get stats (this blocks briefly per container)
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

            # Calculate memory usage
            mem_usage = container_stats['memory_stats'].get('usage', 0)
            mem_limit = container_stats['memory_stats'].get('limit', 1)
            mem_percent = (mem_usage / mem_limit) * 100 if mem_limit > 0 else 0

            service_name = container.name.replace('docker-compose-', '').replace('-service-1', '').replace('-1', '')

            stats.append({
                'name': service_name,
                'status': container.status,
                'cpu_percent': cpu_percent,
                'mem_usage_mb': mem_usage / (1024 * 1024),
                'mem_percent': mem_percent
            })

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
    """Create comprehensive pipeline status panel"""
    if not dataset_info or 'error' in dataset_info:
        return Panel(f"⚠️  Unable to fetch dataset info: {dataset_info.get('error', 'Unknown error')}",
                    title="Pipeline Status", border_style="red")

    progress = dataset_info['progress']
    if not progress:
        return Panel("⚠️  No progress data available", title="Pipeline Status", border_style="red")

    total, oss_done, pkg_done, analyzed_done, forecasted_done, recommended_done = progress

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=25)
    table.add_column()

    # Dataset info
    status_color = {
        'READY_FOR_PROCESSING': 'yellow',
        'PROCESSING': 'blue',
        'COMPLETE': 'green',
        'ERROR': 'red'
    }.get(dataset_info['status'], 'white')

    table.add_row(
        "[ Dataset:",
        f"[bold {status_color}]{dataset_info['name']}[/] ([{status_color}]{dataset_info['status']}[/])"
    )

    # Show all active job_ids if available
    active_job_ids = dataset_info.get('active_job_ids', [])
    job_id_counts = dataset_info.get('job_id_counts', {})

    if active_job_ids:
        if len(active_job_ids) == 1:
            # Single job - show full UUID
            job_id = active_job_ids[0]
            count = job_id_counts.get(job_id, 0)
            table.add_row("Job ID:", f"[cyan]{job_id}[/] ({count:,} events)")
        else:
            # Multiple jobs - show all with counts
            table.add_row(f"Active Jobs ({len(active_job_ids)}):", "")
            for idx, job_id in enumerate(active_job_ids, 1):
                count = job_id_counts.get(job_id, 0)
                table.add_row(f"  Job {idx}:", f"[cyan]{job_id}[/]")
                table.add_row(f"    Events:", f"[yellow]{count:,}[/]")

    # Show peristalsis state
    if peristalsis_state is not None:
        peristalsis_color = "green" if peristalsis_state else "red"
        peristalsis_text = "ON" if peristalsis_state else "OFF"
        table.add_row("~ Peristalsis:", f"[{peristalsis_color}]{peristalsis_text}[/]")
    else:
        table.add_row("~ Peristalsis:", "[dim]Unknown[/]")

    # Show job duration only when actively processing
    if dataset_info['status'] == 'PROCESSING' and dataset_info.get('updated_at'):
        try:
            updated_at = parser.isoparse(dataset_info['updated_at'])
            now = datetime.now(updated_at.tzinfo)
            duration = now - updated_at

            # Format duration
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

            table.add_row("T Job Duration:", f"[yellow]{duration_str}[/]")
        except Exception as e:
            # If parsing fails, silently skip duration display
            pass

    table.add_row("", "")

    # Event status breakdown
    active_counts = dataset_info['active_event_counts']
    processing = active_counts.get('PROCESSING', 0)
    ready = active_counts.get('READY_FOR_PROCESSING', 0)
    ready_next = active_counts.get('READY_FOR_NEXT_PROCESSING', 0)
    errors = dataset_info['error_count']

    table.add_row("⚡ Processing:", f"[yellow]{processing:,}[/]")
    table.add_row("⏳ Ready:", f"[cyan]{ready:,}[/]")
    table.add_row("~ Ready Next:", f"[blue]{ready_next:,}[/]")
    table.add_row("❌ Errors:", f"[red]{errors:,}[/]")
    table.add_row("", "")

    # Total events by status
    all_counts = dataset_info['all_event_counts']
    processed = all_counts.get('PROCESSED', 0)
    total_events = dataset_info.get('total_events', 0)

    table.add_row("✅ Processed:", f"[green]{processed:,}[/]")
    table.add_row("📈 Total Events:", f"[bold cyan]{total_events:,}[/]")
    table.add_row("", "")

    # Progress bars for active processing
    if total > 0:
        oss_pct = (oss_done / total * 100)
        pkg_pct = (pkg_done / total * 100)
        analyzed_pct = (analyzed_done / total * 100)
        forecasted_pct = (forecasted_done / total * 100)
        recommended_pct = (recommended_done / total * 100)

        table.add_row(
            "🔍 OSS Enriched:",
            f"[{'green' if oss_pct == 100 else 'yellow'}]{oss_done:,}/{total:,}[/] ({oss_pct:.1f}%)"
        )
        table.add_row(
            "* Package Indexed:",
            f"[{'green' if pkg_pct == 100 else 'yellow'}]{pkg_done:,}/{total:,}[/] ({pkg_pct:.1f}%)"
        )
        table.add_row(
            "🧪 Analyzed:",
            f"[{'green' if analyzed_pct == 100 else 'yellow'}]{analyzed_done:,}/{total:,}[/] ({analyzed_pct:.1f}%)"
        )
        table.add_row(
            "🔮 Forecasted:",
            f"[{'green' if forecasted_pct == 100 else 'yellow'}]{forecasted_done:,}/{total:,}[/] ({forecasted_pct:.1f}%)"
        )
        table.add_row(
            "💡 Recommended:",
            f"[{'green' if recommended_pct == 100 else 'yellow'}]{recommended_done:,}/{total:,}[/] ({recommended_pct:.1f}%)"
        )

    return Panel(table, title="> Pipeline Status", border_style="green", box=box.ROUNDED)




def create_package_health_panel(dataset_info):
    """Create package health metrics panel with vulnerability findings"""
    if not dataset_info or 'error' in dataset_info:
        return Panel("⚠️  Unable to fetch package metrics", title="Package Health", border_style="red")

    metrics = dataset_info['package_metrics']
    total_packages, major_behind, minor_behind, patch_behind, stale_packages, packages_with_updates = metrics

    findings = dataset_info['findings']

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=25)
    table.add_column(justify="right")

    # Vulnerability findings first
    table.add_row("[bold]! Vulnerability Findings[/]", "")
    table.add_row("🔴 Critical:", f"[bold red]{findings['critical']:,}[/]")
    table.add_row("🟠 High:", f"[red]{findings['high']:,}[/]")
    table.add_row("🟡 Medium:", f"[yellow]{findings['medium']:,}[/]")
    table.add_row("🟢 Low:", f"[green]{findings['low']:,}[/]")
    table.add_row("[ Total Findings:", f"[bold cyan]{findings['total']:,}[/]")
    table.add_row("", "")
    table.add_row("", "")

    # Package health metrics
    table.add_row("[bold]* Package Health[/]", "")
    table.add_row("* Total Packages:", f"[bold cyan]{total_packages:,}[/]")
    table.add_row("", "")
    table.add_row("🔴 Major Behind:", f"[red]{major_behind:,}[/]")
    table.add_row("🟡 Minor Behind:", f"[yellow]{minor_behind:,}[/]")
    table.add_row("🟢 Patch Behind:", f"[green]{patch_behind:,}[/]")
    table.add_row("", "")
    table.add_row("T Stale (>2yr):", f"[dim]{stale_packages:,}[/]")
    table.add_row("✨ Has Updates:", f"[cyan]{packages_with_updates:,}[/]")

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
                f"[{mem_color}]{stat['mem_usage_mb']:.0f}MB ({stat['mem_percent']:.1f}%)[/]"
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
