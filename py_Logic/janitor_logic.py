import logging
import time
from .metrics import get_prom_val, get_prom_result, get_docker_containers_fallback
from .database import save_billing_and_delete, save_latest_scan_snapshot

# 로그 기록 방식 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("SuperJanitor")


def run_janitor(config):
    """Scan TC Docker containers and find zombies based on metrics."""
    
    prom_url = config.get('PROMETHEUS_URL', 'http://localhost:9091')
    tc_name = config.get('TARGET_NAME', 'tc-target')
    container_map = config.get('CONTAINER_MAP', {}) or {}
    whitelist = {str(x).strip().lower() for x in config.get('CONTAINER_WHITELIST', []) if str(x).strip()}
    cycle_id = int(time.time())

    def _q(value):
        """Quote value for logfmt-like structured logs."""
        text = str(value).replace("\\", "\\\\").replace('"', '\\"')
        return f'"{text}"'
    
    logger.info(f"🎯 소탕 작전 시작 (TC: {tc_name}, 모드: {'테스트' if config['DRY_RUN'] else '실전'})")
    logger.info(f"📡 Prometheus URL: {prom_url}")
    logger.info(f"SCAN_CYCLE_START cycle={cycle_id} tc={_q(tc_name)}")

    if not container_map:
        logger.warning("SCAN_SKIPPED cycle=%s tc=%s reason=%s", cycle_id, _q(tc_name), _q("empty container_map"))
        return
    
    # Get Docker containers from TC Prometheus (cAdvisor metrics)
    try:
        containers = get_docker_containers_fallback(prom_url)
        if not containers:
            logger.warning("⚠️ No containers found from Prometheus")
            containers = []
    except Exception as e:
        logger.error(f"❌ Error getting containers from Prometheus: {e}")
        containers = []

    # TC-reported container_map is the source of truth for "which containers exist".
    # cAdvisor metrics are used as supplemental values.
    metrics_by_id = {}
    for item in containers:
        sid = item.get("short_id")
        if sid:
            metrics_by_id[sid] = item

    merged_containers = []
    for sid, meta in container_map.items():
        metric = metrics_by_id.get(sid, {})
        merged_containers.append({
            "name": metric.get("name") or meta.get("name") or sid,
            "short_id": sid,
            "cpu": float(metric.get("cpu", 0.0)),
            "mem": float(metric.get("mem", 0.0)),
            "net": float(metric.get("net", 0.0)),
            "type": metric.get("type") or meta.get("type") or "unknown",
            "zombie_type": metric.get("zombie_type") or meta.get("zombie_type") or "",
        })

    # If map is unexpectedly empty, fallback to metrics-only path.
    containers = merged_containers if merged_containers else containers
    
    # Print header for output
    print(f"\n{'TC/CONTAINER':<38} {'CPU(m)':>10} {'MEM(Mi)':>10} {'NET(B)':>10} {'TYPE':<15} {'DECISION':<30} {'REASON'}")
    print("-" * 150)
    
    zombie_count = 0
    candidate_count = 0
    active_count = 0
    safe_count = 0
    snapshot_rows = []
    
    for container in containers:
        name = container['name']
        short_id = container.get('short_id')
        cpu_val = container['cpu']
        mem_val = container['mem']
        net_val = container['net']
        app_type = container.get('type', '')
        zombie_type = container.get('zombie_type', '')
        type_str = f"{app_type}/{zombie_type}" if zombie_type else app_type
        display_name = f"{tc_name}/{name}"
        alias = container_map.get(short_id, {}) if short_id else {}
        alias_name = alias.get('name') if isinstance(alias, dict) else None
        if alias_name:
            display_name = f"{tc_name}/{alias_name}"
            if app_type == 'unknown':
                app_type = alias.get('type', app_type)
                zombie_type = alias.get('zombie_type', zombie_type)
                type_str = f"{app_type}/{zombie_type}" if zombie_type else app_type
        if not app_type and short_id:
            display_name = f"{tc_name}/{short_id}"

        # TC-side whitelist: do not treat system containers as zombie/candidate.
        effective_name = (alias_name or name or "").lower()
        if effective_name in whitelist:
            decision = "🛡️ SAFE (WhiteList)"
            reason = "container whitelist"
            safe_count += 1
            snapshot_rows.append({
                "container_name": alias_name or name,
                "tc_container": display_name,
                "cpu_m": cpu_val,
                "mem_mi": mem_val,
                "net_b": net_val,
                "ctype": type_str or "unknown",
                "decision": "SAFE_WHITELIST",
                "reason": reason,
            })
            print(f"{display_name:<38} {cpu_val:>10.2f} {mem_val:>10.2f} {net_val:>10.2f} {type_str:<15} {decision:<30} {reason}")
            logger.info(
                "SCAN_CONTAINER cycle=%s tc=%s container=%s tc_container=%s cpu_m=%.2f mem_mi=%.2f net_b=%.2f ctype=%s decision=%s reason=%s",
                cycle_id,
                _q(tc_name),
                _q(alias_name or name),
                _q(display_name),
                cpu_val,
                mem_val,
                net_val,
                _q(type_str or "unknown"),
                _q("SAFE_WHITELIST"),
                _q(reason),
            )
            continue
        
        # Decision logic for TC Docker containers
        # Zombie: app-type=zombie label AND low CPU AND low network
        if app_type == 'zombie':
            if cpu_val < config['LIMIT_CPU_M'] and net_val < config['LIMIT_NET_B']:
                decision = "🚨 ZOMBIE DETECTED"
                reason = f"label=zombie && cpu<{config['LIMIT_CPU_M']} && net<{config['LIMIT_NET_B']}"
                zombie_count += 1
            else:
                decision = "👍 ACTIVE (zombie but active)"
                reason = f"label=zombie but cpu/net above threshold"
                active_count += 1
        elif app_type == 'active':
            decision = "✅ ACTIVE (normal app)"
            reason = "label=active"
            active_count += 1
        else:
            # Unknown containers - check by metrics only
            if cpu_val < config['LIMIT_CPU_M'] and net_val < config['LIMIT_NET_B']:
                decision = "🔍 CANDIDATE (low metrics)"
                reason = f"cpu<{config['LIMIT_CPU_M']} && net<{config['LIMIT_NET_B']}"
                candidate_count += 1
            else:
                decision = "👍 ACTIVE"
                reason = "metrics above threshold"
                active_count += 1
        
        # Print result line (this goes to Loki)
        snapshot_rows.append({
            "container_name": alias_name or name,
            "tc_container": display_name,
            "cpu_m": cpu_val,
            "mem_mi": mem_val,
            "net_b": net_val,
            "ctype": type_str or "unknown",
            "decision": decision,
            "reason": reason,
        })
        print(f"{display_name:<38} {cpu_val:>10.2f} {mem_val:>10.2f} {net_val:>10.2f} {type_str:<15} {decision:<30} {reason}")
        logger.info(
            "SCAN_CONTAINER cycle=%s tc=%s container=%s tc_container=%s cpu_m=%.2f mem_mi=%.2f net_b=%.2f ctype=%s decision=%s reason=%s",
            cycle_id,
            _q(tc_name),
            _q(alias_name or name),
            _q(display_name),
            cpu_val,
            mem_val,
            net_val,
            _q(type_str or "unknown"),
            _q(decision),
            _q(reason),
        )
        
        # If zombie and not dry_run, delete via Docker API
        if decision == "🚨 ZOMBIE DETECTED" and not config['DRY_RUN']:
            try:
                import docker
                client = docker.DockerClient(base_url=config.get('DOCKER_API_URL', 'unix:///var/run/docker.sock'))
                container_obj = client.containers.get(name)
                container_obj.remove(force=True)
                logger.info(f"💥 [Deleted] {name}")
            except Exception as e:
                logger.error(f"❌ Failed to delete {name}: {e}")
    
    print("-" * 150)
    logger.info(f"📊 Summary: {zombie_count} zombies, {candidate_count} candidates, {active_count} active, {safe_count} safe")
    logger.info(
        f"SUMMARY_METRICS zombie={zombie_count} candidate={candidate_count} active={active_count} safe={safe_count}"
    )
    logger.info(
        "SCAN_CYCLE_END cycle=%s tc=%s zombie=%s candidate=%s active=%s safe=%s",
        cycle_id,
        _q(tc_name),
        zombie_count,
        candidate_count,
        active_count,
        safe_count,
    )

    try:
        save_latest_scan_snapshot(
            tc_name=tc_name,
            cycle_id=cycle_id,
            summary={
                "zombie": zombie_count,
                "candidate": candidate_count,
                "active": active_count,
                "safe": safe_count,
            },
            rows=snapshot_rows,
        )
    except Exception as e:
        logger.error("SNAPSHOT_SAVE_FAILED cycle=%s tc=%s error=%s", cycle_id, _q(tc_name), _q(str(e)))
