import os
import time
import requests
from kubernetes import client, config as k8s_config


def get_k8s_client():
    try:
        # Set local auth file path (~/.kube/config)
        kube_config_path = os.path.expanduser("~/.kube/config")
        
        if os.path.exists(kube_config_path):
            # Home: local (computer/VM) environment
            k8s_config.load_kube_config(config_file=kube_config_path)
            print(">>> [AUTH] 🏠 Using local .kube/config file.")
        else:
            # In-cluster: K8s pod environment
            k8s_config.load_incluster_config()
            print(">>> [AUTH] ☸️ Using in-cluster service account token.")
            
        return client.CoreV1Api()
    except Exception as e:
        print(f">>> [AUTH] ❌ Auth failed: {str(e)}")
        return None


def get_prom_val(url, query):
    """
    Query Prometheus server with PromQL and return numeric result.
    """
    try:
        # Send HTTP request with 3s timeout
        res = requests.get(f"{url}/api/v1/query", params={'query': query}, timeout=3).json()
        result = res.get('data', {}).get('result', [])
        
        # Extract numeric value if result exists
        return float(result[0]['value'][1]) if result else 0.0
    except Exception:
        return 0.0


def get_prom_result(url, query):
    """
    Query Prometheus and return full result list.
    """
    try:
        res = requests.get(f"{url}/api/v1/query", params={'query': query}, timeout=5).json()
        return res.get('data', {}).get('result', [])
    except Exception as e:
        print(f"[WARN] Prometheus query failed: {e}")
        return []


def _sum_network_bytes_from_stats(stats):
    """Return RX+TX cumulative bytes from Docker stats payload."""
    total = 0.0
    networks = (stats or {}).get("networks") or {}
    if not isinstance(networks, dict):
        return total
    for data in networks.values():
        if not isinstance(data, dict):
            continue
        total += float(data.get("rx_bytes", 0.0) or 0.0)
        total += float(data.get("tx_bytes", 0.0) or 0.0)
    return total


def _collect_docker_net_rates(tracked_containers, sample_seconds=1.0):
    """Collect per-container RX+TX bytes/sec from Docker stats."""
    if not tracked_containers:
        return {}

    first = {}
    second = {}

    try:
        for c in tracked_containers:
            try:
                first[c.short_id] = _sum_network_bytes_from_stats(c.stats(stream=False))
            except Exception:
                continue

        time.sleep(max(0.1, float(sample_seconds)))

        for c in tracked_containers:
            try:
                second[c.short_id] = _sum_network_bytes_from_stats(c.stats(stream=False))
            except Exception:
                continue
    except Exception:
        return {}

    rates = {}
    dt = max(0.1, float(sample_seconds))
    for short_id, start_val in first.items():
        if short_id not in second:
            continue
        delta = float(second[short_id]) - float(start_val)
        rates[short_id] = max(0.0, delta / dt)
    return rates


