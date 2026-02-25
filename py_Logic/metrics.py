import os
import time
import re
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


def get_prometheus_network_avg_rates(url, window="5m"):
    """
    Return per-container average network bytes/sec (RX+TX) from Prometheus.
    Uses subquery averaging to smooth short spikes/idle gaps.
    """
    window = str(window or "5m").strip() or "5m"
    selector = f'id=~"{_CADVISOR_DOCKER_ID_MATCHER}"'
    # Interval average: Prometheus rate already returns average bytes/sec over [window].
    rx_query = f'rate(container_network_receive_bytes_total{{{selector}}}[{window}])'
    tx_query = f'rate(container_network_transmit_bytes_total{{{selector}}}[{window}])'

    rates = {}
    for item in get_prom_result(url, rx_query) + get_prom_result(url, tx_query):
        metric = item.get("metric", {})
        container_id = metric.get("id", "")
        short_id = _extract_short_id_from_cgroup_id(container_id)
        if not short_id:
            continue
        try:
            value = float(item.get("value", [0, 0])[1])
        except Exception:
            value = 0.0
        rates[short_id] = rates.get(short_id, 0.0) + max(0.0, value)
    return rates


# =============================================================================
# Docker Stats API - 모든 메트릭을 Docker SDK로 직접 수집
# WSL/Ubuntu/macOS 모두에서 동일하게 작동
# =============================================================================

def _calculate_cpu_percent(stats):
    """
    Docker stats에서 CPU 사용률 계산
    Docker SDK의 stats는 cumulative 값이므로 이전 샘플과의 차이로 계산
    """
    try:
        cpu_stats = stats.get('cpu_stats', {})
        precpu_stats = stats.get('precpu_stats', {})
        
        cpu_usage = cpu_stats.get('cpu_usage', {})
        precpu_usage = precpu_stats.get('cpu_usage', {})
        
        # Total CPU time (nanoseconds)
        cpu_delta = cpu_usage.get('total_usage', 0) - precpu_usage.get('total_usage', 0)
        
        # System CPU time (nanoseconds)
        system_delta = cpu_stats.get('system_cpu_usage', 0) - precpu_stats.get('system_cpu_usage', 0)
        
        # Number of CPUs
        online_cpus = cpu_stats.get('online_cpus', 1)
        if online_cpus == 0:
            online_cpus = len(cpu_usage.get('percpu_usage', [])) or 1
        
        if system_delta > 0 and cpu_delta >= 0:
            cpu_percent = (cpu_delta / system_delta) * online_cpus * 100.0
            return max(0.0, cpu_percent)
        
        return 0.0
    except Exception:
        return 0.0


def _calculate_cpu_millicores(stats, sample_interval=1.0):
    """
    CPU 사용량을 millicores (m)로 변환
    1000m = 1 CPU core
    """
    cpu_percent = _calculate_cpu_percent(stats)
    # percent to millicores: 100% = 1000m per core
    return cpu_percent * 10.0  # 1% = 10m


def _get_memory_mb(stats):
    """
    메모리 사용량을 MB로 반환
    """
    try:
        memory_stats = stats.get('memory_stats', {})
        usage = memory_stats.get('usage', 0)
        # Convert bytes to MB
        return usage / (1024 * 1024)
    except Exception:
        return 0.0


def _get_network_bytes_per_sec(stats, prev_stats, sample_interval=1.0):
    """
    네트워크 사용량을 bytes/sec로 계산
    """
    try:
        if not prev_stats:
            return 0.0
            
        curr_networks = stats.get('networks', {})
        prev_networks = prev_stats.get('networks', {})
        
        if not curr_networks or not prev_networks:
            return 0.0
        
        curr_total = 0
        prev_total = 0
        
        for iface, data in curr_networks.items():
            curr_total += data.get('rx_bytes', 0) + data.get('tx_bytes', 0)
        
        for iface, data in prev_networks.items():
            prev_total += data.get('rx_bytes', 0) + data.get('tx_bytes', 0)
        
        delta = curr_total - prev_total
        if delta < 0:
            delta = 0
        
        return delta / max(sample_interval, 0.1)
    except Exception:
        return 0.0


