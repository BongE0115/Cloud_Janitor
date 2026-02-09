import requests
import config

def get_prom_val(query):
    try:
        res = requests.get(f"{config.PROMETHEUS_URL}/api/v1/query", params={'query': query}, timeout=3).json()
        result = res.get('data', {}).get('result', [])
        return float(result[0]['value'][1]) if result else 0.0
    except:
        return 0.0

def get_pod_metrics(ns, name):
    cpu_q = f'sum(rate(container_cpu_usage_seconds_total{{pod="{name}",namespace="{ns}"}}[{config.TIME_WINDOW_CPU}])) * 1000'
    mem_q = f'sum(container_memory_working_set_bytes{{pod="{name}",namespace="{ns}"}}) / 1024 / 1024'
    net_q = f'sum(rate(container_network_receive_bytes_total{{pod="{name}",namespace="{ns}"}}[{config.TIME_WINDOW_NET}]))'
    return {"cpu": get_prom_val(cpu_q), "mem": get_prom_val(mem_q), "net": get_prom_val(net_q)}