def get_docker_containers_from_prometheus(url):
    """
    Get Docker container metrics from Prometheus/cAdvisor.
    Returns list of containers with name, cpu, mem, net, and labels.
    Uses Docker SDK for container info and Prometheus for metrics.
    """
    import docker
    
    # Get container info from Docker SDK
    container_map = {}
    tracked_containers = []
    docker_client = None
    try:
        docker_client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        for container in docker_client.containers.list():
            # Only get containers in tc-network
            networks = container.attrs.get('NetworkSettings', {}).get('Networks', {})
            if 'tc-network' not in networks:
                continue
            
            labels = container.labels or {}
            container_map[container.short_id] = {
                'name': container.name,
                'short_id': container.short_id,
                'type': labels.get('app-type', ''),
                'zombie_type': labels.get('zombie-type', ''),
            }
            tracked_containers.append(container)
    except Exception as e:
        print(f"[WARN] Failed to get Docker container list: {e}")
        return []
    
    if not container_map:
        print("[WARN] No containers found in tc-network")
        try:
            if docker_client is not None:
                docker_client.close()
        except Exception:
            pass
        return []
    
    containers = {}
    
    # Initialize containers from Docker info
    for short_id, info in container_map.items():
        containers[info['name']] = {
            'name': info['name'],
            'short_id': short_id,
            'image': '',
            'cpu': 0.0,
            'mem': 0.0,
            'net': 0.0,
            'type': info['type'],
            'zombie_type': info['zombie_type'],
        }

    # Preferred: container-level net rate from Docker stats (RX+TX bytes/sec).
    net_rates = {}
    try:
        sample_seconds = float(os.getenv("NET_SAMPLE_SECONDS", "2.0") or 2.0)
        sample_seconds = max(0.3, min(sample_seconds, 10.0))
        net_rates = _collect_docker_net_rates(tracked_containers, sample_seconds=sample_seconds)
    except Exception as e:
        print(f"[WARN] Docker stats network collection failed: {e}")
        net_rates = {}
    finally:
        try:
            if docker_client is not None:
                docker_client.close()
        except Exception:
            pass

    if net_rates:
        for short_id, rate in net_rates.items():
            info = container_map.get(short_id)
            if not info:
                continue
            name = info['name']
            if name in containers:
                containers[name]['net'] = float(rate)
    
    # Query all container CPU metrics from cAdvisor
    cpu_query = 'rate(container_cpu_usage_seconds_total{id=~"/docker/.*"}[2m]) * 1000'
    cpu_results = get_prom_result(url, cpu_query)
    
    for item in cpu_results:
        metric = item.get('metric', {})
        container_id = metric.get('id', '')
        
        # Extract short ID from path like /docker/4bba0df01ff0...
        if container_id.startswith('/docker/'):
            short_id = container_id.split('/')[-1][:12]
        else:
            continue
        
        # Find container name from our map
        if short_id not in container_map:
            continue
        
        name = container_map[short_id]['name']
        cpu_val = float(item.get('value', [0, 0])[1])
        
        # Add CPU value (might be multiple results per container)
        containers[name]['cpu'] += cpu_val
    
    # Query memory
    mem_query = 'container_memory_working_set_bytes{id=~"/docker/.*"}'
    mem_results = get_prom_result(url, mem_query)
    
    for item in mem_results:
        metric = item.get('metric', {})
        container_id = metric.get('id', '')
        
        if container_id.startswith('/docker/'):
            short_id = container_id.split('/')[-1][:12]
        else:
            continue
        
        if short_id not in container_map:
            continue
        
        name = container_map[short_id]['name']
        mem_val = float(item.get('value', [0, 0])[1]) / 1024 / 1024
        containers[name]['mem'] += mem_val
    
    # Fallback: Prometheus network if Docker stats rates are unavailable.
    if not net_rates:
        net_rx_query = 'rate(container_network_receive_bytes_total{id=~"/docker/.*"}[2m])'
        net_tx_query = 'rate(container_network_transmit_bytes_total{id=~"/docker/.*"}[2m])'
        net_results = get_prom_result(url, net_rx_query) + get_prom_result(url, net_tx_query)

        for item in net_results:
            metric = item.get('metric', {})
            container_id = metric.get('id', '')

            if container_id.startswith('/docker/'):
                short_id = container_id.split('/')[-1][:12]
            else:
                continue

            if short_id not in container_map:
                continue

            name = container_map[short_id]['name']
            net_val = float(item.get('value', [0, 0])[1])
            containers[name]['net'] += net_val
    
    return list(containers.values())


