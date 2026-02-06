# janitor_logic.py (위치: py_Logic 폴더 안)
import logging
from datetime import datetime, timezone
from kubernetes import client, config as k8s_config

# 같은 폴더 내 모듈 임포트
import config
import metrics
import database

logger = logging.getLogger("SuperJanitor")

# 🌟 이 함수 이름이 main.py에서 부르는 이름과 정확히 일치해야 합니다.
def run_janitor_process():
    try:
        # 쿠버네티스 설정 로드
        k8s_config.load_kube_config()
        v1 = client.CoreV1Api()
        
        logger.info(f"🎯 소탕 작전 시작 (모드: {'테스트' if config.DRY_RUN else '실전'})")
        
        all_pods = v1.list_pod_for_all_namespaces().items
        print(f"\n{'NAMESPACE':<15} {'POD NAME':<35} {'CPU(m)':>8} {'NET(B)':>8} {'DECISION'}")
        print("-" * 100)
        
        for pod in all_pods:
            ns, name = pod.metadata.namespace, pod.metadata.name
            
            # 지표 수집 (metrics.py 활용)
            m = metrics.get_pod_metrics(ns, name)
            
            # 좀비 판정 로직
            if ns in config.WHITE_LIST_NS:
                decision = "✅ SAFE"
            elif ns in config.TARGET_NAMESPACES and m['cpu'] < config.LIMIT_CPU_M and m['net'] < config.LIMIT_NET_B:
                decision = "🚨 ZOMBIE"
            else:
                decision = "👍 ACTIVE"

            print(f"{ns:<15} {name[:35]:<35} {m['cpu']:>8.2f} {m['net']:>8.2f} {decision}")

            # 실전 모드(DRY_RUN=False)일 때 삭제 및 DB 저장
            if decision == "🚨 ZOMBIE" and not config.DRY_RUN:
                creation_ts = pod.metadata.creation_timestamp
                alive_sec = int((datetime.now(timezone.utc) - creation_ts).total_seconds())
                cost = config.DEFAULT_CPU_REQ * (alive_sec / 3600) * config.COST_PER_CORE_HOUR
                
                # DB 저장 (database.py 활용)
                if database.save_log(name, ns, alive_sec, cost):
                    v1.delete_namespaced_pod(name=name, namespace=ns)
                    logger.info(f"💥 [삭제 완료] {name} (비용: ${cost:.5f})")
                    
    except Exception as e:
        logger.error(f"❌ 실행 중 오류 발생: {e}")