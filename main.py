import os
import sys
import json
import argparse
import threading
import requests
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse
from dotenv import load_dotenv
import re
from datetime import datetime, timezone, timedelta

# KST timezone
KST = timezone(timedelta(hours=9))

def to_kst(dt):
    """Convert datetime to KST string."""
    if dt is None:
        return ""
    if hasattr(dt, 'tzinfo') and dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    kst_dt = dt.astimezone(KST)
    return kst_dt.strftime("%Y-%m-%d %H:%M:%S")

# Add py_Logic to Python path
sys.path.append(os.path.join(os.path.dirname(__file__), 'py_Logic'))

# Load .env file
load_dotenv()

try:
    from py_Logic.janitor_logic import run_janitor, run_cleanup
    from py_Logic.database import (
        upsert_registered_target,
        list_registered_targets,
        get_latest_registered_target,
        delete_registered_target,
        get_registered_target,
        update_target_labels,
        ensure_runtime_schema,
        list_pending_zombies,
        get_zombie_by_id,
        postpone_zombie,
        stop_zombie,
        get_all_containers_with_status,
        remove_from_whitelist,
    )
    from kubernetes import client, config as k8s_config
except ImportError as e:
    print(f"❌ Cannot load logic files: {e}")
    sys.exit(1)


def get_k8s_client():
    """Get Kubernetes client for cj cluster."""
    try:
        kube_config_path = os.path.expanduser("~/.kube/config")
        if os.path.exists(kube_config_path):
            k8s_config.load_kube_config(config_file=kube_config_path)
        else:
            k8s_config.load_incluster_config()
        return client.CoreV1Api(), client.CustomObjectsApi()
    except Exception as e:
        print(f"❌ K8s auth failed: {e}")
        return None, None


def sanitize_namespace_name(name):
    """Convert TC name to valid K8s namespace name."""
    # Lowercase, replace invalid chars with hyphen, max 63 chars
    sanitized = name.lower()
    sanitized = re.sub(r'[^a-z0-9-]', '-', sanitized)
    sanitized = re.sub(r'^-+', '', sanitized)
    sanitized = re.sub(r'-+$', '', sanitized)
    sanitized = sanitized[:63]
    if not sanitized:
        sanitized = "tc-default"
    return f"tc-{sanitized}"


def create_tc_namespace(v1, tc_name, tc_info):
    """Create namespace for TC in cj K8s cluster."""
    namespace = sanitize_namespace_name(tc_name)
    
    try:
        # Check if namespace exists
        v1.read_namespace(name=namespace)
        print(f"[INFO] Namespace {namespace} already exists")
        return namespace
    except Exception:
        pass  # Namespace doesn't exist, create it
    
    # Create namespace with labels
    ns_body = client.V1Namespace(
        metadata=client.V1ObjectMeta(
            name=namespace,
            labels={
                "app.kubernetes.io/name": "cloud-janitor-target",
                "app.kubernetes.io/component": "target-cluster",
                "cloud-janitor.io/tc-name": tc_name,
                "cloud-janitor.io/tc-hostname": tc_info.get("tc_hostname", "unknown"),
            },
            annotations={
                "cloud-janitor.io/prometheus-url": tc_info.get("prometheus_url", ""),
                "cloud-janitor.io/registered-at": tc_info.get("timestamp", ""),
            }
        )
    )
    
    try:
        v1.create_namespace(ns_body)
        print(f"[INFO] Created namespace: {namespace}")
        return namespace
    except Exception as e:
        print(f"[ERROR] Failed to create namespace: {e}")
        return None


def get_host_ip_for_kind():
    """Best-effort host gateway IP reachable from kind."""
    # Method 1: Resolve host.docker.internal from kind control-plane container.
    kind_containers = ["cloud-janitor-cluster-control-plane"]
    for container in kind_containers:
        try:
            result = os.popen(f"docker exec {container} getent hosts host.docker.internal 2>/dev/null | awk '{{print $1}}'").read().strip()
            if result and result != "":
                return result
        except Exception:
            pass
    
    # Method 2: Docker bridge gateway IP on host.
    try:
        result = os.popen("docker network inspect bridge 2>/dev/null | grep -m1 '\"Gateway\"' | awk -F'\"' '{print $4}'").read().strip()
        if result and result != "" and result != "null":
            return result
    except Exception:
        pass

    return ""


