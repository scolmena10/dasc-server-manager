\
#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-dasc}"
APP_GROUP="${APP_GROUP:-$APP_USER}"
APP_HOME="/home/${APP_USER}"
BACKUP_DIR="${BACKUP_DIR:-${APP_HOME}/backups}"

DB_HOST="${DB_HOST:-192.168.60.20}"
DB_NAME="${DB_NAME:-employees}"
DB_BACKUP_USER="${DB_BACKUP_USER:-dasc_backup}"
DB_BACKUP_PASS="${DB_BACKUP_PASS:-dasc_backup_2026}"

INSTALL_BACKUP_SCRIPT="/usr/local/bin/backups_api.sh"
INSTALL_SERVICES_SCRIPT="/usr/local/bin/servicios_api.sh"
SUDOERS_FILE="/etc/sudoers.d/dasc-servicios"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/package"

SRC_BACKUP_SCRIPT="${SCRIPT_DIR}/backups_api.sh"
SRC_SERVICES_SCRIPT="${SCRIPT_DIR}/servicios_api.sh"
OPTIONAL_API_PUBKEY="${SCRIPT_DIR}/api_panel.pub"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

[[ -f "$SRC_BACKUP_SCRIPT" ]] || { echo "ERROR: falta backups_api.sh en ${SCRIPT_DIR}"; exit 1; }
[[ -f "$SRC_SERVICES_SCRIPT" ]] || { echo "ERROR: falta servicios_api.sh en ${SCRIPT_DIR}"; exit 1; }

echo "==> Instalando paquetes necesarios"
apt update
DEBIAN_FRONTEND=noninteractive apt install -y openssh-server mariadb-client sudo

echo "==> Habilitando SSH"
systemctl enable --now ssh

echo "==> Creando usuario de servicio ${APP_USER}"
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${APP_USER}"
fi

mkdir -p "${APP_HOME}/.ssh"
mkdir -p "${BACKUP_DIR}"
chown -R "${APP_USER}:${APP_GROUP}" "${APP_HOME}"
chmod 700 "${APP_HOME}/.ssh"
chmod 755 "${BACKUP_DIR}"

echo "==> Instalando scripts administrativos"
cp "${SRC_BACKUP_SCRIPT}" "${INSTALL_BACKUP_SCRIPT}"
cp "${SRC_SERVICES_SCRIPT}" "${INSTALL_SERVICES_SCRIPT}"
chown root:root "${INSTALL_BACKUP_SCRIPT}" "${INSTALL_SERVICES_SCRIPT}"
chmod 755 "${INSTALL_BACKUP_SCRIPT}" "${INSTALL_SERVICES_SCRIPT}"

echo "==> Creando /home/${APP_USER}/.my.cnf"
cat > "${APP_HOME}/.my.cnf" <<EOF
[client]
user=${DB_BACKUP_USER}
password=${DB_BACKUP_PASS}
host=${DB_HOST}
EOF
chown "${APP_USER}:${APP_GROUP}" "${APP_HOME}/.my.cnf"
chmod 600 "${APP_HOME}/.my.cnf"

echo "==> Configurando sudoers para controlar servicios sin contraseña"
cat > "${SUDOERS_FILE}" <<EOF
${APP_USER} ALL=(ALL) NOPASSWD: /usr/bin/systemctl start *, /usr/bin/systemctl stop *, /usr/bin/systemctl restart *, /usr/bin/systemctl status *, /usr/bin/systemctl is-active *
EOF
chmod 440 "${SUDOERS_FILE}"
visudo -cf "${SUDOERS_FILE}"

if [[ -f "${OPTIONAL_API_PUBKEY}" ]]; then
  echo "==> Instalando clave pública opcional desde api_panel.pub"
  touch "${APP_HOME}/.ssh/authorized_keys"
  grep -qxF "$(cat "${OPTIONAL_API_PUBKEY}")" "${APP_HOME}/.ssh/authorized_keys" || cat "${OPTIONAL_API_PUBKEY}" >> "${APP_HOME}/.ssh/authorized_keys"
  chown "${APP_USER}:${APP_GROUP}" "${APP_HOME}/.ssh/authorized_keys"
  chmod 600 "${APP_HOME}/.ssh/authorized_keys"
else
  echo "==> No se encontró api_panel.pub. Recuerda hacer ssh-copy-id desde la VM API."
fi

echo "==> Validaciones"
systemctl --no-pager --full status ssh || true
ls -l "${INSTALL_BACKUP_SCRIPT}"
ls -l "${INSTALL_SERVICES_SCRIPT}"
ls -ld "${BACKUP_DIR}"
sudo -u "${APP_USER}" test -f "${APP_HOME}/.my.cnf" && echo ".my.cnf OK"
sudo -u "${APP_USER}" mysqldump --protocol=tcp --databases "${DB_NAME}" | head -n 5 || true

echo
echo "============================================"
echo "Servidor de Backups + Servicios instalado"
echo "APP_USER=${APP_USER}"
echo "DB_HOST=${DB_HOST}"
echo "DB_NAME=${DB_NAME}"
echo "Backups en: ${BACKUP_DIR}"
echo "Scripts: ${INSTALL_BACKUP_SCRIPT} y ${INSTALL_SERVICES_SCRIPT}"
echo "============================================"
