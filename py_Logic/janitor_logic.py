import logging
from .metrics import get_k8s_client, get_prom_val
from .database import save_billing_and_delete

# 로그 기록 방식 설정
logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')
logger = logging.getLogger("SuperJanitor")

def run_janitor(config):
    """클러스터를 스캔하고 기준에 미달하는 좀비 파드를 찾아 삭제합니다."""
    
    # metrics.py에 정의한 함수를 통해 자동으로 인증된 K8s 클라이언트를 가져옴
    v1 = get_k8s_client()
    if not v1:
        logger.error("❌ 쿠버네티스 인증 실패: .kube/config 파일이나 SA 권한을 확인하세요.")
        return

    logger.info(f"🎯 소탕 작전 시작 (모드: {'테스트' if config['DRY_RUN'] else '실전'})")
    
    try:
        # 클러스터 내의 모든 파드 목록 조회
        all_pods = v1.list_pod_for_all_namespaces().items
    except Exception as e:
        logger.error(f"❌ 파드 목록 조회 중 오류 발생: {e}")
        return

    # 화면 출력용 헤더 (표 형식)
    print(f"\n{'NAMESPACE':<15} {'POD NAME':<35} {'CPU(m)':>8} {'MEM(Mi)':>8} {'NET(B)':>8} {'DECISION'}")
    print("-" * 115)

    for pod in all_pods:
        ns, name = pod.metadata.namespace, pod.metadata.name
        
        # 프로메테우스 쿼리 준비
        cpu_q = f'sum(rate(container_cpu_usage_seconds_total{{pod="{name}",namespace="{ns}"}}[{config["TIME_WINDOW_CPU"]}])) * 1000'
        mem_q = f'sum(container_memory_working_set_bytes{{pod="{name}",namespace="{ns}"}}) / 1024 / 1024'
        net_q = f'sum(rate(container_network_receive_bytes_total{{pod="{name}",namespace="{ns}"}}[{config["TIME_WINDOW_NET"]}]))'

        # 지표 데이터 수집
        cpu_val = get_prom_val(config['PROMETHEUS_URL'], cpu_q)
        mem_val = get_prom_val(config['PROMETHEUS_URL'], mem_q)
        net_val = get_prom_val(config['PROMETHEUS_URL'], net_q)

        # 판정 단계
        if ns in config['WHITE_LIST_NS']:
            decision = "✅ SAFE (WhiteList)"
        elif ns in config['TARGET_NAMESPACES'] and cpu_val < config['LIMIT_CPU_M'] and net_val < config['LIMIT_NET_B']:
            decision = "🚨 ZOMBIE DETECTED"
        else:
            decision = "👍 ACTIVE"

        # 결과 한 줄 출력
        print(f"{ns:<15} {name[:35]:<35} {cpu_val:>8.2f} {mem_val:>8.2f} {net_val:>8.2f} {decision}")

        # 좀비로 판정될 경우 DB 저장 및 실제 삭제 수행
        if decision == "🚨 ZOMBIE DETECTED" and not config['DRY_RUN']:
            success, val, sec = save_billing_and_delete(v1, pod, config)
            if success:
                logger.info(f"💰 [DB 기록 완료] {name}: ${val:.5f} (생존: {sec}초)")
                logger.info(f"💥 [삭제 성공] {ns}/{name}")
            else:
                logger.error(f"❌ 작업 중 오류 발생: {val}")