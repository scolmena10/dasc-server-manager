\
#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-dasc}"
APP_HOME="/home/${APP_USER}"
INSTALL_BACKUP_SCRIPT="/usr/local/bin/backups_api.sh"
INSTALL_SERVICES_SCRIPT="/usr/local/bin/servicios_api.sh"
SUDOERS_FILE="/etc/sudoers.d/dasc-servicios"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "Vas a limpiar el servidor de Backups + Servicios."
echo "Se eliminarán:"
echo "  - ${INSTALL_BACKUP_SCRIPT}"
echo "  - ${INSTALL_SERVICES_SCRIPT}"
echo "  - ${SUDOERS_FILE}"
echo "  - usuario ${APP_USER} y su home (${APP_HOME})"
echo "  - paquetes openssh-server y mariadb-client"
read -r -p "Escribe SI para continuar: " CONFIRM

if [[ "${CONFIRM}" != "SI" ]]; then
  echo "Cancelado."
  exit 0
fi

echo "==> Parando y deshabilitando SSH"
systemctl stop ssh 2>/dev/null || true
systemctl disable ssh 2>/dev/null || true

echo "==> Eliminando scripts y sudoers"
rm -f "${INSTALL_BACKUP_SCRIPT}"
rm -f "${INSTALL_SERVICES_SCRIPT}"
rm -f "${SUDOERS_FILE}"

echo "==> Eliminando usuario ${APP_USER}"
if id "${APP_USER}" >/dev/null 2>&1; then
  userdel -r "${APP_USER}" 2>/dev/null || true
fi
rm -rf "${APP_HOME}"

echo "==> Purgando paquetes"
apt purge -y openssh-server mariadb-client || true
apt autoremove -y || true
apt autoclean -y || true

echo
echo "============================================"
echo "Servidor de Backups + Servicios limpiado"
echo "============================================"
