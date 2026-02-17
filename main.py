import os
import sys
import json
import argparse
import requests
import socket
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse
from dotenv import load_dotenv
import re

# Add py_Logic to Python path
sys.path.append(os.path.join(os.path.dirname(__file__), 'py_Logic'))

# Load .env file
load_dotenv()

try:
    from py_Logic.janitor_logic import run_janitor
    from py_Logic.database import (
        upsert_registered_target,
        list_registered_targets,
        get_latest_registered_target,
        delete_registered_target,
        get_registered_target,
        update_target_labels,
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
    """Get host IP that kind cluster can use to reach host services."""
    import socket
    
    # Try to get the host's IP that kind can reach
    # kind clusters use the host's docker bridge network
    try:
        # Method 1: Check for docker bridge IP
        result = os.popen("ip route show default | awk '/default/ {print $3}'").read().strip()
        if result and result != "":
            return result
    except Exception:
        pass
    
    try:
        # Method 2: Get IP from hostname
        hostname = socket.gethostname()
        host_ip = socket.gethostbyname(hostname)
        if host_ip and not host_ip.startswith("127."):
            return host_ip
    except Exception:
        pass
    
    try:
        # Method 3: Get IP from network interface
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        host_ip = s.getsockname()[0]
        s.close()
        return host_ip
    except Exception:
        pass
    
    # Fallback: Use host.docker.internal (works on Docker Desktop)
    return "host.docker.internal"


def create_tc_prometheus_service(v1, namespace, tc_info):
    """Create Service pointing to TC Prometheus (external)."""
    service_name = "prometheus"
    prometheus_url = tc_info.get("prometheus_url", "")
    tc_ip = tc_info.get("tc_ip", "")
    
    if not prometheus_url:
        print("[ERROR] No prometheus_url provided")
        return False
    
    # Parse Prometheus URL
    parsed = urlparse(prometheus_url)
    hostname = parsed.hostname or "localhost"
    port = parsed.port or 9091
    
    # Resolve IP address for Endpoints (K8s Endpoints require IP, not hostname)
    # If hostname is localhost or 127.0.0.1, use tc_ip or detect host IP
    if hostname in ("localhost", "127.0.0.1", "0.0.0.0"):
        # TC is on the same host as cj
        if tc_ip and tc_ip != "unknown":
            endpoint_ip = tc_ip
        else:
            # Get host IP that kind can reach
            endpoint_ip = get_host_ip_for_kind()
    else:
        # TC is on a remote host - use the IP directly if it's an IP
        # or try to resolve the hostname
        try:
            import socket
            endpoint_ip = socket.gethostbyname(hostname)
        except Exception:
            # If hostname resolution fails, assume it's already an IP
            endpoint_ip = hostname
    
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
    
    # Create Service
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
            cluster_ip="None",  # Headless service for external endpoints
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
        "TARGET_NAME": os.getenv('TARGET_NAME', 'tc-target'),
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
            print(f"[INFO] Using internal Prometheus URL: {internal_url}")
    except Exception as e:
        print(f"[WARN] Could not get latest target: {e}")
    
    return config


def run_scan():
    """Run janitor scan."""
    config = build_config()
    if not config.get("SCAN_ENABLED"):
        print(f"[WARN] scan skipped: {config.get('SCAN_SKIP_REASON', 'target not ready')}")
        return
    run_janitor(config)


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
    
    return {
        "message": "registered",
        "tc_name": tc_name,
        "namespace": namespace,
        "internal_prometheus_url": tc_info["internal_prometheus_url"]
    }, 200


def update_tc_whitelist(tc_name, payload):
    """Update TC container whitelist only."""
    whitelist = payload.get("container_whitelist")
    if not isinstance(whitelist, list):
        return {"error": "container_whitelist must be a list"}, 400

    sanitized = []
    for item in whitelist:
        text = str(item).strip()
        if text:
            sanitized.append(text)

    target = get_registered_target(tc_name)
    if not target:
        return {"error": f"target not found: {tc_name}"}, 404

    labels = target.get("labels") or {}
    if not isinstance(labels, dict):
        labels = {}
    labels["container_whitelist"] = sanitized

    if not update_target_labels(tc_name, labels):
        return {"error": "failed to update whitelist"}, 500

    return {
        "message": "whitelist updated",
        "tc_name": tc_name,
        "container_whitelist": sanitized,
    }, 200


class RequestHandler(BaseHTTPRequestHandler):
    def _send_json(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

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
            
            result, status = register_tc(payload)
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
        
        self._send_json(404, {"error": "not found"})

    def do_DELETE(self):
        path = urlparse(self.path).path
        # TODO: Implement TC unregistration
        self._send_json(404, {"error": "not implemented"})


def serve():
    """Start HTTP server."""
    host = os.getenv("HOST", "0.0.0.0")
    port = int(os.getenv("PORT", "8000"))
    httpd = ThreadingHTTPServer((host, port), RequestHandler)
    print(f"[INFO] Cloud Janitor API server starting on {host}:{port}")
    httpd.serve_forever()


def main():
    default_mode = os.getenv("RUN_MODE", "serve")
    parser = argparse.ArgumentParser()
    parser.add_argument("mode", nargs="?", default=default_mode, choices=["serve", "scan"])
    args = parser.parse_args()
    
    if args.mode == "scan":
        run_scan()
        return
    serve()


if __name__ == "__main__":
    main()
