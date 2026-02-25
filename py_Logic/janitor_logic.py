import logging
import shutil
import subprocess
import time
from .metrics import (
    get_prom_val,
    get_docker_containers_fallback,
    get_docker_containers_from_docker_stats,
    get_prometheus_network_avg_rates,
)
from .database import (
    add_or_update_zombie,
    get_stopped_overrides,
    mark_recovered_pendings,
    process_cleanup,
    save_latest_scan_snapshot,
)

# 로그 기록 방식 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("SuperJanitor")


def _normalize_container_name(name):
    text = str(name or "").strip().lower()
    if text.startswith("/"):
        text = text[1:]
    return text


def get_runtime_state_map(config, container_map, extra_short_ids=None):
    """
    Return runtime state for tracked short IDs.
    Priority: Docker SDK -> docker CLI fallback.
    """
    short_ids = [str(sid).strip() for sid in (container_map or {}).keys() if str(sid).strip()]
    if extra_short_ids:
        for sid in extra_short_ids:
            value = str(sid).strip()
            if value and value not in short_ids:
                short_ids.append(value)
    if not short_ids:
        return {}

    state_map = {}
    docker_url = config.get("DOCKER_API_URL", "unix:///var/run/docker.sock")

    # Prefer Docker SDK (respects DOCKER_API_URL).
    try:
        import docker
        client = docker.DockerClient(base_url=docker_url)
        try:
            for sid in short_ids:
                try:
                    c = client.containers.get(sid)
                    state = ((c.attrs or {}).get("State") or {}).get("Status") or c.status or ""
                    state_map[sid] = {
                        "state": str(state).lower(),
                        "name": getattr(c, "name", "") or "",
                    }
                except Exception as e:
                    msg = str(e).lower()
                    if "not found" in msg or "404" in msg:
                        state_map[sid] = {"state": "not_found", "name": ""}
                    else:
                        logger.debug("RUNTIME_STATE_LOOKUP_FAILED sid=%s error=%s", sid, str(e))
        finally:
            try:
                client.close()
            except Exception:
                pass

        if state_map:
            return state_map
    except Exception as e:
        logger.debug("RUNTIME_STATE_DOCKER_SDK_UNAVAILABLE error=%s", str(e))

    # Fallback: docker CLI (local daemon only).
    if not shutil.which("docker"):
        return {}

    try:
        cli = subprocess.run(
            ["docker", "ps", "-a", "--format", "{{.ID}}|{{.State}}|{{.Names}}"],
            capture_output=True,
            text=True,
            check=False,
            timeout=10,
        )
        if cli.returncode != 0:
            logger.debug("RUNTIME_STATE_DOCKER_CLI_FAILED error=%s", (cli.stderr or "").strip())
            return {}

        by_short = {}
        for raw in (cli.stdout or "").splitlines():
            line = raw.strip()
            if not line:
                continue
            parts = line.split("|", 2)
            if len(parts) != 3:
                continue
            cid, state, name = parts[0].strip(), parts[1].strip().lower(), parts[2].strip()
            if not cid:
                continue
            by_short[cid[:12]] = {"state": state, "name": name}

        for sid in short_ids:
            state_map[sid] = by_short.get(sid, {"state": "not_found", "name": ""})
        return state_map
    except Exception as e:
        logger.debug("RUNTIME_STATE_DOCKER_CLI_EXCEPTION error=%s", str(e))
        return {}


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
    
    # Get Docker containers directly from Docker Stats API
    # This is more reliable and works on WSL/Ubuntu/macOS equally
    try:
        containers = get_docker_containers_from_docker_stats()
        if not containers:
            logger.warning("⚠️ No containers found from Docker Stats, trying Prometheus fallback")
            containers = get_docker_containers_fallback(prom_url)
    except Exception as e:
        logger.error(f"❌ Error getting containers from Docker Stats: {e}")
        try:
            containers = get_docker_containers_fallback(prom_url)
        except Exception as e2:
            logger.error(f"❌ Prometheus fallback also failed: {e2}")
            containers = []

    net_avg_window = str(
        config.get("NET_AVG_WINDOW", config.get("TIME_WINDOW_NET", "5m")) or "5m"
    ).strip() or "5m"
    prom_net_rates = {}
    try:
        prom_net_rates = get_prometheus_network_avg_rates(prom_url, net_avg_window)
    except Exception as e:
        logger.warning("PROM_NET_AVG_FAILED tc=%s error=%s", _q(tc_name), _q(str(e)))

    # TC-reported container_map is the source of truth for "which containers exist".
    # cAdvisor metrics are used as supplemental values.
    metrics_by_id = {}
    metrics_by_name = {}
    for item in containers:
        sid = item.get("short_id")
        if sid:
            metrics_by_id[sid] = item
            if sid in prom_net_rates:
                item["net"] = float(prom_net_rates.get(sid, 0.0))
        name_key = _normalize_container_name(item.get("name"))
        if name_key and name_key not in metrics_by_name:
            metrics_by_name[name_key] = item

    aliases_by_name = {}
    for sid, meta in container_map.items():
        if not isinstance(meta, dict):
            continue
        name_key = _normalize_container_name(meta.get("name"))
        if name_key and name_key not in aliases_by_name:
            aliases_by_name[name_key] = (sid, meta)

    merged_containers = []
    for sid, meta in container_map.items():
        metric = metrics_by_id.get(sid)
        if not metric and isinstance(meta, dict):
            metric = metrics_by_name.get(_normalize_container_name(meta.get("name")))
        metric = metric or {}
        resolved_short_id = str(metric.get("short_id") or sid)
        net_bps = prom_net_rates.get(resolved_short_id)
        if net_bps is None:
            net_bps = prom_net_rates.get(sid)
        if net_bps is None:
            net_bps = float(metric.get("net", 0.0))
        merged_containers.append({
            "name": metric.get("name") or meta.get("name") or sid,
            "short_id": resolved_short_id,
            "map_short_id": sid,
            "cpu": float(metric.get("cpu", 0.0)),
            "mem": float(metric.get("mem", 0.0)),
            "net": float(net_bps),
            "iops_read": float(metric.get("iops_read", 0.0)),
            "iops_write": float(metric.get("iops_write", 0.0)),
            "type": metric.get("type") or meta.get("type") or "unknown",
            "zombie_type": metric.get("zombie_type") or meta.get("zombie_type") or "",
        })

    # If map is unexpectedly empty, fallback to metrics-only path.
    containers = merged_containers if merged_containers else containers
    
    # Print header for output
    print(f"\n{'TC/CONTAINER':<38} {'CPU(m)':>10} {'MEM(Mi)':>10} {'NET(B/s)':>10} {'TYPE':<15} {'DECISION':<30} {'REASON'}")
    print("-" * 150)
    
    zombie_count = 0
    candidate_count = 0
    active_count = 0
    stopped_count = 0
    safe_count = 0
    snapshot_rows = []
    zombie_container_names = set()
    runtime_metric_ids = [c.get("short_id") for c in containers if c.get("short_id")]
    runtime_states = get_runtime_state_map(config, container_map, extra_short_ids=runtime_metric_ids)
    stopped_overrides = set()
    try:
        stopped_overrides = get_stopped_overrides(tc_name, config)
    except Exception as e:
        logger.warning("STOPPED_OVERRIDE_LOAD_FAILED tc=%s error=%s", _q(tc_name), _q(str(e)))
    
    for container in containers:
        name = container['name']
        short_id = container.get('short_id')
        cpu_val = container['cpu']
        mem_val = container['mem']
        net_val = container['net']
        # IOPS = I/O Operations Per Second
        iops_read = container.get('iops_read', 0.0)
        iops_write = container.get('iops_write', 0.0)
        iops_val = iops_read + iops_write  # Total IOPS
        app_type = container.get('type', '')
        zombie_type = container.get('zombie_type', '')
        type_str = f"{app_type}/{zombie_type}" if zombie_type else app_type
        display_name = f"{tc_name}/{name}"
        alias = container_map.get(short_id, {}) if short_id else {}
        if not alias:
            alias = container_map.get(container.get("map_short_id"), {})
        if not alias:
            alias_match = aliases_by_name.get(_normalize_container_name(name))
            if alias_match:
                alias = alias_match[1]
        alias_name = alias.get('name') if isinstance(alias, dict) else None
        alias_state = str((alias or {}).get("state") or "").lower() if isinstance(alias, dict) else ""
        if alias_name:
            display_name = f"{tc_name}/{alias_name}"
            if app_type == 'unknown':
                app_type = alias.get('type', app_type)
                zombie_type = alias.get('zombie_type', zombie_type)
                type_str = f"{app_type}/{zombie_type}" if zombie_type else app_type
        if not app_type and short_id:
            display_name = f"{tc_name}/{short_id}"

        runtime_state = str((runtime_states.get(short_id) or {}).get("state") or "").lower()
        if not runtime_state:
            runtime_state = alias_state
        is_stopped_state = runtime_state in {"exited", "dead", "created", "removing", "not_found"}
        if is_stopped_state:
            decision = "⏸️ STOPPED"
            if runtime_state == "not_found":
                reason = "container not running (not found)"
            else:
                reason = f"container not running (state={runtime_state})"
            stopped_count += 1
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
                _q("STOPPED"),
                _q(reason),
            )
            continue

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

        # Manual STOPPED override in UI: do not requeue as PENDING on scan.
        if effective_name in stopped_overrides:
            decision = "⏸️ STOPPED"
            reason = "manual stop override"
            stopped_count += 1
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
                _q("STOPPED"),
                _q(reason),
            )
            continue

        # Decision logic for TC Docker containers
        # Policy-based detection: CPU / IOPS ratio near zero = Zombie
        # If CPU is low AND IOPS is low, the container is doing nothing
        # Formula: CPU/IOPS ≈ 0 means zombie (no work being done)
        
        # Get IOPS threshold (default 1 operation per second)
        limit_iops = float(config.get('LIMIT_IOPS', 1.0))
        
        # Zombie conditions: CPU <= 1m AND IOPS < threshold
        zombie_cpu_threshold = 1.0  # 1 millicore = almost no CPU usage
        is_very_low_cpu = cpu_val <= zombie_cpu_threshold
        is_low_iops = iops_val < limit_iops
        
        # Zombie = very low CPU AND low IOPS (truly idle containers)
        if is_very_low_cpu and is_low_iops:
            decision = "🚨 ZOMBIE DETECTED"
            reason = f"cpu<={zombie_cpu_threshold}m(actual:{cpu_val:.1f}m) && iops<{limit_iops}(actual:{iops_val:.2f}/s)"
            zombie_count += 1
        else:
            decision = "✅ ACTIVE"
            active_metrics = []
            if not is_very_low_cpu:
                active_metrics.append(f"cpu={cpu_val:.1f}m")
            if not is_low_iops:
                active_metrics.append(f"iops={iops_val:.2f}/s")
            reason = "active: " + ", ".join(active_metrics) if active_metrics else "at threshold"
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
        
        # Register pending lifecycle row; actual deletion is ONLY done via UI action.
        # Auto-cleanup is disabled - user must explicitly delete via UI.
        if decision == "🚨 ZOMBIE DETECTED":
            pending_name = alias_name or name
            zombie_container_names.add(str(pending_name))
            lifecycle_saved = add_or_update_zombie(
                tc_name=tc_name,
                container_name=pending_name,
                short_id=short_id,
                reason=reason,
                cpu_m=cpu_val,
                mem_mi=mem_val,
                net_b=net_val,
                config=config,
            )
            if lifecycle_saved:
                logger.info(
                    "LIFECYCLE_PENDING tc=%s container=%s short_id=%s",
                    _q(tc_name),
                    _q(pending_name),
                    _q(short_id or ""),
                )
            else:
                logger.error(
                    "LIFECYCLE_PENDING_FAILED tc=%s container=%s short_id=%s",
                    _q(tc_name),
                    _q(pending_name),
                    _q(short_id or ""),
                )

    # If a previously pending container is no longer zombie in this scan, cancel deletion.
    if not config['DRY_RUN']:
        recovered_count = mark_recovered_pendings(tc_name, zombie_container_names, config)
        if recovered_count > 0:
            logger.info(
                "LIFECYCLE_RECOVERED tc=%s count=%s",
                _q(tc_name),
                recovered_count,
            )
    
    print("-" * 150)
    logger.info(f"📊 Summary: {zombie_count} zombies, {candidate_count} candidates, {active_count} active, {stopped_count} stopped, {safe_count} safe")
    logger.info(
        f"SUMMARY_METRICS zombie={zombie_count} candidate={candidate_count} active={active_count} stopped={stopped_count} safe={safe_count}"
    )
    logger.info(
        "SCAN_CYCLE_END cycle=%s tc=%s zombie=%s candidate=%s active=%s stopped=%s safe=%s",
        cycle_id,
        _q(tc_name),
        zombie_count,
        candidate_count,
        active_count,
        stopped_count,
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
                "stopped": stopped_count,
                "safe": safe_count,
            },
            rows=snapshot_rows,
        )
    except Exception as e:
        logger.error("SNAPSHOT_SAVE_FAILED cycle=%s tc=%s error=%s", cycle_id, _q(tc_name), _q(str(e)))


def run_cleanup(config):
    """Delete due pending lifecycle rows and write status back to DB."""
    tc_name = config.get('TARGET_NAME') or ''
    logger.info("🧹 Cleanup cycle start (TC: %s)", tc_name if tc_name else "all")

    try:
        stats = process_cleanup(config)
        logger.info(
            "CLEANUP_SUMMARY tc=%s total=%s deleted=%s already_missing=%s failed=%s dry_run=%s",
            tc_name if tc_name else "all",
            stats.get("total", 0),
            stats.get("deleted", 0),
            stats.get("already_missing", 0),
            stats.get("failed", 0),
            stats.get("dry_run", False),
        )
    except Exception as e:
        logger.error("CLEANUP_FAILED tc=%s error=%s", tc_name if tc_name else "all", str(e))
