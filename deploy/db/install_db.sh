#!/usr/bin/env bash
set -euo pipefail

DB_BIND_ADDRESS="${DB_BIND_ADDRESS:-0.0.0.0}"
DB_NAME="${DB_NAME:-employees}"
TEST_TABLE="${TEST_TABLE:-empleados_demo}"

BACKUP_USER="${BACKUP_USER:-dasc_backup}"
BACKUP_PASS="${BACKUP_PASS:-dasc_backup_2026}"
BACKUP_ALLOWED_HOST="${BACKUP_ALLOWED_HOST:-192.168.60.30}"
RESTORE_USER="${RESTORE_USER:-dasc_restore}"
RESTORE_PASS="${RESTORE_PASS:-dasc_restore_2026}"

MARIADB_CNF="/etc/mysql/mariadb.conf.d/50-server.cnf"

# Usuario SSH usado por la API/Terminal para entrar en esta máquina DB
APP_USER="${APP_USER:-dasc}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
APP_HOME="/home/${APP_USER}"
SSHD_CONFIG="/etc/ssh/sshd_config"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPTIONAL_API_PUBKEY="$SCRIPT_DIR/api_panel.pub"

DB_SERVER_ID="${DB_SERVER_ID:-20}"
BINLOG_BASENAME="${BINLOG_BASENAME:-/var/log/mysql/dasc-bin}"
BINLOG_FORMAT="${BINLOG_FORMAT:-ROW}"
BINLOG_EXPIRE_DAYS="${BINLOG_EXPIRE_DAYS:-14}"
BINLOG_MAX_SIZE="${BINLOG_MAX_SIZE:-100M}"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "==> Instalando MariaDB, SSH y sudo"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y mariadb-server mariadb-client openssh-server sudo

echo "==> Preparando SSH para la terminal remota de DASC"
systemctl enable --now ssh

if [[ -f "$SSHD_CONFIG" ]]; then
  echo "==> Asegurando autenticación por contraseña y clave pública en SSH"

  if grep -qE '^[#[:space:]]*PasswordAuthentication' "$SSHD_CONFIG"; then
    sed -i -E 's|^[#[:space:]]*PasswordAuthentication[[:space:]]+.*|PasswordAuthentication yes|g' "$SSHD_CONFIG"
  else
    echo 'PasswordAuthentication yes' >> "$SSHD_CONFIG"
  fi

  if grep -qE '^[#[:space:]]*PubkeyAuthentication' "$SSHD_CONFIG"; then
    sed -i -E 's|^[#[:space:]]*PubkeyAuthentication[[:space:]]+.*|PubkeyAuthentication yes|g' "$SSHD_CONFIG"
  else
    echo 'PubkeyAuthentication yes' >> "$SSHD_CONFIG"
  fi

  systemctl restart ssh
fi

echo "==> Creando usuario SSH de servicio ${APP_USER}"
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${APP_USER}"
fi

if [[ -z "${APP_PASSWORD:-}" ]]; then
  echo
  read -rsp "Introduce la contraseña para el usuario ${APP_USER} en esta máquina DB: " APP_PASSWORD
  echo
  read -rsp "Repite la contraseña para ${APP_USER}: " APP_PASSWORD_CONFIRM
  echo

  if [[ "$APP_PASSWORD" != "$APP_PASSWORD_CONFIRM" ]]; then
    echo "ERROR: las contraseñas no coinciden."
    exit 1
  fi
fi

if [[ -z "$APP_PASSWORD" ]]; then
  echo "ERROR: la contraseña de ${APP_USER} no puede estar vacía."
  exit 1
fi

echo "${APP_USER}:${APP_PASSWORD}" | chpasswd
echo "==> Contraseña de ${APP_USER} configurada"

mkdir -p "${APP_HOME}/.ssh"
touch "${APP_HOME}/.ssh/authorized_keys"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_HOME}"
chmod 755 "${APP_HOME}"
chmod 700 "${APP_HOME}/.ssh"
chmod 600 "${APP_HOME}/.ssh/authorized_keys"

if [[ -f "${OPTIONAL_API_PUBKEY}" ]]; then
  echo "==> Instalando clave pública opcional desde api_panel.pub"
  grep -qxF "$(cat "${OPTIONAL_API_PUBKEY}")" "${APP_HOME}/.ssh/authorized_keys" || \
    cat "${OPTIONAL_API_PUBKEY}" >> "${APP_HOME}/.ssh/authorized_keys"
  chown "${APP_USER}:${APP_GROUP}" "${APP_HOME}/.ssh/authorized_keys"
  chmod 600 "${APP_HOME}/.ssh/authorized_keys"
else
  echo "==> No se encontró api_panel.pub junto al instalador DB."
  echo "==> La API podrá copiar su clave automáticamente con sshpass durante install_dasc_api.sh."
fi

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

echo "==> Creando base de datos, tabla demo y usuarios de backup/restauración"
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
ALTER USER '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}' IDENTIFIED BY '${BACKUP_PASS}';

GRANT SELECT, SHOW VIEW, TRIGGER, EVENT, LOCK TABLES
ON \`${DB_NAME}\`.* TO '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';

GRANT RELOAD, REPLICATION CLIENT, REPLICATION SLAVE
ON *.* TO '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';

CREATE USER IF NOT EXISTS '${RESTORE_USER}'@'${BACKUP_ALLOWED_HOST}' IDENTIFIED BY '${RESTORE_PASS}';
ALTER USER '${RESTORE_USER}'@'${BACKUP_ALLOWED_HOST}' IDENTIFIED BY '${RESTORE_PASS}';

GRANT ALL PRIVILEGES
ON \`${DB_NAME}\`.* TO '${RESTORE_USER}'@'${BACKUP_ALLOWED_HOST}';

FLUSH PRIVILEGES;
SQL

echo "==> Validaciones"
systemctl --no-pager --full status ssh || true
systemctl --no-pager --full status mariadb || true
id "${APP_USER}" || true
ls -ld "${APP_HOME}" "${APP_HOME}/.ssh" || true
ss -lntp | grep -E '(:22|:3306)' || true
mariadb -e "SELECT User, Host FROM mysql.user WHERE User='${BACKUP_USER}';"
mariadb -e "SHOW DATABASES LIKE '${DB_NAME}';"
mariadb -e "SHOW GRANTS FOR '${BACKUP_USER}'@'${BACKUP_ALLOWED_HOST}';" || true
mariadb -e "SHOW GRANTS FOR '${RESTORE_USER}'@'${BACKUP_ALLOWED_HOST}';" || true
mariadb -e "SHOW VARIABLES LIKE 'log_bin';"
mariadb -e "SHOW MASTER STATUS;"
mariadb -e "SHOW BINARY LOGS;"

echo
echo "============================================"
echo "Base de datos instalada correctamente"
echo "DB_NAME=${DB_NAME}"
echo "TEST_TABLE=${TEST_TABLE}"
echo "BACKUP_USER=${BACKUP_USER}"
echo "RESTORE_USER=${RESTORE_USER}"
echo "BACKUP_ALLOWED_HOST=${BACKUP_ALLOWED_HOST}"
echo "Binary logs: ${BINLOG_BASENAME}"
echo "Puerto SSH esperado: 22"
echo "Puerto MariaDB esperado: 3306"
echo "Usuario SSH para terminal: ${APP_USER}"
echo "============================================"
