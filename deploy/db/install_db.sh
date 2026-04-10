\
#!/usr/bin/env bash
set -euo pipefail

DB_BIND_ADDRESS="${DB_BIND_ADDRESS:-0.0.0.0}"
DB_NAME="${DB_NAME:-employees}"
TEST_TABLE="${TEST_TABLE:-empleados_demo}"
BACKUP_USER="${BACKUP_USER:-dasc_backup}"
BACKUP_PASS="${BACKUP_PASS:-dasc_backup_2026}"
BACKUP_ALLOWED_HOST="${BACKUP_ALLOWED_HOST:-192.168.60.30}"
MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "==> Instalando MariaDB"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client

echo "==> Configurando bind-address en ${MARIADB_CNF}"
if [[ -f "$MARIADB_CNF" ]]; then
  cp -n "$MARIADB_CNF" "${MARIADB_CNF}.bak" || true
  if grep -qE '^[#[:space:]]*bind-address' "$MARIADB_CNF"; then
    sed -i -E "s|^[#[:space:]]*bind-address[[:space:]]*=.*|bind-address = ${DB_BIND_ADDRESS}|g" "$MARIADB_CNF"
  else
    cat >> "$MARIADB_CNF" <<EOF

[mysqld]
bind-address = ${DB_BIND_ADDRESS}
EOF
  fi
else
  echo "ERROR: no existe ${MARIADB_CNF}"
  exit 1
fi

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
GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES ON \`${DB_NAME}\`.* TO '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';
FLUSH PRIVILEGES;
SQL

echo "==> Validaciones"
systemctl --no-pager --full status mariadb || true
ss -lntp | grep 3306 || true
mariadb -e "SELECT User, Host FROM mysql.user WHERE User='${BACKUP_USER}';"
mariadb -e "SHOW DATABASES LIKE '${DB_NAME}';"

echo
echo "============================================"
echo "Base de datos instalada correctamente"
echo "DB_NAME=${DB_NAME}"
echo "BACKUP_USER=${BACKUP_USER}"
echo "BACKUP_ALLOWED_HOST=${BACKUP_ALLOWED_HOST}"
echo "Puerto esperado: 3306"
echo "============================================"