def get_docker_containers_fallback(url):
    """
    Return container-like rows for janitor scanning.
    Prefer Docker SDK mapping when available; otherwise use Prometheus id-only metrics.
    """
    containers = get_docker_containers_from_prometheus(url)
    if containers:
        return containers

    # Fallback for in-cluster runs where docker.sock is unavailable:
    # build rows from Prometheus id labels only.
    cpu_query = 'rate(container_cpu_usage_seconds_total{id=~"/docker/[a-f0-9]{64}",cpu="total"}[2m]) * 1000'
    mem_query = 'container_memory_working_set_bytes{id=~"/docker/[a-f0-9]{64}"}'
    net_query = 'rate(container_network_receive_bytes_total{id=~"/docker/[a-f0-9]{64}"}[2m])'
    # IOPS = I/O Operations Per Second (not bytes!)
    iops_read_query = 'rate(container_fs_reads_total{id=~"/docker/[a-f0-9]{64}"}[2m])'
    iops_write_query = 'rate(container_fs_writes_total{id=~"/docker/[a-f0-9]{64}"}[2m])'

    cpu_results = get_prom_result(url, cpu_query)
    if not cpu_results:
        # Right after cadvisor restart, rate windows may be empty.
        # Fallback to existence metric to keep scan output non-empty.
        cpu_results = get_prom_result(url, 'container_last_seen{id=~"/docker/[a-f0-9]{64}"}')
    mem_results = get_prom_result(url, mem_query)
    net_results = get_prom_result(url, net_query)
    iops_read_results = get_prom_result(url, iops_read_query)
    iops_write_results = get_prom_result(url, iops_write_query)

    rows = {}
    loki_map = get_loki_container_map()

    for item in cpu_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if not cid:
            continue
        short = cid.split('/')[-1][:12]
        mapped = loki_map.get(short, {})
        mapped_name = mapped.get('compose_service') or mapped.get('container_name')
        rows[cid] = {
            'name': mapped_name or f"container-{short}",
            'short_id': short,
            'image': '',
            'cpu': float(item.get('value', [0, 0])[1]) if metric.get('__name__') != 'container_last_seen' else 0.0,
            'mem': 0.0,
            'net': 0.0,
            'iops_read': 0.0,
            'iops_write': 0.0,
            'type': infer_type_from_name(mapped_name),
            'zombie_type': '',
        }
        compose_name = metric.get('container_label_com_docker_compose_service')
        if compose_name:
            rows[cid]['name'] = compose_name
            rows[cid]['type'] = infer_type_from_name(compose_name)

    for item in mem_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if cid not in rows:
            continue
        rows[cid]['mem'] = float(item.get('value', [0, 0])[1]) / 1024 / 1024

    # Some environments expose network only at root id=/.
    # Keep net default 0.0 when per-container series are not available.
    for item in net_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if cid not in rows:
            continue
        rows[cid]['net'] += float(item.get('value', [0, 0])[1])

    # IOPS metrics (I/O Operations Per Second)
    for item in iops_read_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if cid not in rows:
            continue
        rows[cid]['iops_read'] = float(item.get('value', [0, 0])[1])

    for item in iops_write_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if cid not in rows:
            continue
        rows[cid]['iops_write'] = float(item.get('value', [0, 0])[1])

    return list(rows.values())


def infer_type_from_name(name):
    if not name:
        return 'unknown'
    if 'zombie' in name:
        return 'zombie'
    if 'active' in name:
        return 'active'
    return 'unknown'


def get_loki_container_map():
    """
    Build map: short_container_id -> {container_name, compose_service}
    from Loki tc-docker streams.
    """
    loki_url = os.getenv("LOKI_URL", "http://loki.monitoring.svc.cluster.local:3100")
    end_ns = int(time.time() * 1_000_000_000)
    start_ns = end_ns - (6 * 60 * 60 * 1_000_000_000)  # last 6h
    mapping = {}

    try:
        res = requests.get(
            f"{loki_url}/loki/api/v1/series",
            params={
                "match[]": '{job="tc-docker"}',
                "start": str(start_ns),
                "end": str(end_ns),
            },
            timeout=5,
        )
        data = res.json().get("data", [])
        for labels in data:
            cid = labels.get("container_id")
            if not cid:
                continue
            mapping[cid] = {
                "container_name": labels.get("container_name", ""),
                "compose_service": labels.get("compose_service", ""),
            }
    except Exception:
        # mapping is optional fallback; ignore errors
        return {}

    return mapping
