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
POSTGRES_HOST = "localhost"
POSTGRES_PORT = 54321
POSTGRES_DB = "mrs_db"
POSTGRES_USER = "mr_data"
POSTGRES_PASSWORD = "omnomdata"

ORCHESTRATE_URL = "http://localhost:1707"

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
    """Get comprehensive dataset processing status"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        # Get dataset info
        cur.execute("SELECT id, name, status FROM dataset LIMIT 1;")
        dataset = cur.fetchone()

        if not dataset:
            return None

        dataset_id, dataset_name, dataset_status = dataset

        # Get active job_id (most common job_id among currently processing events)
        cur.execute("""
            SELECT job_id, COUNT(*) as cnt
            FROM datasource_event
            WHERE status IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING')
              AND job_id IS NOT NULL
            GROUP BY job_id
            ORDER BY cnt DESC
            LIMIT 1;
        """)
        job_result = cur.fetchone()
        active_job_id = job_result[0] if job_result else None

        # Get event counts by status (only active processing states)
        cur.execute("""
            SELECT status, COUNT(*)
            FROM datasource_event
            WHERE status IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING', 'PROCESSING_ERROR')
            GROUP BY status;
        """)
        active_event_counts = dict(cur.fetchall())

        # Get total event counts
        cur.execute("""
            SELECT status, COUNT(*)
            FROM datasource_event
            GROUP BY status;
        """)
        all_event_counts = dict(cur.fetchall())

        # Get enrichment progress (only for active events)
        cur.execute("""
            SELECT
                COUNT(*) as total,
                SUM(CASE WHEN oss_enriched = true THEN 1 ELSE 0 END) as oss_done,
                SUM(CASE WHEN package_index_enriched = true THEN 1 ELSE 0 END) as pkg_done,
                SUM(CASE WHEN analyzed = true THEN 1 ELSE 0 END) as analyzed_done,
                SUM(CASE WHEN forecasted = true THEN 1 ELSE 0 END) as forecasted_done,
                SUM(CASE WHEN recommended = true THEN 1 ELSE 0 END) as recommended_done
            FROM datasource_event
            WHERE status IN ('PROCESSING', 'READY_FOR_PROCESSING', 'READY_FOR_NEXT_PROCESSING');
        """)
        progress = cur.fetchone()

        # Get error count
        cur.execute("SELECT COUNT(*) FROM datasource_event WHERE status = 'PROCESSING_ERROR' OR processing_error IS NOT NULL;")
        error_count = cur.fetchone()[0]

        # Get record counts
        cur.execute("SELECT COUNT(*) FROM datasource;")
        datasource_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM package;")
        package_count = cur.fetchone()[0]

        # Get finding counts by severity
        cur.execute("SELECT COUNT(DISTINCT package_id) FROM package_critical_finding;")
        critical_finding_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(DISTINCT package_id) FROM package_high_finding;")
        high_finding_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(DISTINCT package_id) FROM package_medium_finding;")
        medium_finding_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(DISTINCT package_id) FROM package_low_finding;")
        low_finding_count = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM finding;")
        total_findings = cur.fetchone()[0]

        # Get package health metrics
        cur.execute("""
            SELECT
                COUNT(*) as total_packages,
                COUNT(CASE WHEN number_major_versions_behind_head > 0 THEN 1 END) as major_behind,
                COUNT(CASE WHEN number_minor_versions_behind_head > 0 THEN 1 END) as minor_behind,
                COUNT(CASE WHEN number_patch_versions_behind_head > 0 THEN 1 END) as patch_behind,
                COUNT(CASE WHEN this_version_published_at < NOW() - INTERVAL '2 years' THEN 1 END) as stale_packages,
                COUNT(CASE WHEN most_recent_version_published_at IS NOT NULL THEN 1 END) as packages_with_updates
            FROM package;
        """)
        package_metrics = cur.fetchone()

        cur.close()
        conn.close()

        return {
            'id': dataset_id,
            'name': dataset_name,
            'status': dataset_status,
            'active_job_id': active_job_id,
            'active_event_counts': active_event_counts,
            'all_event_counts': all_event_counts,
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
            'package_metrics': package_metrics
        }
    except Exception as e:
        return {'error': str(e)}


def get_postgres_stats():
    """Get postgres connection and query stats"""
    try:
        conn = get_db_connection()
        cur = conn.cursor()

        cur.execute("""
            SELECT state, count(*)
            FROM pg_stat_activity
            WHERE datname = 'mrs_db'
            GROUP BY state;
        """)
        conn_stats = dict(cur.fetchall())

        cur.execute("""
            SELECT COUNT(*)
            FROM pg_stat_activity
            WHERE datname = 'mrs_db' AND state = 'active' AND pid <> pg_backend_pid();
        """)
        active_queries = cur.fetchone()[0]

        cur.close()
        conn.close()

        return {
            'conn_stats': conn_stats,
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
            # Get stats
            container_stats = container.stats(stream=False)

            # Calculate CPU percentage
            cpu_delta = container_stats['cpu_stats']['cpu_usage']['total_usage'] - \
                       container_stats['precpu_stats']['cpu_usage']['total_usage']
            system_delta = container_stats['cpu_stats']['system_cpu_usage'] - \
                          container_stats['precpu_stats']['system_cpu_usage']
            cpu_percent = 0.0
            if system_delta > 0 and cpu_delta > 0:
                num_cpus = len(container_stats['cpu_stats']['cpu_usage'].get('percpu_usage', [1]))
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


def create_pipeline_status_panel(dataset_info):
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

    # Show active job_id if available
    if dataset_info.get('active_job_id'):
        job_id_str = str(dataset_info['active_job_id'])[:8]  # Show first 8 chars of UUID
        table.add_row("Job ID:", f"[cyan]{job_id_str}...[/]")

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
    total_events = sum(all_counts.values())

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

    # Calculate percentage downlevel
    if total_packages > 0:
        downlevel_pct = ((major_behind + minor_behind + patch_behind) / total_packages) * 100
        table.add_row("", "")
        table.add_row("📉 Downlevel %:", f"[{'red' if downlevel_pct > 50 else 'yellow' if downlevel_pct > 25 else 'green'}]{downlevel_pct:.1f}%[/]")

    return Panel(table, title="[ Findings & Package Health", border_style="yellow", box=box.ROUNDED)




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
        return Panel(f"⚠️  {pg_stats['error']}", title="Postgres", border_style="red")

    table = Table.grid(padding=(0, 2))
    table.add_column(style="cyan", width=25)
    table.add_column()

    conn_stats = pg_stats.get('conn_stats', {})

    table.add_row("🔌 Active:", f"[yellow]{conn_stats.get('active', 0)}[/]")
    table.add_row("💤 Idle:", f"[green]{conn_stats.get('idle', 0)}[/]")
    table.add_row("⏳ Idle in TX:", f"[red]{conn_stats.get('idle in transaction', 0)}[/]")
    table.add_row("🔍 Active Queries:", f"[cyan]{pg_stats['active_queries']}[/]")

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


def create_dashboard(next_refresh_in, dataset_info=None, container_stats=None, pg_stats=None, host_stats=None, updating=False):
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
    layout["left"].update(create_pipeline_status_panel(dataset_info))

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

        with Live(create_dashboard(refresh_interval, dataset_info, container_stats, pg_stats, host_stats, updating=False),
                  refresh_per_second=update_rate, console=console, screen=True) as live:
            while True:
                start_time = time.time()

                # Update countdown every 0.1 seconds WITHOUT fetching new data
                while time.time() - start_time < refresh_interval:
                    elapsed = time.time() - start_time
                    remaining = refresh_interval - elapsed
                    live.update(create_dashboard(remaining, dataset_info, container_stats, pg_stats, host_stats, updating=False))
                    time.sleep(0.1)

                # Show UPDATING message
                live.update(create_dashboard(0, dataset_info, container_stats, pg_stats, host_stats, updating=True))

                # Fetch fresh data after countdown completes
                dataset_info = get_dataset_info()
                container_stats = get_container_stats()
                pg_stats = get_postgres_stats()
                host_stats = get_host_stats()

                # Display with refreshed data and reset timer to full interval
                live.update(create_dashboard(refresh_interval, dataset_info, container_stats, pg_stats, host_stats, updating=False))

    except KeyboardInterrupt:
        console.print("\n\n[bold yellow]👋 Shutting down monitor...[/bold yellow]\n")


if __name__ == "__main__":
    main()
