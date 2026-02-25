import json
import os
import shutil
import subprocess
from datetime import datetime, timedelta, timezone

import mysql.connector


def get_db_config_from_env():
    return {
        "host": os.getenv('DB_HOST', '127.0.0.1'),
        "user": os.getenv('DB_USER', 'root'),
        "password": os.getenv('DB_PASSWORD', '1234'),
        "database": os.getenv('DB_NAME', 'janitor_db'),
        "auth_plugin": "mysql_native_password"
    }


def _get_db_config(config=None):
    if config and isinstance(config.get("DB_CONFIG"), dict):
        return dict(config["DB_CONFIG"])
    return get_db_config_from_env()


def _get_connection(config=None):
    return mysql.connector.connect(**_get_db_config(config))


def _utc_now_naive():
    return datetime.now(timezone.utc).replace(tzinfo=None)


def _normalize_db_datetime(value):
    if value is None:
        return None
    if getattr(value, "tzinfo", None) is not None:
        return value.astimezone(timezone.utc).replace(tzinfo=None)
    return value


def ensure_lifecycle_table(conn):
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            CREATE TABLE IF NOT EXISTS zombie_lifecycle (
              id BIGINT AUTO_INCREMENT PRIMARY KEY,
              tc_name VARCHAR(255) NOT NULL,
              container_name VARCHAR(255) NOT NULL,
              short_id VARCHAR(64),
              status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
              detected_at TIMESTAMP NULL,
              scheduled_delete_at TIMESTAMP NULL,
              deleted_at TIMESTAMP NULL,
              reason TEXT,
              cpu_m DECIMAL(10, 2) NOT NULL DEFAULT 0,
              mem_mi DECIMAL(10, 2) NOT NULL DEFAULT 0,
              net_b DECIMAL(14, 2) NOT NULL DEFAULT 0,
              wasted_cost DECIMAL(14, 6) NOT NULL DEFAULT 0,
              last_error TEXT,
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
              updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
              INDEX idx_tc_status_sched (tc_name, status, scheduled_delete_at),
              INDEX idx_status_detected (status, detected_at),
              INDEX idx_container (tc_name, container_name),
              INDEX idx_short_id (short_id)
            ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4
            """
        )
        conn.commit()
    finally:
        cursor.close()


def ensure_runtime_schema(config=None):
    """Ensure runtime-required tables exist for alerting/cleanup flows."""
    conn = _get_connection(config)
    try:
        ensure_lifecycle_table(conn)
    finally:
        conn.close()


def upsert_registered_target(payload):
    """Insert or update a registered TC target."""
    conn = _get_connection()
    cursor = conn.cursor()
    labels_json = json.dumps(payload.get("labels", {}), ensure_ascii=False)
    
    # Include namespace and internal_prometheus_url
    sql = """
    INSERT INTO registered_targets (
        tc_name, tc_hostname, tc_ip, tc_os, tc_arch,
        prometheus_url, docker_api_url, labels, namespace, internal_prometheus_url,
        registered_at, updated_at
    )
    VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP(), UTC_TIMESTAMP())
    ON DUPLICATE KEY UPDATE
        tc_hostname = VALUES(tc_hostname),
        tc_ip = VALUES(tc_ip),
        tc_os = VALUES(tc_os),
        tc_arch = VALUES(tc_arch),
        prometheus_url = VALUES(prometheus_url),
        docker_api_url = VALUES(docker_api_url),
        labels = VALUES(labels),
        namespace = VALUES(namespace),
        internal_prometheus_url = VALUES(internal_prometheus_url),
        updated_at = UTC_TIMESTAMP()
    """
    cursor.execute(
        sql,
        (
            payload.get("tc_name"),
            payload.get("tc_hostname"),
            payload.get("tc_ip"),
            payload.get("tc_os"),
            payload.get("tc_arch"),
            payload.get("prometheus_url"),
            payload.get("docker_api_url"),
            labels_json,
            payload.get("namespace"),
            payload.get("internal_prometheus_url")
        )
    )
    conn.commit()
    cursor.close()
    conn.close()


def list_registered_targets():
    """List all registered TC targets."""
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    cursor.execute(
        """
        SELECT tc_name, tc_hostname, tc_ip, tc_os, tc_arch,
               prometheus_url, docker_api_url, labels, namespace, internal_prometheus_url,
               registered_at, updated_at
        FROM registered_targets
        ORDER BY updated_at DESC
        """
    )
    rows = cursor.fetchall()
    cursor.close()
    conn.close()
    for row in rows:
        if isinstance(row.get("labels"), str):
            try:
                row["labels"] = json.loads(row["labels"])
            except Exception:
                row["labels"] = {}
    return rows


def get_latest_registered_target():
    """Get the most recently updated TC target."""
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    cursor.execute(
        """
        SELECT tc_name, tc_hostname, tc_ip, tc_os, tc_arch,
               prometheus_url, docker_api_url, labels, namespace, internal_prometheus_url,
               registered_at, updated_at
        FROM registered_targets
        ORDER BY updated_at DESC
        LIMIT 1
        """
    )
    row = cursor.fetchone()
    cursor.close()
    conn.close()
    if row and isinstance(row.get("labels"), str):
        try:
            row["labels"] = json.loads(row["labels"])
        except Exception:
            row["labels"] = {}
    return row


def delete_registered_target(tc_name):
    """Delete a registered TC target."""
    conn = _get_connection()
    cursor = conn.cursor()
    cursor.execute("DELETE FROM registered_targets WHERE tc_name = %s", (tc_name,))
    conn.commit()
    affected = cursor.rowcount
    cursor.close()
    conn.close()
    return affected > 0


def get_registered_target(tc_name):
    """Get a registered TC target by name."""
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    cursor.execute(
        """
        SELECT tc_name, tc_hostname, tc_ip, tc_os, tc_arch,
               prometheus_url, docker_api_url, labels, namespace, internal_prometheus_url,
               registered_at, updated_at
        FROM registered_targets
        WHERE tc_name = %s
        LIMIT 1
        """,
        (tc_name,)
    )
    row = cursor.fetchone()
    cursor.close()
    conn.close()
    if row and isinstance(row.get("labels"), str):
        try:
            row["labels"] = json.loads(row["labels"])
        except Exception:
            row["labels"] = {}
    return row


def update_target_labels(tc_name, labels):
    """Update labels JSON for a registered TC target."""
    conn = _get_connection()
    cursor = conn.cursor()
    labels_json = json.dumps(labels or {}, ensure_ascii=False)
    cursor.execute(
        """
        UPDATE registered_targets
        SET labels = %s, updated_at = UTC_TIMESTAMP()
        WHERE tc_name = %s
        """,
        (labels_json, tc_name)
    )
    conn.commit()
    affected = cursor.rowcount
    cursor.close()
    conn.close()
    return affected > 0


def save_billing_and_delete(v1, pod_obj, config):
    """Save pod info to DB and delete from K8s."""
    ns, name = pod_obj.metadata.namespace, pod_obj.metadata.name
    
    # Calculate alive time
    creation_ts = pod_obj.metadata.creation_timestamp
    alive_sec = int((datetime.now(timezone.utc) - creation_ts).total_seconds())
    
    # Calculate cost
    cost = config['DEFAULT_CPU_REQ'] * (alive_sec / 3600) * config['COST_PER_CORE_HOUR']

    try:
        conn = _get_connection(config)
        cursor = conn.cursor()
        
        sql = "INSERT INTO billing_log (pod_name, namespace, alive_seconds, wasted_cost) VALUES (%s, %s, %s, %s)"
        cursor.execute(sql, (name, ns, alive_sec, cost))
        
        conn.commit()
        conn.close()
        
        # Delete pod
        v1.delete_namespaced_pod(name=name, namespace=ns)
        return True, cost, alive_sec
    except Exception as e:
        return False, str(e), 0


def add_or_update_zombie(tc_name, container_name, short_id, reason, cpu_m, mem_mi, net_b, config):
    """Upsert a pending zombie lifecycle row. Simple approach - only PENDING records exist."""
    if not tc_name or not container_name:
        return False

    conn = _get_connection(config)
    cursor = conn.cursor(dictionary=True)
    try:
        ensure_lifecycle_table(conn)

        # If latest record is STOPPED, keep manual stop override (do not recreate PENDING).
        cursor.execute(
            """
            SELECT id, status
            FROM zombie_lifecycle
            WHERE tc_name = %s AND container_name = %s
            ORDER BY id DESC
            LIMIT 1
            """,
            (tc_name, container_name),
        )
        latest = cursor.fetchone()
        if latest and str(latest.get("status") or "").upper() == "STOPPED":
            cursor.execute(
                """
                UPDATE zombie_lifecycle
                   SET cpu_m = %s, mem_mi = %s, net_b = %s, reason = %s, short_id = %s, updated_at = UTC_TIMESTAMP()
                 WHERE id = %s
                """,
                (float(cpu_m), float(mem_mi), float(net_b), str(reason), short_id, int(latest["id"])),
            )
            conn.commit()
            return True

        # Check if PENDING record already exists
        cursor.execute(
            """
            SELECT id FROM zombie_lifecycle
            WHERE tc_name = %s AND container_name = %s AND status = 'PENDING'
            LIMIT 1
            """,
            (tc_name, container_name),
        )
        existing = cursor.fetchone()

        if existing:
            # Update existing PENDING record
            cursor.execute(
                """
                UPDATE zombie_lifecycle
                   SET cpu_m = %s, mem_mi = %s, net_b = %s, reason = %s, short_id = %s, updated_at = UTC_TIMESTAMP()
                 WHERE id = %s
                """,
                (float(cpu_m), float(mem_mi), float(net_b), str(reason), short_id, int(existing["id"])),
            )
        else:
            # Create new PENDING record
            grace_minutes = max(1, int(config.get("GRACE_PERIOD_MINUTES", 10)))
            now_utc = _utc_now_naive()
            scheduled_at = now_utc + timedelta(minutes=grace_minutes)
            cursor.execute(
                """
                INSERT INTO zombie_lifecycle (
                    tc_name, container_name, short_id, status,
                    detected_at, scheduled_delete_at, reason, cpu_m, mem_mi, net_b
                )
                VALUES (%s, %s, %s, 'PENDING', %s, %s, %s, %s, %s, %s)
                """,
                (tc_name, container_name, short_id, now_utc, scheduled_at, str(reason),
                 float(cpu_m), float(mem_mi), float(net_b)),
            )

        conn.commit()
        return True
    except Exception as e:
        print(f"❌ lifecycle upsert failed: {e}")
        return False
    finally:
        cursor.close()
        conn.close()


def get_stopped_overrides(tc_name, config=None):
    """
    Return container names whose latest lifecycle status is STOPPED for this TC.
    """
    if not tc_name:
        return set()

    conn = _get_connection(config)
    cursor = conn.cursor(dictionary=True)
    try:
        ensure_lifecycle_table(conn)
        cursor.execute(
            """
            SELECT zl.container_name
            FROM zombie_lifecycle zl
            JOIN (
                SELECT tc_name, container_name, MAX(id) AS max_id
                FROM zombie_lifecycle
                WHERE tc_name = %s
                GROUP BY tc_name, container_name
            ) latest
              ON zl.id = latest.max_id
            WHERE zl.tc_name = %s
              AND zl.status = 'STOPPED'
            """,
            (tc_name, tc_name),
        )
        rows = cursor.fetchall()
        return {str(r.get("container_name", "")).strip().lower() for r in rows if r.get("container_name")}
    finally:
        cursor.close()
        conn.close()


def mark_recovered_pendings(tc_name, zombie_container_names, config):
    """Delete pending lifecycle rows when they are no longer zombie (simple approach)."""
    if not tc_name:
        return 0

    active_zombies = sorted({str(name).strip() for name in (zombie_container_names or []) if str(name).strip()})

    conn = _get_connection(config)
    cursor = conn.cursor()
    try:
        ensure_lifecycle_table(conn)

        if active_zombies:
            # Delete rows that are no longer zombie
            placeholders = ", ".join(["%s"] * len(active_zombies))
            sql = f"""
                DELETE FROM zombie_lifecycle
                 WHERE tc_name = %s
                   AND status = 'PENDING'
                   AND container_name NOT IN ({placeholders})
            """
            params = [tc_name] + active_zombies
            cursor.execute(sql, params)
        else:
            # No zombies - delete all pending for this TC
            cursor.execute(
                "DELETE FROM zombie_lifecycle WHERE tc_name = %s AND status = 'PENDING'",
                (tc_name,),
            )

        affected = cursor.rowcount
        conn.commit()
        return max(0, int(affected))
    except Exception as e:
        print(f"❌ pending recover delete failed: {e}")
        return 0
    finally:
        cursor.close()
        conn.close()


def process_cleanup(config):
    """DISABLED: Auto-cleanup is disabled. Containers can only be deleted via UI."""
    # Return immediately - no automatic deletion
    return {
        "total": 0,
        "deleted": 0,
        "already_missing": 0,
        "failed": 0,
        "dry_run": True,
        "disabled": True,
    }


def _process_cleanup_original(config):
    """Delete due pending zombies and update lifecycle status."""
    stats = {
        "total": 0,
        "deleted": 0,
        "already_missing": 0,
        "failed": 0,
        "dry_run": bool(config.get("DRY_RUN", False)),
    }

    conn = _get_connection(config)
    cursor = conn.cursor(dictionary=True)
    try:
        ensure_lifecycle_table(conn)

        target_name = config.get("TARGET_NAME")
        if target_name:
            cursor.execute(
                """
                SELECT *
                FROM zombie_lifecycle
                WHERE status = 'PENDING'
                  AND tc_name = %s
                  AND scheduled_delete_at <= UTC_TIMESTAMP()
                ORDER BY id ASC
                """,
                (target_name,),
            )
        else:
            cursor.execute(
                """
                SELECT *
                FROM zombie_lifecycle
                WHERE status = 'PENDING'
                  AND scheduled_delete_at <= UTC_TIMESTAMP()
                ORDER BY id ASC
                """
            )

        targets = cursor.fetchall()
        stats["total"] = len(targets)
        if not targets:
            return stats

        if stats["dry_run"]:
            print(f"[INFO] cleanup dry-run: {len(targets)} pending rows are due")
            return stats

        docker_client = None
        use_docker_cli = False
        docker_init_error = ""
        try:
            import docker
            docker_client = docker.DockerClient(
                base_url=config.get("DOCKER_API_URL", "unix:///var/run/docker.sock")
            )
        except Exception as e:
            docker_init_error = f"docker client init failed: {e}"
            if shutil.which("docker"):
                use_docker_cli = True
            else:
                for target in targets:
                    cursor.execute(
                        """
                        UPDATE zombie_lifecycle
                           SET status = 'FAILED',
                               last_error = %s,
                               updated_at = UTC_TIMESTAMP()
                         WHERE id = %s
                        """,
                        (docker_init_error, int(target["id"])),
                    )
                conn.commit()
                stats["failed"] = len(targets)
                return stats

        now_utc = _utc_now_naive()
        for target in targets:
            record_id = int(target["id"])
            container_ref = target.get("short_id") or target.get("container_name")
            detected_at = _normalize_db_datetime(target.get("detected_at")) or now_utc
            alive_sec = max(0, int((now_utc - detected_at).total_seconds()))
            cost = float(config.get("DEFAULT_CPU_REQ", 0.2)) * (alive_sec / 3600) * float(config.get("COST_PER_CORE_HOUR", 0.1))

            try:
                if use_docker_cli:
                    cli_result = subprocess.run(
                        ["docker", "rm", "-f", str(container_ref)],
                        check=False,
                        text=True,
                        capture_output=True,
                    )
                    if cli_result.returncode != 0:
                        raise RuntimeError((cli_result.stderr or cli_result.stdout or "").strip() or docker_init_error)
                else:
                    docker_client.containers.get(container_ref).remove(force=True)
                cursor.execute(
                    """
                    UPDATE zombie_lifecycle
                       SET status = 'DELETED',
                           deleted_at = UTC_TIMESTAMP(),
                           wasted_cost = %s,
                           last_error = NULL
                     WHERE id = %s
                    """,
                    (cost, record_id),
                )
                stats["deleted"] += 1
            except Exception as e:
                error_text = str(e)
                not_found = ("NotFound" in error_text) or ("404" in error_text)
                if not_found:
                    cursor.execute(
                        """
                        UPDATE zombie_lifecycle
                           SET status = 'DELETED',
                               deleted_at = UTC_TIMESTAMP(),
                               wasted_cost = %s,
                               last_error = %s
                         WHERE id = %s
                        """,
                        (cost, "container already missing", record_id),
                    )
                    stats["already_missing"] += 1
                else:
                    cursor.execute(
                        """
                        UPDATE zombie_lifecycle
                           SET status = 'FAILED',
                               last_error = %s,
                               updated_at = UTC_TIMESTAMP()
                         WHERE id = %s
                        """,
                        (error_text[:1000], record_id),
                    )
                    stats["failed"] += 1

        conn.commit()
        return stats
    finally:
        cursor.close()
        conn.close()


def list_pending_zombies(tc_name=None):
    """List all pending zombies with full details for email notifications."""
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        if tc_name:
            cursor.execute(
                """
                SELECT id, tc_name, container_name, short_id, status,
                       detected_at, scheduled_delete_at, reason,
                       cpu_m, mem_mi, net_b, wasted_cost
                FROM zombie_lifecycle
                WHERE status = 'PENDING' AND tc_name = %s
                ORDER BY scheduled_delete_at ASC
                """,
                (tc_name,),
            )
        else:
            cursor.execute(
                """
                SELECT id, tc_name, container_name, short_id, status,
                       detected_at, scheduled_delete_at, reason,
                       cpu_m, mem_mi, net_b, wasted_cost
                FROM zombie_lifecycle
                WHERE status = 'PENDING'
                ORDER BY scheduled_delete_at ASC
                """
            )
        rows = cursor.fetchall()
        # Normalize datetime fields
        for row in rows:
            row["detected_at"] = _normalize_db_datetime(row.get("detected_at"))
            row["scheduled_delete_at"] = _normalize_db_datetime(row.get("scheduled_delete_at"))
        return rows
    finally:
        cursor.close()
        conn.close()


def get_zombie_by_id(zombie_id):
    """Get a single zombie lifecycle record by ID."""
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        cursor.execute(
            """
            SELECT id, tc_name, container_name, short_id, status,
                   detected_at, scheduled_delete_at, reason,
                   cpu_m, mem_mi, net_b, wasted_cost
            FROM zombie_lifecycle
            WHERE id = %s
            """,
            (zombie_id,),
        )
        row = cursor.fetchone()
        if row:
            row["detected_at"] = _normalize_db_datetime(row.get("detected_at"))
            row["scheduled_delete_at"] = _normalize_db_datetime(row.get("scheduled_delete_at"))
        return row
    finally:
        cursor.close()
        conn.close()


def stop_zombie(zombie_id, config=None):
    """Mark a pending zombie as STOPPED (manual stop action)."""
    zombie = get_zombie_by_id(zombie_id)
    if not zombie:
        return {"success": False, "error": "zombie not found"}

    if zombie["status"] == "STOPPED":
        return {
            "success": True,
            "container_name": zombie["container_name"],
            "tc_name": zombie["tc_name"],
            "status": "STOPPED",
            "already_stopped": True,
        }

    if zombie["status"] != "PENDING":
        return {"success": False, "error": f"zombie status is {zombie['status']}, not PENDING"}

    conn = _get_connection(config)
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            UPDATE zombie_lifecycle
               SET status = 'STOPPED',
                   stopped_at = COALESCE(stopped_at, UTC_TIMESTAMP()),
                   last_cost_calc_at = COALESCE(last_cost_calc_at, UTC_TIMESTAMP()),
                   stop_ended_at = NULL,
                   updated_at = UTC_TIMESTAMP(),
                   last_error = NULL
             WHERE id = %s AND status = 'PENDING'
            """,
            (zombie_id,),
        )
        conn.commit()
        if cursor.rowcount > 0:
            return {
                "success": True,
                "container_name": zombie["container_name"],
                "tc_name": zombie["tc_name"],
                "status": "STOPPED",
            }
        return {"success": False, "error": "zombie not found or not pending"}
    finally:
        cursor.close()
        conn.close()

