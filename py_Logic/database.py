import mysql.connector
from datetime import datetime, timezone

def save_billing_and_delete(v1, pod_obj, config):
    """파드의 정보를 DB에 남기고 실제 쿠버네티스 명령으로 삭제합니다."""
    ns, name = pod_obj.metadata.namespace, pod_obj.metadata.name
    
    # 생존 시간 계산 (현재 시간 - 파드 생성 시간)
    creation_ts = pod_obj.metadata.creation_timestamp
    alive_sec = int((datetime.now(timezone.utc) - creation_ts).total_seconds())
    
    # 소모 비용 계산 (CPU 요청량 * 시간 * 단가)
    cost = config['DEFAULT_CPU_REQ'] * (alive_sec / 3600) * config['COST_PER_CORE_HOUR']

    try:
        # MySQL 데이터베이스에 접속 (main.py에서 받은 정보 활용)
        conn = mysql.connector.connect(**config['DB_CONFIG'])
        cursor = conn.cursor()
        
        # 소탕 로그 삽입 쿼리
        sql = "INSERT INTO billing_log (pod_name, namespace, alive_seconds, wasted_cost) VALUES (%s, %s, %s, %s)"
        cursor.execute(sql, (name, ns, alive_sec, cost))
        
        conn.commit()
        conn.close()
        
        # 실제 쿠버네티스 파드 삭제 명령 실행
        v1.delete_namespaced_pod(name=name, namespace=ns)
        return True, cost, alive_sec
    except Exception as e:
        # 실패 시 에러 내용을 반환
        return False, str(e), 0