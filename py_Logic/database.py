import mysql.connector
from datetime import datetime, timedelta

# [Comment] DB 연결 및 통합 라이프사이클 관리
def get_db_connection(config):
    return mysql.connector.connect(**config['DB_CONFIG'])

def add_or_update_zombie(pod_obj, reason, config):
    """[Phase 1] 좀비를 PENDING 상태로 등록하거나 예약 시간 갱신"""
    ns, name = pod_obj.metadata.namespace, pod_obj.metadata.name
    try:
        conn = get_db_connection(config)
        cursor = conn.cursor()
        
        # [Comment] 유예 기간 계산 (분 단위)
        minutes = config.get('GRACE_PERIOD_MINUTES', 3)
        scheduled_at = datetime.now() + timedelta(minutes=minutes)
        
        # [Comment] 중복 발생 시 예약 시간과 사유만 업데이트
        sql = """
            INSERT INTO zombie_lifecycle (pod_name, namespace, status, scheduled_delete_at, reason) 
            VALUES (%s, %s, 'PENDING', %s, %s)
            ON DUPLICATE KEY UPDATE 
                scheduled_delete_at = VALUES(scheduled_delete_at),
                reason = VALUES(reason),
                status = 'PENDING'
        """
        cursor.execute(sql, (name, ns, scheduled_at, reason))
        conn.commit()
        conn.close()
        return True
    except Exception as e:
        print(f"❌ DB 등록 오류: {e}")
        return False

def process_cleanup(v1, config):
    """[Phase 2] PENDING 상태 중 시간이 만료된 파드 소탕"""
    try:
        conn = get_db_connection(config)
        cursor = conn.cursor(dictionary=True)
        
        # [Comment] 예약 시간이 지났고 아직 PENDING 상태인 파드만 조회
        query = "SELECT * FROM zombie_lifecycle WHERE status = 'PENDING' AND scheduled_delete_at <= NOW()"
        cursor.execute(query)
        targets = cursor.fetchall()

        for target in targets:
            name, ns = target['pod_name'], target['namespace']
            
            # [Comment] 비용 계산 (최초 감지 시각 기준)
            alive_sec = int((datetime.now() - target['detected_at']).total_seconds())
            cost = config.get('DEFAULT_CPU_REQ', 0.2) * (alive_sec / 3600) * config.get('COST_PER_CORE_HOUR', 0.1)

            try:
                # K8s에서 실제 파드 삭제
                v1.delete_namespaced_pod(name=name, namespace=ns)
                
                # [Comment] DB 상태 업데이트 (PENDING -> DELETED)
                update_sql = "UPDATE zombie_lifecycle SET status = 'DELETED', deleted_at = NOW(), wasted_cost = %s WHERE id = %s"
                cursor.execute(update_sql, (cost, target['id']))
                print(f"💥 [소탕 완료] {ns}/{name} (${cost:.5f} 절약)")
            except Exception as e:
                print(f"⚠️ {name} 삭제 실패: {e}")

        conn.commit()
        conn.close()
    except Exception as e:
        print(f"❌ 클린업 실행 오류: {e}")