def is_tcp_reachable(host, port, timeout=2.0):
    """Check TCP reachability from cj runtime."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except Exception:
        return False


def create_tc_prometheus_service(v1, namespace, tc_info):
    """Create Service pointing to TC Prometheus (external)."""
    service_name = "prometheus"
    prometheus_url = tc_info.get("prometheus_url", "")
    tc_ip = str(tc_info.get("tc_ip", "")).strip()
    
    if not prometheus_url:
        print("[ERROR] No prometheus_url provided")
        return False
    
    # Parse Prometheus URL
    parsed = urlparse(prometheus_url)
    hostname = parsed.hostname or "localhost"
    port = parsed.port or 9091
    
    # Resolve endpoint IP with one deterministic strategy:
    # 1) URL host (localhost -> kind host gateway, IP -> itself, hostname -> DNS resolve)
    # 2) tc_ip from registration payload
    # 3) kind host gateway fallback
    # Then pick the first TCP-reachable candidate from cj runtime.
    ip_pattern = r'^(\d{1,3}\.){3}\d{1,3}$'
    is_ip = bool(re.match(ip_pattern, hostname))
    is_local = hostname in ("localhost", "127.0.0.1", "0.0.0.0")

    candidates = []
    if is_local:
        kind_ip = get_host_ip_for_kind()
        if kind_ip:
            candidates.append(kind_ip)
    elif is_ip:
        candidates.append(hostname)
    else:
        try:
            resolved_ip = socket.gethostbyname(hostname)
            if resolved_ip:
                candidates.append(resolved_ip)
        except Exception:
            pass

    if tc_ip and tc_ip != "unknown":
        candidates.append(tc_ip)

    kind_ip = get_host_ip_for_kind()
    if kind_ip:
        candidates.append(kind_ip)

    dedup_candidates = []
    seen = set()
    for candidate in candidates:
        value = str(candidate).strip()
        if not value or value in seen:
            continue
        seen.add(value)
        dedup_candidates.append(value)

    endpoint_ip = None
    for candidate in dedup_candidates:
        if is_tcp_reachable(candidate, port, timeout=2.0):
            endpoint_ip = candidate
            break

    if not endpoint_ip:
        print(
            f"[ERROR] No reachable TC Prometheus endpoint for {prometheus_url} "
            f"(candidates: {', '.join(dedup_candidates) if dedup_candidates else '<none>'})"
        )
        return False

    print(f"[INFO] Using endpoint IP: {endpoint_ip}:{port} for TC Prometheus")
    
    # Check if service exists
    try:
        v1.read_namespaced_service(name=service_name, namespace=namespace)
        # Delete and recreate
        v1.delete_namespaced_service(name=service_name, namespace=namespace)
        print(f"[INFO] Deleted existing service {service_name}")
    except Exception:
        pass
    
    # Delete existing endpoints too
    try:
        v1.delete_namespaced_endpoints(name=service_name, namespace=namespace)
    except Exception:
        pass
    
    # Create Endpoints for external Prometheus
    endpoints_body = client.V1Endpoints(
        metadata=client.V1ObjectMeta(
            name=service_name,
            namespace=namespace,
            labels={
                "app.kubernetes.io/name": "prometheus",
                "app.kubernetes.io/component": "target-prometheus",
            }
        ),
        subsets=[
            client.V1EndpointSubset(
                addresses=[
                    client.V1EndpointAddress(
                        ip=endpoint_ip,
                    )
                ],
                ports=[
                    client.CoreV1EndpointPort(
                        name="http",
                        port=port,
                        protocol="TCP"
                    )
                ]
            )
        ]
    )
    
    # Create Service (use regular ClusterIP, not headless, for proper DNS resolution)
    service_body = client.V1Service(
        metadata=client.V1ObjectMeta(
            name=service_name,
            namespace=namespace,
            labels={
                "app.kubernetes.io/name": "prometheus",
                "app.kubernetes.io/component": "target-prometheus",
            }
        ),
        spec=client.V1ServiceSpec(
            type="ClusterIP",
            ports=[
                client.V1ServicePort(
                    name="http",
                    port=port,
                    target_port=port,
                    protocol="TCP"
                )
            ]
        )
    )
    
    try:
        # Create endpoints first
        v1.create_namespaced_endpoints(namespace=namespace, body=endpoints_body)
        # Then create service
        v1.create_namespaced_service(namespace=namespace, body=service_body)
        print(f"[INFO] Created service: {service_name}.{namespace} -> {endpoint_ip}:{port}")
        return True
    except Exception as e:
        print(f"[ERROR] Failed to create service: {e}")
        return False


def get_internal_prometheus_url(namespace, port=9091):
    """Get K8s-internal Prometheus URL for a TC namespace."""
    service_name = "prometheus"
    # K8s DNS: service.namespace.svc.cluster.local
    return f"http://{service_name}.{namespace}.svc.cluster.local:{port}"


def get_prometheus_port_from_url(prometheus_url, default_port=9091):
    """Parse Prometheus port from URL."""
    try:
        parsed = urlparse(prometheus_url or "")
        if parsed.port:
            return int(parsed.port)
    except Exception:
        pass
    return int(default_port)


def build_config():
    """Build configuration from environment variables."""
    config = {
        "LIMIT_CPU_M": float(os.getenv('LIMIT_CPU_M', 10.0)),
        "TIME_WINDOW_CPU": os.getenv('TIME_WINDOW_CPU', '2m'),
        "LIMIT_NET_B": float(os.getenv('LIMIT_NET_B', 100.0)),
        "TIME_WINDOW_NET": os.getenv('TIME_WINDOW_NET', '2m'),
        "LIMIT_MEM_MI": float(os.getenv('LIMIT_MEM_MI', 1.0)),
        "GRACE_PERIOD_MINUTES": int(os.getenv('GRACE_PERIOD_MINUTES', 10)),
        "COST_PER_CORE_HOUR": float(os.getenv('COST_PER_CORE_HOUR', 0.1)),
        "DEFAULT_CPU_REQ": float(os.getenv('DEFAULT_CPU_REQ', 0.2)),
        "DB_CONFIG": {
            "host": os.getenv('DB_HOST', '127.0.0.1'),
            "user": os.getenv('DB_USER', 'root'),
            "password": os.getenv('DB_PASSWORD', '1234'),
            "database": os.getenv('DB_NAME', 'janitor_db'),
            "auth_plugin": "mysql_native_password"
        },
        "PROMETHEUS_URL": os.getenv('PROMETHEUS_URL', 'http://prometheus:9090'),
        "DOCKER_API_URL": os.getenv('DOCKER_API_URL', 'unix:///var/run/docker.sock'),
        "TARGET_NAME": os.getenv('TARGET_NAME', ''),
        "CONTAINER_WHITELIST": [x.strip() for x in os.getenv('CONTAINER_WHITELIST', 'target-prometheus,promtail,cadvisor').split(',') if x.strip()],
        "CONTAINER_MAP": {},
        "SCAN_ENABLED": False,
        "SCAN_SKIP_REASON": "no registered target",
        "DRY_RUN": os.getenv('DRY_RUN', 'False').lower() == 'true',
        "WHITE_LIST_NS": ['kube-system', 'prometheus', 'local-path-storage', 'monitoring'],
        "TARGET_NAMESPACES": ['default', 'zombie-zone']
    }
    
    # Get latest registered target's internal URL
    try:
        latest = get_latest_registered_target()
        if latest and latest.get("namespace"):
            # Prefer stored internal URL from registration snapshot.
            internal_url = latest.get("internal_prometheus_url")
            if not internal_url:
                prom_port = get_prometheus_port_from_url(latest.get("prometheus_url", ""), 9091)
                internal_url = get_internal_prometheus_url(latest["namespace"], prom_port)
            config["PROMETHEUS_URL"] = internal_url
            config["TARGET_NAME"] = latest.get("tc_name", "tc-target")
            config["SCAN_ENABLED"] = True
            config["SCAN_SKIP_REASON"] = ""
            labels = latest.get("labels") or {}
            if isinstance(labels, dict):
                config["CONTAINER_MAP"] = labels.get("container_map", {})
                tc_whitelist = labels.get("container_whitelist", [])
                if isinstance(tc_whitelist, list):
                    config["CONTAINER_WHITELIST"] = [str(x).strip() for x in tc_whitelist if str(x).strip()]
            if latest.get("docker_api_url"):
                config["DOCKER_API_URL"] = latest.get("docker_api_url")
            print(f"[INFO] Using internal Prometheus URL: {internal_url}")
    except Exception as e:
        print(f"[WARN] Could not get latest target: {e}")
    
    return config


def bootstrap_runtime_schema(config=None):
    """Best-effort DB schema bootstrap for runtime alert queries."""
    try:
        ensure_runtime_schema(config)
        print("[INFO] ensured runtime DB schema (zombie_lifecycle)")
    except Exception as e:
        print(f"[WARN] runtime schema ensure failed: {e}")


def run_scan():
    """Run janitor scan."""
    bootstrap_runtime_schema()
    config = build_config()
    if not config.get("SCAN_ENABLED"):
        print(f"[WARN] scan skipped: {config.get('SCAN_SKIP_REASON', 'target not ready')}")
        return
    bootstrap_runtime_schema(config)
    run_janitor(config)


def trigger_post_register_scan(tc_name):
    """Run one scan asynchronously right after TC registration."""
    name = str(tc_name or "unknown")

    def _job():
        try:
            print(f"[INFO] Triggering post-register scan for TC: {name}")
            run_scan()
        except Exception as e:
            print(f"[WARN] post-register scan failed for {name}: {e}")

    worker = threading.Thread(target=_job, daemon=True, name=f"register-scan-{name}")
    worker.start()


def run_cleanup_cycle():
    """Run deferred cleanup cycle."""
    bootstrap_runtime_schema()
    config = build_config()
    bootstrap_runtime_schema(config)
    run_cleanup(config)


def get_grafana_config():
    """Get Grafana configuration."""
    url = os.getenv("GRAFANA_URL")
    password = os.getenv("GRAFANA_PASSWORD")
    user = os.getenv("GRAFANA_USER", "admin")
    if not url or not password:
        return None
    return url.rstrip("/"), user, password


def sanitize_uid(value, prefix="ds"):
    """Build a Grafana-safe datasource uid."""
    sanitized = re.sub(r'[^a-zA-Z0-9_-]', '-', (value or "").strip())
    sanitized = sanitized.strip("-_")
    if not sanitized:
        sanitized = "default"
    # Grafana uid practical limit: keep short and stable
    return f"{prefix}-{sanitized}"[:40]


def upsert_grafana_datasource(prometheus_url, tc_name):
    """Create or update Grafana datasource for a TC."""
    config = get_grafana_config()
    if not config:
        return False
    
    grafana_url, user, password = config
    datasource_name = f"TC-{tc_name}"
    
    payload = {
        "uid": sanitize_uid(tc_name, "tc"),
        "name": datasource_name,
        "type": "prometheus",
        "url": prometheus_url,
        "access": "proxy",
        "isDefault": False,
        "jsonData": {
            "httpMethod": "POST"
        }
    }
    
    try:
        # Check if datasource exists
        resp = requests.get(
            f"{grafana_url}/api/datasources/name/{datasource_name}",
            auth=(user, password),
            timeout=5
        )
        
        if resp.status_code == 200:
            # Update existing
            ds_id = resp.json().get("id")
            if ds_id:
                update_resp = requests.put(
                    f"{grafana_url}/api/datasources/{ds_id}",
                    json=payload,
                    auth=(user, password),
                    timeout=5
                )
                print(f"[INFO] Updated Grafana datasource: {datasource_name}")
                return update_resp.status_code in (200, 202)
        elif resp.status_code == 404:
            # Create new
            create_resp = requests.post(
                f"{grafana_url}/api/datasources",
                json=payload,
                auth=(user, password),
                timeout=5
            )
            print(f"[INFO] Created Grafana datasource: {datasource_name}")
            return create_resp.status_code in (200, 202)
        
        return False
    except Exception as e:
        print(f"[ERROR] Grafana datasource error: {e}")
        return False


def upsert_grafana_main_prometheus(prometheus_url):
    """Create or update fixed Grafana Prometheus datasource used by dashboard panels."""
    config = get_grafana_config()
    if not config:
        return False

    grafana_url, user, password = config
    payload = {
        "uid": "prometheus-main",
        "name": "Prometheus",
        "type": "prometheus",
        "url": prometheus_url,
        "access": "proxy",
        "isDefault": True,
        "jsonData": {
            "httpMethod": "POST"
        }
    }

    try:
        resp = requests.get(
            f"{grafana_url}/api/datasources/name/Prometheus",
            auth=(user, password),
            timeout=5
        )

        if resp.status_code == 200:
            ds_id = resp.json().get("id")
            if ds_id:
                update_resp = requests.put(
                    f"{grafana_url}/api/datasources/{ds_id}",
                    json=payload,
                    auth=(user, password),
                    timeout=5
                )
                print("[INFO] Updated Grafana datasource: Prometheus (prometheus-main)")
                return update_resp.status_code in (200, 202)
        elif resp.status_code == 404:
            create_resp = requests.post(
                f"{grafana_url}/api/datasources",
                json=payload,
                auth=(user, password),
                timeout=5
            )
            print("[INFO] Created Grafana datasource: Prometheus (prometheus-main)")
            return create_resp.status_code in (200, 202)

        return False
    except Exception as e:
        print(f"[ERROR] Grafana main datasource error: {e}")
        return False


def register_tc(tc_info):
    """Register a TC: create K8s resources, update DB, create Grafana datasource."""
    tc_name = tc_info.get("tc_name")
    if not tc_name:
        return {"error": "tc_name is required"}, 400
    
    if not tc_info.get("prometheus_url"):
        return {"error": "prometheus_url is required"}, 400

    # Best-effort schema ensure for alert queries even before first scan.
    bootstrap_runtime_schema()
    
    # Get K8s client
    v1, _ = get_k8s_client()
    if not v1:
        return {"error": "Failed to connect to K8s"}, 500
    
    # Create namespace
    namespace = create_tc_namespace(v1, tc_name, tc_info)
    if not namespace:
        return {"error": "Failed to create namespace"}, 500
    
    # Create Prometheus service
    if not create_tc_prometheus_service(v1, namespace, tc_info):
        return {"error": "Failed to create Prometheus service"}, 500
    
    # Add namespace to tc_info for DB storage
    tc_info["namespace"] = namespace
    prom_port = get_prometheus_port_from_url(tc_info.get("prometheus_url", ""), 9091)
    tc_info["internal_prometheus_url"] = get_internal_prometheus_url(namespace, prom_port)
    
    # Save to database
    upsert_registered_target(tc_info)
    
    # Create Grafana datasource with internal URL
    upsert_grafana_datasource(tc_info["internal_prometheus_url"], tc_name)
    upsert_grafana_main_prometheus(tc_info["internal_prometheus_url"])
    trigger_post_register_scan(tc_name)
    
    return {
        "message": "registered",
        "tc_name": tc_name,
        "namespace": namespace,
        "internal_prometheus_url": tc_info["internal_prometheus_url"]
    }, 200


def build_loki_push_url(cj_host):
    """Build Loki push URL for TC promtail.

    Priority:
    1) LOKI_URL
    2) http://<cj_host>:31000 (fallback)
    """
    configured = (os.getenv("LOKI_URL") or "").strip()
    if configured:
        return configured

    host = (cj_host or "").strip() or "localhost"
    return f"http://{host}:31000"


def update_tc_whitelist(tc_name, payload):
    """Update TC container whitelist only."""
    whitelist = payload.get("container_whitelist")
    add_containers = payload.get("add_containers", [])
    
    target = get_registered_target(tc_name)
    if not target:
        return {"error": f"target not found: {tc_name}"}, 404

    labels = target.get("labels") or {}
    if not isinstance(labels, dict):
        labels = {}
    
    # Get existing whitelist
    existing = labels.get("container_whitelist", [])
    if not isinstance(existing, list):
        existing = []
    
    # If add_containers is provided, merge with existing
    if add_containers and isinstance(add_containers, list):
        for item in add_containers:
            text = str(item).strip().lower()
            if text and text not in existing:
                existing.append(text)
        labels["container_whitelist"] = existing
    elif whitelist is not None and isinstance(whitelist, list):
        # Replace entire whitelist
        sanitized = []
        for item in whitelist:
            text = str(item).strip()
            if text:
                sanitized.append(text)
        labels["container_whitelist"] = sanitized
    else:
        return {"error": "container_whitelist or add_containers is required"}, 400

    if not update_target_labels(tc_name, labels):
        return {"error": "failed to update whitelist"}, 500

    return {
        "message": "whitelist updated",
        "tc_name": tc_name,
        "container_whitelist": labels["container_whitelist"],
    }, 200


def get_logs_from_loki(query, limit=50):
    """Fetch logs from Loki."""
    loki_url = os.getenv("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
    
    try:
        # Calculate time range (last 1 hour)
        end_ns = int(datetime.now(timezone.utc).timestamp() * 1_000_000_000)
        start_ns = end_ns - (60 * 60 * 1_000_000_000)  # 1 hour ago
        
        resp = requests.get(
            f"{loki_url}/loki/api/v1/query_range",
            params={
                "query": query,
                "start": str(start_ns),
                "end": str(end_ns),
                "limit": str(limit),
            },
            timeout=10
        )
        
        if resp.status_code != 200:
            return {"error": f"Loki returned {resp.status_code}", "logs": []}
        
        data = resp.json()
        result = data.get("data", {}).get("result", [])
        
        logs = []
        for stream in result:
            values = stream.get("values", [])
            for val in values:
                if len(val) >= 2:
                    timestamp_ns = int(val[0])
                    timestamp = datetime.fromtimestamp(timestamp_ns / 1_000_000_000, tz=timezone.utc)
                    logs.append({
                        "time": timestamp.strftime("%H:%M:%S"),
                        "message": val[1],
                        "level": "info"  # Default level
                    })
        
        # Sort by time (oldest first)
        logs.reverse()
        return {"logs": logs[:limit]}
        
    except Exception as e:
        return {"error": str(e), "logs": []}


def _escape_logql_label_value(value):
    """Escape LogQL label string value."""
    return str(value).replace("\\", "\\\\").replace('"', '\\"')


def get_logs_for_container(container_name, limit=50):
    """
    Fetch logs for a specific container.
    Try compose_service first, then container_name exact/suffix match.
    """
    name = str(container_name or "").strip()
    if not name:
        return {"error": "container_name parameter is required", "logs": []}

    esc_name = _escape_logql_label_value(name)
    esc_suffix = _escape_logql_label_value(f".*{re.escape(name)}$")
    queries = [
        f'{{job="tc-docker",compose_service="{esc_name}"}}',
        f'{{job="tc-docker",container_name="{esc_name}"}}',
        f'{{job="tc-docker",container_name=~"{esc_suffix}"}}',
    ]

    last_error = None
    for q in queries:
        result = get_logs_from_loki(q, limit)
        if result.get("error"):
            last_error = result["error"]
            continue
        if result.get("logs"):
            return result

    if last_error:
        return {"error": last_error, "logs": []}
    return {"logs": []}


TEMPLATE_DIR = os.path.join(os.path.dirname(__file__), "templates")
_HTML_TEMPLATE_CACHE = {}


def _load_html_template(template_name):
    """Load HTML template from disk."""
    base_dir = os.path.dirname(__file__)
    candidates = [
        os.path.join(TEMPLATE_DIR, template_name),
        os.path.join(base_dir, template_name),
    ]
    for path in candidates:
        if os.path.exists(path):
            with open(path, "r", encoding="utf-8") as f:
                return f.read()
    raise FileNotFoundError(f"template not found: {template_name}")


def _render_html_template(template_name, **values):
    """Render HTML template with .format placeholders."""
    template = _HTML_TEMPLATE_CACHE.get(template_name)
    if template is None:
        template = _load_html_template(template_name)
        _HTML_TEMPLATE_CACHE[template_name] = template
    return template.format(**values)

class RequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_html(self, status, html):
        body = html.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _render_containers_ui(self, message=""):
        """Render all TC containers dashboard HTML."""
        # Get all containers with status
        containers = get_all_containers_with_status()
        
        # Get TC whitelist
        tc_name = None
        whitelist = set()
        target = get_latest_registered_target()
        if target:
            tc_name = target.get("tc_name")
            labels = target.get("labels") or {}
            wl = labels.get("container_whitelist", [])
            if isinstance(wl, list):
                whitelist = {str(x).lower() for x in wl if x}
        
        # Separate containers into categories
        pending_containers = []
        stopped_containers = []
        active_containers = []
        whitelisted_containers = []
        
        for c in containers:
            container_name = c.get("container_name", "").lower()
            decision = c.get("decision", "")
            decision_upper = str(decision).upper()
            lifecycle_status = c.get("lifecycle_status")
            
            # Check if whitelisted
            if container_name in whitelist:
                c["is_whitelisted"] = True
                whitelisted_containers.append(c)
            else:
                # PENDING = zombie candidate, STOPPED = manually stopped in UI or runtime stopped
                if lifecycle_status == "PENDING":
                    pending_containers.append(c)
                elif lifecycle_status == "STOPPED" or "STOPPED" in decision_upper:
                    stopped_containers.append(c)
                else:
                    active_containers.append(c)
        
        # Build HTML content
        content_html = ""
        
        # Pending (Zombie) containers
        content_html += "<h3 class='section-title'>🚨 Pending 삭제 (좀비 감지됨)</h3>"
        if not pending_containers:
            content_html += "<p class='empty'>삭제 예정인 컨테이너가 없습니다.</p>"
        else:
            content_html += self._build_container_table(pending_containers, tc_name, "pending", is_pending=True)
        
        # Stopped containers
        content_html += "<h3 class='section-title'>⏸️ 멈춤 (STOPPED)</h3>"
        if not stopped_containers:
            content_html += "<p class='empty'>멈춤 처리된 컨테이너가 없습니다.</p>"
        else:
            content_html += self._build_container_table(stopped_containers, tc_name, "stopped", is_stopped=True)
        
        # Active containers
        content_html += "<h3 class='section-title'>✅ 정상 작동 중</h3>"
        if not active_containers:
            content_html += "<p class='empty'>활성 컨테이너가 없습니다.</p>"
        else:
            content_html += self._build_container_table(active_containers, tc_name, "active", is_pending=False)
        
        # Whitelisted containers
        content_html += "<h3 class='section-title'>🛡️ 화이트리스트</h3>"
        if not whitelisted_containers:
            content_html += "<p class='empty'>화이트리스트된 컨테이너가 없습니다.</p>"
        else:
            content_html += self._build_container_table(whitelisted_containers, tc_name, "whitelist", is_whitelisted=True)
        
        html = _render_html_template("containers.html", message=message, content=content_html)
        self._send_html(200, html)
    
    def _build_container_table(self, containers, tc_name, section_prefix, is_pending=False, is_whitelisted=False, is_stopped=False):
        """Build HTML table for containers."""
        if not containers:
            return ""
        
        rows_html = ""
        for idx, c in enumerate(containers):
            row_id = f"{section_prefix}-{idx}"
            container_name = c.get("container_name", "")
            lifecycle_id = c.get("lifecycle_id") or ""
            lifecycle_status = (c.get("lifecycle_status") or "").upper()
            decision = c.get("decision", "")
            cpu = c.get("cpu_m", 0)
            mem = c.get("mem_mi", 0)
            net = c.get("net_b", 0)
            reason = c.get("reason", "")
            
            # Status badge
            if is_whitelisted:
                status_html = "<span class='status-whitelisted'>WHITELISTED</span>"
            elif lifecycle_status == "STOPPED" or is_stopped:
                status_html = "<span class='status-stopped'>⏸️ STOPPED</span>"
            elif decision and "STOPPED" in str(decision).upper():
                status_html = "<span class='status-stopped'>⏸️ STOPPED</span>"
            elif lifecycle_status == "PENDING":
                if decision:
                    decision = str(decision).strip()
                    if decision.startswith("🚨"):
                        decision = decision[1:].strip()
                    status_html = f"<span class='status-pending'>🚨 {decision.upper()}</span>"
                else:
                    status_html = "<span class='status-pending'>🚨 PENDING</span>"
            elif decision:
                if decision == "active":
                    status_html = f"<span class='status-active'>✅ {decision.upper()}</span>"
                else:
                    status_html = f"<span>{decision.upper()}</span>"
            else:
                status_html = "<span class='status-active'>ACTIVE</span>"
            
            # Action buttons
            actions_html = ""
            if is_whitelisted:
                actions_html = f'''<button class="btn btn-unwhitelist" onclick="removeFromWhitelist('{tc_name}', '{container_name}', '{row_id}', event);">🔓 화이트리스트 제거</button>'''
            elif is_pending and lifecycle_id:
                actions_html = f'''
                    <button class="btn btn-stop" onclick="stopContainer('{lifecycle_id}', '{row_id}', event);">⏸️ 멈춤</button>
                    <button class="btn btn-whitelist" onclick="addToWhitelist('{tc_name}', '{container_name}', '{row_id}', event);">🛡️ 화이트리스트</button>
                '''
            else:
                actions_html = f'''<button class="btn btn-whitelist" onclick="addToWhitelist('{tc_name}', '{container_name}', '{row_id}', event);">🛡️ 화이트리스트</button>'''
            
            rows_html += f'''
            <tr class="clickable-row" onclick="toggleLog('{row_id}', '{tc_name}', '{container_name}', event)" data-row-id="{row_id}">
                <td>{container_name}</td>
                <td class="metrics">{cpu:.2f}</td>
                <td class="metrics">{mem:.2f}</td>
                <td class="metrics">{net:.2f}</td>
                <td>{status_html}</td>
                <td onclick="event.stopPropagation()">{actions_html}</td>
            </tr>
            <tr id="log-row-{row_id}" class="log-row">
                <td colspan="6" style="padding:0;">
                    <div id="log-{row_id}" class="log-panel">
                        <div class="log-content"></div>
                    </div>
                </td>
            </tr>
            '''
        
        return f'''
        <table>
            <thead>
                <tr>
                    <th>Container</th>
                    <th>CPU (m)</th>
                    <th>MEM (Mi)</th>
                    <th>NET (B)</th>
                    <th>상태</th>
                    <th>액션</th>
                </tr>
            </thead>
            <tbody>
                {rows_html}
            </tbody>
        </table>
        '''

    def _render_zombies_ui(self, message=""):
        """Render zombie management dashboard HTML."""
        zombies = list_pending_zombies()
        
        if not zombies:
            rows_html = "<tr><td colspan='8' class='empty'>🎉 삭제 예정인 좀비 컨테이너가 없습니다.</td></tr>"
        else:
            rows_html = ""
            for z in zombies:
                scheduled = to_kst(z.get("scheduled_delete_at"))
                z_id = z.get('id', '')
                tc_name = z.get('tc_name', '')
                container_name = z.get('container_name', '')
                reason = z.get('reason', '')
                rows_html += f"""
                <tr class="clickable-row" onclick="toggleLog('{z_id}', '{tc_name}', '{container_name}', event)" data-zombie-id="{z_id}">
                    <td>{z_id}</td>
                    <td><strong>{tc_name}</strong>/{container_name}</td>
                    <td class="metrics">{z.get('cpu_m', 0):.2f}</td>
                    <td class="metrics">{z.get('mem_mi', 0):.2f}</td>
                    <td class="metrics">{z.get('net_b', 0):.2f}</td>
                    <td>{scheduled}</td>
                    <td class="status-pending">{z.get('status', '')}</td>
                    <td onclick="event.stopPropagation()">
                        <button class="btn btn-whitelist" onclick="addToWhitelist('{z_id}', '{tc_name}', '{container_name}', event);">🛡️ 화이트리스트</button>
                        <button class="btn btn-stop" onclick="stopZombie('{z_id}', event);">⏸️ 멈춤</button>
                    </td>
                </tr>
                <tr id="log-row-{z_id}" class="log-row">
                    <td colspan="8" style="padding:0;">
                        <div id="log-{z_id}" class="log-panel">
                            <div class="log-content"></div>
                        </div>
                    </td>
                </tr>
                """
        
        html = _render_html_template("zombies.html", message=message, rows=rows_html)
        self._send_html(200, html)

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            self._send_json(200, {"status": "ok"})
            return
        if path == "/ready":
            self._send_json(200, {"status": "ready"})
            return
        if path == "/api/v1/targets":
            try:
                targets = list_registered_targets()
                self._send_json(200, targets)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        if path == "/api/v1/zombies":
            try:
                config = build_config()
                zombies = list_pending_zombies()
                base_url = os.getenv("CJ_BASE_URL", f"http://{self.headers.get('Host', 'localhost:8000')}")
                result = []
                for z in zombies:
                    z["action_urls"] = {
                        "stop": f"{base_url}/api/v1/zombies/{z['id']}/stop",
                        "postpone_30m": f"{base_url}/api/v1/zombies/{z['id']}/postpone?minutes=30",
                        "postpone_1h": f"{base_url}/api/v1/zombies/{z['id']}/postpone?minutes=60",
                        "postpone_24h": f"{base_url}/api/v1/zombies/{z['id']}/postpone?minutes=1440",
                    }
                    result.append(z)
                self._send_json(200, {"count": len(result), "zombies": result})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        
        # GET /api/v1/zombies/<id>
        match = re.fullmatch(r"/api/v1/zombies/(\d+)", path)
        if match:
            try:
                zombie_id = int(match.group(1))
                zombie = get_zombie_by_id(zombie_id)
                if not zombie:
                    self._send_json(404, {"error": "zombie not found"})
                    return
                base_url = os.getenv("CJ_BASE_URL", f"http://{self.headers.get('Host', 'localhost:8000')}")
                zombie["action_urls"] = {
                    "stop": f"{base_url}/api/v1/zombies/{zombie['id']}/stop",
                    "postpone_30m": f"{base_url}/api/v1/zombies/{zombie['id']}/postpone?minutes=30",
                }
                self._send_json(200, zombie)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        
        # GET /api/v1/logs - Fetch logs from Loki
        if path == "/api/v1/logs":
            try:
                parsed_url = urlparse(self.path)
                query_params = parse_qs(parsed_url.query or "", keep_blank_values=False)
                query = (query_params.get("query", [""])[0] or "").strip()
                container_name = (query_params.get("container_name", [""])[0] or "").strip()
                try:
                    limit = int((query_params.get("limit", ["50"])[0] or "50").strip())
                except ValueError:
                    limit = 50
                
                if container_name:
                    result = get_logs_for_container(container_name, limit)
                elif query:
                    result = get_logs_from_loki(query, limit)
                else:
                    self._send_json(400, {"error": "query or container_name parameter is required"})
                    return
                self._send_json(200, result)
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        
        # ── Web UI for Zombie Management (GET requests for email links) ──
        
        # GET /ui/zombies - 웹 대시보드
        if path == "/ui/zombies":
            try:
                self._render_zombies_ui(message="")
            except Exception as e:
                self._send_html(500, f"<h1>Error</h1><p>{str(e)}</p>")
            return
        
        # GET /ui/zombies/<id>/stop - 이메일 링크용 (정식)
        match = re.fullmatch(r"/ui/zombies/(\d+)/stop", path)
        if match:
            try:
                zombie_id = int(match.group(1))
                config = build_config()
                result = stop_zombie(zombie_id, config)
                if result.get("success"):
                    self._render_zombies_ui(f"<div class='result-msg result-success'>✅ 컨테이너 멈춤 처리 완료: {result.get('container_name', '')}</div>")
                else:
                    self._render_zombies_ui(f"<div class='result-msg result-error'>❌ 멈춤 처리 실패: {result.get('error', 'unknown error')}</div>")
            except Exception as e:
                self._render_zombies_ui(f"<div class='result-msg result-error'>❌ 오류: {str(e)}</div>")
            return
        
        # GET /ui/zombies/<id>/postpone - 이메일 링크용
        match = re.fullmatch(r"/ui/zombies/(\d+)/postpone", path)
        if match:
            try:
                zombie_id = int(match.group(1))
                parsed_url = urlparse(self.path)
                query = dict(pair.split('=') for pair in parsed_url.query.split('&') if '=' in pair) if parsed_url.query else {}
                minutes = int(query.get('minutes', 30))
                result = postpone_zombie(zombie_id, minutes)
                if result.get("success"):
                    self._render_zombies_ui(f"<div class='result-msg result-success'>✅ {minutes}분 연기 완료</div>")
                else:
                    self._render_zombies_ui(f"<div class='result-msg result-error'>❌ 연기 실패: {result.get('error', 'unknown error')}</div>")
            except Exception as e:
                self._render_zombies_ui(f"<div class='result-msg result-error'>❌ 오류: {str(e)}</div>")
            return
        
        # GET /ui/containers - 모든 TC 컨테이너 대시보드
        if path == "/ui/containers":
            try:
                self._render_containers_ui(message="")
            except Exception as e:
                self._send_html(500, f"<h1>Error</h1><p>{str(e)}</p>")
            return
        
        self._send_json(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        
        if path == "/api/v1/register":
            try:
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length > 0 else b""
                payload = json.loads(raw.decode("utf-8") or "{}")
            except Exception:
                self._send_json(400, {"error": "invalid json"})
                return
            
            # Use request host so TC can receive an externally reachable Loki URL.
            req_host = self.headers.get("Host", "").split(":")[0].strip()
            result, status = register_tc(payload)
            if status in (200, 201) and isinstance(result, dict):
                result["loki_push_url"] = build_loki_push_url(req_host)
            self._send_json(status, result)
            return

        match = re.fullmatch(r"/api/v1/targets/([^/]+)/whitelist", path)
        if match:
            tc_name = match.group(1)
            try:
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length > 0 else b""
                payload = json.loads(raw.decode("utf-8") or "{}")
            except Exception:
                self._send_json(400, {"error": "invalid json"})
                return

            result, status = update_tc_whitelist(tc_name, payload)
            self._send_json(status, result)
            return
        
        # POST /api/v1/targets/<tc_name>/whitelist/remove - 화이트리스트에서 제거
        match = re.fullmatch(r"/api/v1/targets/([^/]+)/whitelist/remove", path)
        if match:
            tc_name = match.group(1)
            try:
                length = int(self.headers.get("Content-Length", 0))
                raw = self.rfile.read(length) if length > 0 else b""
                payload = json.loads(raw.decode("utf-8") or "{}")
            except Exception:
                self._send_json(400, {"error": "invalid json"})
                return
            
            container_name = payload.get("container_name")
            if not container_name:
                self._send_json(400, {"error": "container_name is required"})
                return
            
            success, msg = remove_from_whitelist(tc_name, container_name)
            if success:
                self._send_json(200, {"message": msg, "tc_name": tc_name, "container_name": container_name})
            else:
                self._send_json(400, {"error": msg})
            return
        
        # POST /api/v1/zombies/<id>/stop - 멈춤 처리 (정식)
        match = re.fullmatch(r"/api/v1/zombies/(\d+)/stop", path)
        if match:
            try:
                zombie_id = int(match.group(1))
                config = build_config()
                result = stop_zombie(zombie_id, config)
                if result.get("success"):
                    self._send_json(200, {"message": "container stopped", **result})
                else:
                    self._send_json(400, {"error": result.get("error", "stop failed")})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        
        # POST /api/v1/zombies/<id>/postpone - 삭제 연기
        match = re.fullmatch(r"/api/v1/zombies/(\d+)/postpone", path)
        if match:
            try:
                zombie_id = int(match.group(1))
                parsed_url = urlparse(self.path)
                query = dict(pair.split('=') for pair in parsed_url.query.split('&') if '=' in pair) if parsed_url.query else {}
                minutes = int(query.get('minutes', 30))
                result = postpone_zombie(zombie_id, minutes)
                if result.get("success"):
                    self._send_json(200, {"message": f"postponed by {minutes} minutes", **result})
                else:
                    self._send_json(400, {"error": result.get("error", "postpone failed")})
            except Exception as e:
                self._send_json(500, {"error": str(e)})
            return
        
        self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        path = urlparse(self.path).path
        # TODO: Implement TC unregistration
        self._send_json(404, {"error": "not implemented"})


def serve():
    """Start HTTP server."""
    bootstrap_runtime_schema()
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    httpd = ThreadingHTTPServer((host, port), RequestHandler)
    print(f"[INFO] Cloud Janitor API server starting on {host}:{port}")
    httpd.serve_forever()


def main():
    default_mode = os.getenv("RUN_MODE", "serve")
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", default=default_mode, choices=["serve", "scan", "cleanup"])
    args = parser.parse_args()
    
    if args.mode == "scan":
        run_scan()
        return
    if args.mode == "cleanup":
        run_cleanup_cycle()
        return
    serve()


if __name__ == "__main__":
    main()
