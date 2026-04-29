#!/usr/bin/env bash
set -euo pipefail

DB_BIND_ADDRESS="${DB_BIND_ADDRESS:-0.0.0.0}"
DB_NAME="${DB_NAME:-employees}"
TEST_TABLE="${TEST_TABLE:-empleados_demo}"

BACKUP_USER="${BACKUP_USER:-dasc_backup}"
BACKUP_PASS="${BACKUP_PASS:-dasc_backup_2026}"
BACKUP_ALLOWED_HOST="${BACKUP_ALLOWED_HOST:-192.168.60.30}"

MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"

DB_SERVER_ID="${DB_SERVER_ID:-20}"
BINLOG_BASENAME="${BINLOG_BASENAME:-/var/log/mysql/dasc-bin}"
BINLOG_FORMAT="${BINLOG_FORMAT:-ROW}"
BINLOG_EXPIRE_DAYS="${BINLOG_EXPIRE_DAYS:-14}"
BINLOG_MAX_SIZE="${BINLOG_MAX_SIZE:-100M}"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "==> Instalando MariaDB"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client

echo "==> Configurando bind-address y binary logs en ${MARIADB_CNF}"
if [[ ! -f "$MARIADB_CNF" ]]; then
  echo "ERROR: no existe ${MARIADB_CNF}"
  exit 1
fi

cp -n "$MARIADB_CNF" "${MARIADB_CNF}.bak" || true

if grep -qE '^[#[:space:]]*bind-address' "$MARIADB_CNF"; then
  sed -i -E "s|^[#[:space:]]*bind-address[[:space:]]*=.*|bind-address = ${DB_BIND_ADDRESS}|g" "$MARIADB_CNF"
else
  cat >> "$MARIADB_CNF" <<EOF

# DASC NETWORK START
[mysqld]
bind-address = ${DB_BIND_ADDRESS}
# DASC NETWORK END
EOF
fi

echo "==> Preparando directorio de binlogs"
mkdir -p /var/log/mysql
chown mysql:adm /var/log/mysql
chmod 750 /var/log/mysql

# Evita duplicados si el instalador se ejecuta varias veces
sed -i '/# DASC BINLOG START/,/# DASC BINLOG END/d' "$MARIADB_CNF"

cat >> "$MARIADB_CNF" <<EOF

# DASC BINLOG START
server_id = ${DB_SERVER_ID}
log_bin = ${BINLOG_BASENAME}
binlog_format = ${BINLOG_FORMAT}
expire_logs_days = ${BINLOG_EXPIRE_DAYS}
max_binlog_size = ${BINLOG_MAX_SIZE}
# DASC BINLOG END
EOF

echo "==> Habilitando y reiniciando MariaDB"
systemctl enable --now mariadb
systemctl restart mariadb

echo "==> Creando base de datos, tabla demo y usuario de backup"
mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\`;

CREATE TABLE IF NOT EXISTS \`${DB_NAME}\`.\`${TEST_TABLE}\` (
  id INT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  nombre VARCHAR(120) NOT NULL,
  fecha_creacion TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

INSERT INTO \`${DB_NAME}\`.\`${TEST_TABLE}\` (nombre)
SELECT 'registro-inicial'
WHERE NOT EXISTS (
  SELECT 1 FROM \`${DB_NAME}\`.\`${TEST_TABLE}\` WHERE nombre='registro-inicial'
);

CREATE USER IF NOT EXISTS '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}' IDENTIFIED BY '${BACKUP_PASS}';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON \`${DB_NAME}\`.* TO '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';

GRANT RELOAD, REPLICATION CLIENT, REPLICATION SLAVE
ON *.* TO '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';

FLUSH PRIVILEGES;
SQL

echo "==> Validaciones"
systemctl --no-pager --full status mariadb || true
ss -lntp | grep 3306 || true
mariadb -e "SELECT User, Host FROM mysql.user WHERE User='${BACKUP_USER}';"
mariadb -e "SHOW DATABASES LIKE '${DB_NAME}';"
mariadb -e "SHOW GRANTS FOR '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';" || true
mariadb -e "SHOW VARIABLES LIKE 'log_bin';"
mariadb -e "SHOW MASTER STATUS;"
mariadb -e "SHOW BINARY LOGS;"

echo
echo "============================================"
echo "Base de datos instalada correctamente"
echo "DB_NAME=${DB_NAME}"
echo "TEST_TABLE=${TEST_TABLE}"
echo "BACKUP_USER=${BACKUP_USER}"
echo "BACKUP_ALLOWED_HOST=${BACKUP_ALLOWED_HOST}"
echo "Binary logs: ${BINLOG_BASENAME}"
echo "Puerto esperado: 3306"
echo "============================================"
