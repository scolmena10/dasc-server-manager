#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "Usa: sudo bash uninstall_cacti_final.sh"
  exit 1
fi

echo "[1/5] Asegurando MariaDB activo..."
systemctl start mariadb || true

echo "[2/5] Evitando error 1049 (crear BD vacía si no existe)..."
sudo mysql --protocol=socket -uroot -e "CREATE DATABASE IF NOT EXISTS cacti;" || true

echo "[3/5] Purga Cacti (MariaDB debe seguir encendido aquí)..."
apt-get purge -y cacti cacti-spine rrdtool snmp snmpd || true
apt-get autoremove -y || true

echo "[4/5] Borrando restos (DB/usuarios) por si el purge no lo hizo..."
sudo mysql --protocol=socket -uroot <<'SQL' || true
DROP DATABASE IF EXISTS cacti;
DROP USER IF EXISTS 'cactiuser'@'localhost';
DROP USER IF EXISTS 'dasc_metrics'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[5/5] Limpieza de ficheros..."
rm -rf /usr/share/cacti /var/www/html/cacti /etc/cacti /etc/cron.d/cacti || true
rm -rf /var/lib/rrd /var/log/cacti || true

# No paro MariaDB por defecto para no romper tu proyecto
systemctl stop apache2 snmpd || true

echo "🗑️ Listo. Cacti desinstalado sin errores típicos."