import json
import os
import mysql.connector
from datetime import datetime, timezone


def get_db_config_from_env():
    return {
        "host": os.getenv('DB_HOST', '127.0.0.1'),
        "user": os.getenv('DB_USER', 'root'),
        "password": os.getenv('DB_PASSWORD', '1234'),
        "database": os.getenv('DB_NAME', 'janitor_db'),
        "auth_plugin": "mysql_native_password"
    }


def upsert_registered_target(payload):
    """Insert or update a registered TC target."""
    conn = mysql.connector.connect(**get_db_config_from_env())
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
    conn = mysql.connector.connect(**get_db_config_from_env())
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
    conn = mysql.connector.connect(**get_db_config_from_env())
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
    conn = mysql.connector.connect(**get_db_config_from_env())
    cursor = conn.cursor()
    cursor.execute("DELETE FROM registered_targets WHERE tc_name = %s", (tc_name,))
    conn.commit()
    affected = cursor.rowcount
    cursor.close()
    conn.close()
    return affected > 0


def get_registered_target(tc_name):
    """Get a registered TC target by name."""
    conn = mysql.connector.connect(**get_db_config_from_env())
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
    conn = mysql.connector.connect(**get_db_config_from_env())
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
        conn = mysql.connector.connect(**config['DB_CONFIG'])
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


def save_latest_scan_snapshot(tc_name, cycle_id, summary, rows):
    """
    Replace latest scan snapshot for a TC.
    Previous rows for the TC are removed, then current cycle rows are inserted.
    """
    conn = mysql.connector.connect(**get_db_config_from_env())
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
