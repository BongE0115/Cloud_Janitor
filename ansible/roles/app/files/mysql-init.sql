CREATE TABLE IF NOT EXISTS deletion_logs (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  pod_name VARCHAR(255) NOT NULL,
  container_name VARCHAR(255),
  namespace VARCHAR(100),
  pod_ip VARCHAR(50),
  cpu_usage DECIMAL(10, 4),
  memory_usage DECIMAL(20, 2),
  network_receive_rate DECIMAL(20, 2),
  network_transmit_rate DECIMAL(20, 2),
  deletion_reason TEXT,
  detected_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  deleted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_pod_name (pod_name),
  INDEX idx_deleted_at (deleted_at),
  INDEX idx_namespace (namespace)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS registered_targets (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tc_name VARCHAR(255) NOT NULL UNIQUE,
  tc_hostname VARCHAR(255),
  tc_ip VARCHAR(50),
  tc_os VARCHAR(50),
  tc_arch VARCHAR(50),
  prometheus_url TEXT NOT NULL,
  docker_api_url TEXT,
  labels TEXT,
  namespace VARCHAR(100),
  internal_prometheus_url TEXT,
  registered_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_updated_at (updated_at),
  INDEX idx_namespace (namespace)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS scan_latest_summary (
  tc_name VARCHAR(255) NOT NULL PRIMARY KEY,
  cycle_id BIGINT NOT NULL,
  zombie_count INT NOT NULL DEFAULT 0,
  candidate_count INT NOT NULL DEFAULT 0,
  active_count INT NOT NULL DEFAULT 0,
  safe_count INT NOT NULL DEFAULT 0,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_cycle_id (cycle_id),
  INDEX idx_updated_at (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS scan_latest_containers (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tc_name VARCHAR(255) NOT NULL,
  cycle_id BIGINT NOT NULL,
  container_name VARCHAR(255) NOT NULL,
  tc_container VARCHAR(255) NOT NULL,
  cpu_m DECIMAL(10, 2) NOT NULL DEFAULT 0,
  mem_mi DECIMAL(10, 2) NOT NULL DEFAULT 0,
  net_b DECIMAL(14, 2) NOT NULL DEFAULT 0,
  ctype VARCHAR(100) NOT NULL DEFAULT 'unknown',
  decision VARCHAR(255) NOT NULL,
  reason TEXT,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  UNIQUE KEY uniq_tc_container (tc_name, tc_container),
  INDEX idx_tc_cycle (tc_name, cycle_id),
  INDEX idx_updated_at (updated_at)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;

CREATE TABLE IF NOT EXISTS zombie_lifecycle (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  tc_name VARCHAR(255) NOT NULL,
  container_name VARCHAR(255) NOT NULL,
  short_id VARCHAR(64),
  status VARCHAR(50) NOT NULL DEFAULT 'PENDING',
  detected_at TIMESTAMP NULL,
  stopped_at TIMESTAMP NULL,
  last_cost_calc_at TIMESTAMP NULL,
  stop_ended_at TIMESTAMP NULL,
  scheduled_delete_at TIMESTAMP NULL,
  deleted_at TIMESTAMP NULL,
  reason TEXT,
  cpu_m DECIMAL(10, 2) NOT NULL DEFAULT 0,
  mem_mi DECIMAL(10, 2) NOT NULL DEFAULT 0,
  net_b DECIMAL(14, 2) NOT NULL DEFAULT 0,
  wasted_cost DECIMAL(14, 6) NOT NULL DEFAULT 0,
  last_error TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
  INDEX idx_tc_status_sched (tc_name, status, scheduled_delete_at),
  INDEX idx_status_detected (status, detected_at),
  INDEX idx_container (tc_name, container_name),
  INDEX idx_short_id (short_id)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
