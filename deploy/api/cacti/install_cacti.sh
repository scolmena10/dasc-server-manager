#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CACTI_DB_PASS="proyecto"
APP_DB_NAME="dasc"
APP_DB_METRICS_PASS="proyecto"

# 0) Root primero
if [[ $EUID -ne 0 ]]; then
  echo "Usa: sudo bash install_cacti_min_fixed.sh"
  exit 1
fi

# 1) Password del admin web
read -s -p "Introduce contraseña para el usuario admin de Cacti: " CACTI_ADMIN_PASS
echo
read -s -p "Repite la contraseña: " CACTI_ADMIN_PASS_CONFIRM
echo
if [[ "$CACTI_ADMIN_PASS" != "$CACTI_ADMIN_PASS_CONFIRM" ]]; then
  echo "❌ Las contraseñas no coinciden"
  exit 1
fi

echo "[1/10] Instalando paquetes..."
apt-get update -y
apt-get install -y \
  apache2 mariadb-server cacti rrdtool snmp snmpd \
  php php-cli php-mysql php-gd php-xml php-mbstring php-intl \
  libapache2-mod-php

echo "[2/10] Apache: PHP + mpm_prefork..."
a2dismod mpm_event >/dev/null 2>&1 || true
a2enmod mpm_prefork >/dev/null 2>&1 || true
a2enmod php* >/dev/null 2>&1 || true
systemctl enable --now apache2 mariadb snmpd
systemctl restart apache2
sleep 2

echo "[3/10] Ajustes PHP recomendados (apache2 + cli)..."
PHP_TZ="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
[[ -z "$PHP_TZ" ]] && PHP_TZ="Europe/Madrid"
PHP_TZ_ESCAPED="$(printf '%s' "$PHP_TZ" | sed 's/[&]/\\&/g')"

for ini in /etc/php/*/apache2/php.ini /etc/php/*/cli/php.ini; do
  [[ -f "$ini" ]] || continue
  sed -i \
    -e "s/^\s*memory_limit\s*=.*/memory_limit = 512M/" \
    -e "s/^\s*max_execution_time\s*=.*/max_execution_time = 60/" \
    -e "s|^\s*;*\s*date\.timezone\s*=.*|date.timezone = ${PHP_TZ_ESCAPED}|" \
    "$ini"
done
systemctl restart apache2

echo "[4/10] Ajustes MariaDB para pasar checks de Cacti (antes de crear BD)..."
# Archivo "99-" para que SIEMPRE tenga prioridad
cat >/etc/mysql/mariadb.conf.d/99-cacti.cnf <<'CNF'
[mysqld]
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci

max_heap_table_size = 64M
tmp_table_size = 64M
join_buffer_size = 16M
sort_buffer_size = 8M

innodb_buffer_pool_size = 1G
innodb_file_per_table = 1
innodb_doublewrite = 0
innodb_flush_method = O_DIRECT
innodb_lock_wait_timeout = 50
CNF

systemctl restart mariadb
sleep 2

echo "[5/10] Creando BD/usuario de Cacti (idempotente)..."
mysql --protocol=socket -uroot <<SQL
CREATE DATABASE IF NOT EXISTS cacti CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
ALTER DATABASE cacti CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;

DROP USER IF EXISTS 'cactiuser'@'localhost';
CREATE USER 'cactiuser'@'localhost' IDENTIFIED BY '${CACTI_DB_PASS}';
GRANT ALL PRIVILEGES ON cacti.* TO 'cactiuser'@'localhost';

FLUSH PRIVILEGES;
SQL

echo "[6/10] Cargando zonas horarias MySQL (si faltan)..."
TZ_COUNT="$(mysql --protocol=socket -uroot -N -e "SELECT COUNT(*) FROM mysql.time_zone_name;" 2>/dev/null || echo 0)"
if [[ "${TZ_COUNT:-0}" -eq 0 ]]; then
  mysql_tzinfo_to_sql /usr/share/zoneinfo | mysql --protocol=socket -uroot mysql || true
fi

mysql --protocol=socket -uroot <<SQL
GRANT SELECT ON mysql.time_zone_name TO 'cactiuser'@'localhost';
FLUSH PRIVILEGES;
SQL

echo "[7/10] Importando tablas de Cacti si faltan..."
if ! mysql --protocol=socket -uroot -N -e \
  "SELECT 1 FROM information_schema.tables WHERE table_schema='cacti' AND table_name='user_auth' LIMIT 1;" \
  | grep -q 1; then

  if [[ -f /usr/share/cacti/cacti.sql ]]; then
    mysql --protocol=socket -uroot cacti < /usr/share/cacti/cacti.sql
  elif [[ -f /usr/share/doc/cacti/cacti.sql ]]; then
    mysql --protocol=socket -uroot cacti < /usr/share/doc/cacti/cacti.sql
  elif [[ -f /usr/share/doc/cacti/cacti.sql.gz ]]; then
    zcat /usr/share/doc/cacti/cacti.sql.gz | mysql --protocol=socket -uroot cacti
  else
    echo "ERROR: No se encuentra cacti.sql"
    dpkg -L cacti | grep -i cacti.sql || true
    exit 1
  fi
fi

echo "[8/10] Escribiendo config.php (DB creds) de forma segura..."
cat > /usr/share/cacti/site/include/config.php <<PHP
<?php
\$database_type = 'mysql';
\$database_default = 'cacti';
\$database_hostname = 'localhost';
\$database_username = 'cactiuser';
\$database_password = '${CACTI_DB_PASS}';
\$database_port = '3306';
\$database_ssl = false;
PHP

echo "[9/10] Forzando password del usuario web admin..."
mysql --protocol=socket -uroot cacti -e \
"UPDATE user_auth SET password=MD5('${CACTI_ADMIN_PASS}'), enabled='on' WHERE username='admin';"

echo "[10/10] Cron del poller (cada 5 min)..."
POLL=""
for p in /usr/share/cacti/site/poller.php /usr/share/cacti/poller.php /var/www/html/cacti/poller.php; do
  [[ -f "$p" ]] && POLL="$p" && break
done
[[ -z "$POLL" ]] && POLL="$(find /usr/share -maxdepth 4 -name poller.php 2>/dev/null | head -n 1 || true)"
[[ -z "$POLL" ]] && POLL="/usr/share/cacti/site/poller.php"

cat > /etc/cron.d/cacti <<CRON
*/5 * * * * www-data php ${POLL} >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/cacti

echo "[Extra] Usuario solo lectura para métricas..."
mysql --protocol=socket -uroot <<SQL
CREATE USER IF NOT EXISTS 'dasc_metrics'@'localhost' IDENTIFIED BY '${APP_DB_METRICS_PASS}';
GRANT SELECT ON ${APP_DB_NAME}.* TO 'dasc_metrics'@'localhost';
FLUSH PRIVILEGES;
SQL

echo
echo "✅ Instalación completada"
echo "Cacti: http://IP_SERVIDOR/cacti"
echo "Login: admin / (la contraseña que has puesto)"