def accumulate_wasted_cost(config=None):
    conn = _get_connection(config)
    cursor = conn.cursor()
    try:
        cpu_rate = float((config or {}).get("CPU_COST_PER_M_PER_SEC", os.getenv("CPU_COST_PER_M_PER_SEC", "0.0")))
        mem_rate = float((config or {}).get("MEM_COST_PER_MI_PER_SEC", os.getenv("MEM_COST_PER_MI_PER_SEC", "0.0")))
        net_rate = float((config or {}).get("NET_COST_PER_B_PER_SEC",  os.getenv("NET_COST_PER_B_PER_SEC",  "0.0")))

        cursor.execute(
            """
            UPDATE zombie_lifecycle
            SET
              wasted_cost = wasted_cost + (
                GREATEST(
                  TIMESTAMPDIFF(SECOND, COALESCE(last_cost_calc_at, stopped_at), UTC_TIMESTAMP()),
                  0
                )
                *
                (
                  (cpu_m * %s) + (mem_mi * %s) + (net_b * %s)
                )
              ),
              last_cost_calc_at = UTC_TIMESTAMP(),
              updated_at = UTC_TIMESTAMP()
            WHERE status='STOPPED'
              AND stopped_at IS NOT NULL
              AND last_cost_calc_at IS NOT NULL
            """,
            (cpu_rate, mem_rate, net_rate),
        )
        conn.commit()
        return cursor.rowcount
    finally:
        cursor.close()
        conn.close()


