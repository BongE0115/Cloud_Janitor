import logging
from .metrics import get_k8s_client, get_prom_val
from .database import add_or_update_zombie  # [Comment] 통합 테이블용 함수명으로 변경
from .database import process_cleanup # database.py에서 정의한 함수

# 로그 기록 방식 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("SuperJanitor")

def run_janitor(config):
    """클러스터를 스캔하고 기준에 미달하는 좀비 파드를 찾아 삭제 대기열에 등록합니다."""
    
    # [Comment] 기존 metrics.py의 인증 로직을 그대로 사용
    v1 = get_k8s_client()
    if not v1:
        logger.error("❌ 쿠버네티스 인증 실패: .kube/config 파일이나 SA 권한을 확인하세요.")
        return

    logger.info(f"🎯 탐색 작전 시작 (모드: {'테스트' if config['DRY_RUN'] else '실전'})")
    
    try:
        all_pods = v1.list_pod_for_all_namespaces().items
    except Exception as e:
        logger.error(f"❌ 파드 목록 조회 중 오류 발생: {e}")
        return

    # 화면 출력용 헤더 (표 형식 그대로 유지)
    print(f"\n{'NAMESPACE':<15} {'POD NAME':<35} {'CPU(m)':>8} {'MEM(Mi)':>8} {'NET(B)':>8} {'DECISION'}")
    print("-" * 115)

    for pod in all_pods:
        ns, name = pod.metadata.namespace, pod.metadata.name
        
        # [Comment] 기존 SKIP 및 쿼리 로직 보존
        if "mysql" in name:
            print(f"🛡️ [SKIP] {name} 은 핵심 인프라(DB)이므로 건너뜁니다.")
            continue

        cpu_q = f'sum(rate(container_cpu_usage_seconds_total{{pod="{name}",namespace="{ns}"}}[{config["TIME_WINDOW_CPU"]}])) * 1000'
        mem_q = f'sum(container_memory_working_set_bytes{{pod="{name}",namespace="{ns}"}}) / 1024 / 1024'
        net_q = f'sum(rate(container_network_receive_bytes_total{{pod="{name}",namespace="{ns}"}}[{config["TIME_WINDOW_NET"]}]))'

        cpu_val = get_prom_val(config['PROMETHEUS_URL'], cpu_q)
        mem_val = get_prom_val(config['PROMETHEUS_URL'], mem_q)
        net_val = get_prom_val(config['PROMETHEUS_URL'], net_q)

        # 판정 단계 (메모리 체크 포함)
        if ns in config['WHITE_LIST_NS']:
            decision = "✅ SAFE (WhiteList)"
        elif ns in config['TARGET_NAMESPACES'] and cpu_val < config['LIMIT_CPU_M'] and net_val < config['LIMIT_NET_B']:
            decision = "🚨 ZOMBIE DETECTED"
        else:
            decision = "👍 ACTIVE"

        print(f"{ns:<15} {name[:35]:<35} {cpu_val:>8.2f} {mem_val:>8.2f} {net_val:>8.2f} {decision}")

        # [Comment] 좀비 발견 시 바로 삭제하지 않고 'zombie_lifecycle' 테이블에 PENDING 상태로 등록/갱신
        if decision == "🚨 ZOMBIE DETECTED" and not config['DRY_RUN']:
            reason = f"CPU:{cpu_val:.1f}m, NET:{net_val:.1f}B"
            # [Comment] 통합 테이블용 함수 호출
            success = add_or_update_zombie(pod, reason, config)
            if success:
                logger.info(f"📝 [라이프사이클 등록] {name} (유예 기간 시작)")

def run_cleanup(config):
    """[Phase 2] 대기열 확인 및 실제 삭제/빌링 기록 로직 실행"""
    # [Comment] 기존에 정의된 인증 함수 사용
    v1 = get_k8s_client()
    if not v1:
        logger.error("❌ 쿠버네티스 인증 실패!")
        return
        
    # [Comment] DB 테이블 스캔 및 만료된 PENDING 파드 삭제 수행
    process_cleanup(v1, config)