def get_docker_containers_from_docker_stats():
    """
    Docker Stats API만 사용하여 모든 메트릭 수집
    Prometheus/cAdvisor 불필요
    WSL/Ubuntu/macOS 모두에서 동일하게 작동
    
    Returns:
        list: [{name, short_id, cpu, mem, net, type, zombie_type}, ...]
    """
    import docker
    
    containers = []
    docker_client = None
    
    try:
        docker_client = docker.DockerClient(base_url='unix:///var/run/docker.sock')
        
        # tc-network에 있는 컨테이너만 필터링
        container_list = []
        for container in docker_client.containers.list():
            networks = container.attrs.get('NetworkSettings', {}).get('Networks', {})
            if 'tc-network' in networks:
                container_list.append(container)
        
        if not container_list:
            print("[INFO] No containers found in tc-network")
            return []
        
        # 첫 번째 샘플 수집
        first_stats = {}
        for container in container_list:
            try:
                first_stats[container.short_id] = container.stats(stream=False)
            except Exception as e:
                print(f"[WARN] Failed to get stats for {container.name}: {e}")
                continue
        
        # 샘플 간격 대기 (CPU 계산을 위해)
        sample_interval = float(os.getenv("NET_SAMPLE_SECONDS", "1.5") or 1.5)
        time.sleep(sample_interval)
        
        # 두 번째 샘플 수집 및 메트릭 계산
        for container in container_list:
            try:
                labels = container.labels or {}
                first = first_stats.get(container.short_id, {})
                second = container.stats(stream=False)
                
                # CPU 계산 (millicores)
                cpu_m = _calculate_cpu_millicores(second)
                
                # 메모리 (MB)
                mem_mb = _get_memory_mb(second)
                
                # 네트워크 (bytes/sec)
                net_bps = _get_network_bytes_per_sec(second, first, sample_interval)
                
                containers.append({
                    'name': container.name,
                    'short_id': container.short_id,
                    'image': container.attrs.get('Config', {}).get('Image', ''),
                    'cpu': round(cpu_m, 2),
                    'mem': round(mem_mb, 2),
                    'net': round(net_bps, 2),
                    'type': labels.get('app-type', '') or infer_type_from_name(container.name),
                    'zombie_type': labels.get('zombie-type', ''),
                })
            except Exception as e:
                print(f"[WARN] Failed to process container {container.name}: {e}")
                continue
                
    except Exception as e:
        print(f"[ERROR] Docker Stats collection failed: {e}")
        return []
    finally:
        if docker_client:
            try:
                docker_client.close()
            except Exception:
                pass
    
    return containers


