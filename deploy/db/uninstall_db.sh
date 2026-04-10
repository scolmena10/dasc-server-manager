\
#!/usr/bin/env bash
set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "Vas a eliminar MariaDB de esta máquina."
echo "Se borrarán paquetes, configuración y datos de /var/lib/mysql."
read -r -p "Escribe SI para continuar: " CONFIRM

if [[ "$CONFIRM" != "SI" ]]; then
  echo "Cancelado."
  exit 0
fi

echo "==> Parando y deshabilitando MariaDB"
systemctl stop mariadb 2>/dev/null || true
systemctl disable mariadb 2>/dev/null || true

echo "==> Purgando paquetes MariaDB"
PKGS="$(dpkg -l | awk '/^ii/ {print $2}' | grep -E '^mariadb-|^galera-4$' || true)"
if [[ -n "${PKGS}" ]]; then
  apt purge -y ${PKGS} || true
fi
apt autoremove -y || true
apt autoclean -y || true

echo "==> Eliminando directorios de datos y configuración"
rm -rf /etc/mysql
rm -rf /var/lib/mysql
rm -rf /var/log/mysql
rm -rf /var/log/mysql.err

echo
echo "============================================"
echo "MariaDB desinstalada y sistema limpiado"
echo "============================================"