def postpone_zombie(zombie_id, minutes=30):
    """Postpone zombie deletion by specified minutes."""
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        new_scheduled = _utc_now_naive() + timedelta(minutes=minutes)
        cursor.execute(
            """
            UPDATE zombie_lifecycle
               SET scheduled_delete_at = %s,
                   updated_at = UTC_TIMESTAMP()
             WHERE id = %s AND status = 'PENDING'
            """,
            (new_scheduled, zombie_id),
        )
        conn.commit()
        if cursor.rowcount > 0:
            return {"success": True, "new_scheduled_at": new_scheduled.isoformat()}
        return {"success": False, "error": "zombie not found or not pending"}
    except Exception as e:
        return {"success": False, "error": str(e)}
    finally:
        cursor.close()
        conn.close()


def save_latest_scan_snapshot(tc_name, cycle_id, summary, rows):
    """
    Replace latest scan snapshot for a TC.
    Previous rows for the TC are removed, then current cycle rows are inserted.
    """
    conn = _get_connection()
    cursor = conn.cursor()
    try:
        cursor.execute(
            """
            INSERT INTO scan_latest_summary (
                tc_name, cycle_id, zombie_count, candidate_count, active_count, safe_count, updated_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
            ON DUPLICATE KEY UPDATE
                cycle_id = VALUES(cycle_id),
                zombie_count = VALUES(zombie_count),
                candidate_count = VALUES(candidate_count),
                active_count = VALUES(active_count),
                safe_count = VALUES(safe_count),
                updated_at = UTC_TIMESTAMP()
            """,
            (
                tc_name,
                int(cycle_id),
                int(summary.get("zombie", 0)),
                int(summary.get("candidate", 0)),
                int(summary.get("active", 0)),
                int(summary.get("safe", 0)),
            ),
        )

        cursor.execute("DELETE FROM scan_latest_containers WHERE tc_name = %s", (tc_name,))

        insert_sql = """
            INSERT INTO scan_latest_containers (
                tc_name, cycle_id, container_name, tc_container,
                cpu_m, mem_mi, net_b, ctype, decision, reason, updated_at
            )
            VALUES (%s, %s, %s, %s, %s, %s, %s, %s, %s, %s, UTC_TIMESTAMP())
        """
        for row in rows or []:
            cursor.execute(
                insert_sql,
                (
                    tc_name,
                    int(cycle_id),
                    str(row.get("container_name", "")),
                    str(row.get("tc_container", "")),
                    float(row.get("cpu_m", 0.0)),
                    float(row.get("mem_mi", 0.0)),
                    float(row.get("net_b", 0.0)),
                    str(row.get("ctype", "unknown")),
                    str(row.get("decision", "")),
                    str(row.get("reason", "")),
                ),
            )
        conn.commit()
    finally:
        cursor.close()
        conn.close()


