import mysql.connector
from datetime import datetime, timedelta, timezone  # [Comment] timezone 추가가 핵심입니다!

def get_db_connection(config):
    """[Comment] DB 연결 후 자동으로 테이블 존재 여부를 체크합니다."""
    # 1. 처음엔 DB 이름을 제외하고 연결 (DB 자체가 없을 수 있으므로)
    base_config = config['DB_CONFIG'].copy()
    db_name = base_config.pop('database', 'janitor_db')
    
    conn = mysql.connector.connect(**base_config)
    cursor = conn.cursor()
    
    # 2. 아래에서 정의할 자동 생성 함수 호출
    setup_database(cursor, db_name)
    
    cursor.close()
    return conn

def setup_database(cursor, db_name):
    """[Comment] 데이터베이스와 테이블이 없으면 생성합니다."""
    # 1. 데이터베이스 생성 및 사용 선언
    cursor.execute(f"CREATE DATABASE IF NOT EXISTS {db_name}")
    cursor.execute(f"USE {db_name}")

    # 2. 테이블 생성 (에러 방지를 위해 모든 컬럼 포함)
    create_table_query = """
    CREATE TABLE IF NOT EXISTS zombie_lifecycle (
        id INT AUTO_INCREMENT PRIMARY KEY,
        namespace VARCHAR(100) NOT NULL,
        pod_name VARCHAR(100) NOT NULL,
        cpu_usage FLOAT DEFAULT 0,
        mem_usage FLOAT DEFAULT 0,
        net_usage FLOAT DEFAULT 0,
        detected_at TIMESTAMP NULL,
        scheduled_delete_at TIMESTAMP NULL,
        deleted_at TIMESTAMP NULL,
        status VARCHAR(50) DEFAULT 'PENDING',
        reason TEXT,
        wasted_cost FLOAT DEFAULT 0.0,
        INDEX (pod_name),
        INDEX (detected_at),
        INDEX (status)
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    """
    cursor.execute(create_table_query)

def add_or_update_zombie(pod_obj, reason, config):
    """[Phase 1] 좀비 파드를 DB에 등록하거나 유예 시간을 갱신합니다."""
    ns, name = pod_obj.metadata.namespace, pod_obj.metadata.name
    try:
        conn = get_db_connection(config)
        cursor = conn.cursor(dictionary=True) # [Comment] 결과 확인을 위해 dictionary 모드로 변경
        
        # 1. [Comment] 중요: 현재 해당 파드가 이미 'PENDING' 상태로 등록되어 있는지 확인합니다.
        # 이 절차가 있어야 UNIQUE KEY가 없어도 1분마다 중복 등록되는 것을 막을 수 있습니다.
        check_sql = "SELECT id FROM zombie_lifecycle WHERE pod_name = %s AND namespace = %s AND status = 'PENDING'"
        cursor.execute(check_sql, (name, ns))
        already_pending = cursor.fetchone()

        if already_pending:
            # [Comment] 이미 대기 중인 좀비라면 기록을 생성하지 않고 종료합니다.
            # (필요하다면 여기서 scheduled_delete_at을 UPDATE 하는 로직을 넣을 수도 있습니다)
            cursor.close()
            conn.close()
            return True

        # 2. [Comment] 9시간 시차 해결 및 새 기록 생성 준비
        now_utc = datetime.now(timezone.utc).replace(tzinfo=None)
        minutes = config.get('GRACE_PERIOD_MINUTES', 3)
        scheduled_at = now_utc + timedelta(minutes=minutes)
        
        # 3. [Comment] INSERT만 수행 (과거 DELETED 기록은 건드리지 않고 새로운 행을 추가함)
        sql = """
            INSERT INTO zombie_lifecycle (pod_name, namespace, status, scheduled_delete_at, reason, detected_at) 
            VALUES (%s, %s, 'PENDING', %s, %s, %s)
        """
        cursor.execute(sql, (name, ns, scheduled_at, reason, now_utc))
        
        conn.commit()
        cursor.close()
        conn.close()
        return True
    except Exception as e:
        print(f"❌ DB 등록 오류: {e}")
        return False

def process_cleanup(v1, config):
    """[Phase 2] 유예 기간이 지난 파드들을 실제로 삭제하고 비용을 계산합니다."""
    try:
        conn = get_db_connection(config)
        cursor = conn.cursor(dictionary=True)
        
        # [Comment] NOW() 대신 UTC_TIMESTAMP()를 써서 DB 서버 시차 문제를 해결합니다.
        query = "SELECT * FROM zombie_lifecycle WHERE status = 'PENDING' AND scheduled_delete_at <= UTC_TIMESTAMP()"
        cursor.execute(query)
        targets = cursor.fetchall()

        # [Comment] 비용 계산을 위해 현재 UTC 시간 확보
        now_utc = datetime.now(timezone.utc).replace(tzinfo=None)

        for target in targets:
            name, ns = target['pod_name'], target['namespace']
            
            # [Comment] 낭비된 비용 계산 (생존 시간 기반)
            detected_at = target['detected_at'] if target['detected_at'] else now_utc
            alive_sec = int((now_utc - detected_at).total_seconds())
            
            # [Comment] 기본값 설정 (CPU 0.2Core, 시간당 $0.1 기준)
            cpu_req = config.get('DEFAULT_CPU_REQ', 0.2)
            cost_per_hour = config.get('COST_PER_CORE_HOUR', 0.1)
            wasted_cost = cpu_req * (alive_sec / 3600) * cost_per_hour

            try:
                # [Comment] 실제 쿠버네티스 파드 삭제 실행
                v1.delete_namespaced_pod(name=name, namespace=ns)
                
                # [Comment] 삭제 상태 및 절약 비용 기록
                # WHERE id = %s 를 사용하므로 정확히 해당 회차의 기록만 업데이트됩니다.
                update_sql = """
                    UPDATE zombie_lifecycle 
                    SET status = 'DELETED', deleted_at = UTC_TIMESTAMP(), wasted_cost = %s 
                    WHERE id = %s
                """
                cursor.execute(update_sql, (wasted_cost, target['id']))
                print(f"💥 [소탕 완료] {ns}/{name} (약 ${wasted_cost:.5f} 절약)")
                
            except Exception as e:
                # [Comment] 파드가 이미 수동으로 삭제된 경우 등 예외 처리
                if "NotFound" in str(e):
                    cursor.execute("UPDATE zombie_lifecycle SET status = 'DELETED' WHERE id = %s", (target['id'],))
                    print(f"ℹ️ {name} 파드가 이미 존재하지 않습니다. DB 상태만 업데이트합니다.")
                else:
                    print(f"⚠️ {name} 삭제 실패: {e}")

        conn.commit()
        cursor.close()
        conn.close()
    except Exception as e:
        print(f"❌ 클린업 프로세스 오류: {e}")