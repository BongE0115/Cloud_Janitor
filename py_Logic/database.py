import mysql.connector
import config
import logging

logger = logging.getLogger("SuperJanitor")

def save_log(name, ns, alive_sec, cost):
    try:
        conn = mysql.connector.connect(**config.DB_CONFIG)
        cursor = conn.cursor()
        sql = "INSERT INTO billing_log (pod_name, namespace, alive_seconds, wasted_cost) VALUES (%s, %s, %s, %s)"
        cursor.execute(sql, (name, ns, alive_sec, cost))
        conn.commit()
        conn.close()
        return True
    except Exception as e:
        logger.error(f"❌ DB 저장 실패: {e}")
        return False