def get_all_containers_with_status(tc_name=None):
    """
    Get all containers from latest scan combined with lifecycle status.
    Returns containers with their current status (PENDING, ACTIVE, DELETED, etc.)
    """
    conn = _get_connection()
    cursor = conn.cursor(dictionary=True)
    try:
        # Get latest scan results
        if tc_name:
            cursor.execute(
                """
                SELECT tc_name, container_name, tc_container, cpu_m, mem_mi, net_b, 
                       ctype, decision, reason, updated_at
                FROM scan_latest_containers
                WHERE tc_name = %s
                ORDER BY container_name
                """,
                (tc_name,),
            )
        else:
            cursor.execute(
                """
                SELECT tc_name, container_name, tc_container, cpu_m, mem_mi, net_b, 
                       ctype, decision, reason, updated_at
                FROM scan_latest_containers
                ORDER BY tc_name, container_name
                """
            )
        containers = cursor.fetchall()
        
        # Get lifecycle status for each container
        for container in containers:
            cursor.execute(
                """
                SELECT id, status, detected_at, scheduled_delete_at, short_id
                FROM zombie_lifecycle
                WHERE tc_name = %s AND container_name = %s
                ORDER BY id DESC
                LIMIT 1
                """,
                (container["tc_name"], container["container_name"]),
            )
            lifecycle = cursor.fetchone()
            if lifecycle:
                container["lifecycle_id"] = lifecycle["id"]
                container["lifecycle_status"] = lifecycle["status"]
                container["short_id"] = lifecycle["short_id"]
                container["detected_at"] = lifecycle["detected_at"]
                container["scheduled_delete_at"] = lifecycle["scheduled_delete_at"]
            else:
                container["lifecycle_id"] = None
                container["lifecycle_status"] = None
                container["short_id"] = None
                container["detected_at"] = None
                container["scheduled_delete_at"] = None
        
        return containers
    finally:
        cursor.close()
        conn.close()


def remove_from_whitelist(tc_name, container_name):
    """Remove a container from TC whitelist."""
    target = get_registered_target(tc_name)
    if not target:
        return False, "target not found"
    
    labels = target.get("labels") or {}
    if not isinstance(labels, dict):
        labels = {}
    
    whitelist = labels.get("container_whitelist", [])
    if not isinstance(whitelist, list):
        whitelist = []
    
    container_lower = container_name.lower()
    if container_lower in [w.lower() for w in whitelist]:
        new_whitelist = [w for w in whitelist if w.lower() != container_lower]
        labels["container_whitelist"] = new_whitelist
        return update_target_labels(tc_name, labels), "removed"
    
    return True, "not in whitelist"