def get_docker_containers_from_prometheus(url):
    """
    [LEGACY] Get Docker container metrics from Prometheus/cAdvisor.
    Docker Stats가 실패할 때만 사용하는 폴백
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
    cpu_query = f'rate(container_cpu_usage_seconds_total{{id=~"{_CADVISOR_DOCKER_ID_MATCHER}"}}[2m]) * 1000'
    cpu_results = get_prom_result(url, cpu_query)
    
    for item in cpu_results:
        metric = item.get('metric', {})
        container_id = metric.get('id', '')

        short_id = _extract_short_id_from_cgroup_id(container_id)
        if not short_id:
            continue
        
        # Find container name from our map
        if short_id not in container_map:
            continue
        
        name = container_map[short_id]['name']
        cpu_val = float(item.get('value', [0, 0])[1])
        
        # Add CPU value (might be multiple results per container)
        containers[name]['cpu'] += cpu_val
    
    # Query memory
    mem_query = f'container_memory_working_set_bytes{{id=~"{_CADVISOR_DOCKER_ID_MATCHER}"}}'
    mem_results = get_prom_result(url, mem_query)
    
    for item in mem_results:
        metric = item.get('metric', {})
        container_id = metric.get('id', '')

        short_id = _extract_short_id_from_cgroup_id(container_id)
        if not short_id:
            continue
        
        if short_id not in container_map:
            continue
        
        name = container_map[short_id]['name']
        mem_val = float(item.get('value', [0, 0])[1]) / 1024 / 1024
        containers[name]['mem'] += mem_val
    
    # Fallback: Prometheus network if Docker stats rates are unavailable.
    if not net_rates:
        net_rx_query = f'rate(container_network_receive_bytes_total{{id=~"{_CADVISOR_DOCKER_ID_MATCHER}"}}[2m])'
        net_tx_query = f'rate(container_network_transmit_bytes_total{{id=~"{_CADVISOR_DOCKER_ID_MATCHER}"}}[2m])'
        net_results = get_prom_result(url, net_rx_query) + get_prom_result(url, net_tx_query)

        for item in net_results:
            metric = item.get('metric', {})
            container_id = metric.get('id', '')

            short_id = _extract_short_id_from_cgroup_id(container_id)
            if not short_id:
                continue

            if short_id not in container_map:
                continue

            name = container_map[short_id]['name']
            net_val = float(item.get('value', [0, 0])[1])
            containers[name]['net'] += net_val
    
    return list(containers.values())


def get_docker_containers_fallback(url):
    """
    [LEGACY] Return container-like rows for janitor scanning.
    Prefer Docker SDK mapping when available; otherwise use Prometheus id-only metrics.
    """
    containers = get_docker_containers_from_prometheus(url)
    if containers:
        return containers

    # Fallback for in-cluster runs where docker.sock is unavailable:
    # build rows from Prometheus id labels only.
    docker_id_selector = f'id=~"{_CADVISOR_DOCKER_ID_MATCHER}"'
    cpu_query = f'rate(container_cpu_usage_seconds_total{{{docker_id_selector},cpu="total"}}[2m]) * 1000'
    mem_query = f'container_memory_working_set_bytes{{{docker_id_selector}}}'
    net_query = f'rate(container_network_receive_bytes_total{{{docker_id_selector}}}[2m])'

    cpu_results = get_prom_result(url, cpu_query)
    if not cpu_results:
        cpu_results = get_prom_result(url, f'container_last_seen{{{docker_id_selector}}}')
    mem_results = get_prom_result(url, mem_query)
    net_results = get_prom_result(url, net_query)

    rows = {}
    loki_map = get_loki_container_map()

    for item in cpu_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if not cid:
            continue
        short = _extract_short_id_from_cgroup_id(cid)
        if not short:
            continue
        mapped = loki_map.get(short, {})
        mapped_name = mapped.get('compose_service') or mapped.get('container_name')
        rows[cid] = {
            'name': mapped_name or f"container-{short}",
            'short_id': short,
            'image': '',
            'cpu': float(item.get('value', [0, 0])[1]) if metric.get('__name__') != 'container_last_seen' else 0.0,
            'mem': 0.0,
            'net': 0.0,
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

    for item in net_results:
        metric = item.get('metric', {})
        cid = metric.get('id', '')
        if cid not in rows:
            continue
        rows[cid]['net'] += float(item.get('value', [0, 0])[1])

    return list(rows.values())


# =============================================================================
# Helper Functions (Prometheus 폴백용)
# =============================================================================

_CADVISOR_DOCKER_ID_MATCHER = r'.*(/docker/[a-f0-9]{12,64}|docker-[a-f0-9]{12,64}\\.scope).*'


def _extract_short_id_from_cgroup_id(cgroup_id):
    """
    Extract Docker short id from cAdvisor 'id' label across cgroup layouts.
    """
    text = str(cgroup_id or "")
    if not text:
        return ""

    patterns = (
        r"/docker/([a-f0-9]{12,64})$",
        r"docker-([a-f0-9]{12,64})\.scope$",
        r"/([a-f0-9]{64})(?:$|[/.])",
    )
    for pat in patterns:
        m = re.search(pat, text)
        if m:
            return m.group(1)[:12]
    return ""


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
        return {}

    return mapping
