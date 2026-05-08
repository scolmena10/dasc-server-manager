#!/usr/bin/env bash
set -euo pipefail

APP_NAME="DASC Server Manager"
SERVICE_NAME="dasc-api"
APP_USER="${SUDO_USER:-$USER}"
APP_GROUP="$APP_USER"
PADRE_DIR="/opt/dasc"
INSTALL_DIR="/opt/dasc/api"
VENV_DIR="$INSTALL_DIR/venv"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

DASC_SSH_DIR="${INSTALL_DIR}/.ssh"
DASC_KEY="${DASC_SSH_DIR}/id_rsa_dasc"
DASC_KNOWN_HOSTS="${DASC_SSH_DIR}/known_hosts_dasc"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/package"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: ejecuta este script con sudo."
  exit 1
fi

echo "==> Instalando ${APP_NAME}"
echo "==> Usuario de ejecución: ${APP_USER}"
echo "==> Ruta destino: ${INSTALL_DIR}"

if [[ ! -d "$PACKAGE_DIR" ]]; then
  echo "ERROR: no existe la carpeta package/"
  exit 1
fi

for required in main.py requirements.txt config.env templates static; do
  if [[ ! -e "$PACKAGE_DIR/$required" ]]; then
    echo "ERROR: falta $required dentro de package/"
    exit 1
  fi
done

echo "==> Instalando dependencias del sistema"
apt update
apt install -y python3 python3-venv python3-pip openssh-client curl sshpass

echo "==> Creando estructura destino"
mkdir -p "$PADRE_DIR" "$INSTALL_DIR" "$DASC_SSH_DIR"

echo "==> Copiando archivos del proyecto"
cp -r "$PACKAGE_DIR"/. "$INSTALL_DIR"

echo "==> Ajustando permisos iniciales"
chown -R "$APP_USER:$APP_GROUP" "$PADRE_DIR"
chmod 640 "$INSTALL_DIR/config.env"
chmod 700 "$DASC_SSH_DIR"

echo
if [[ -z "${ADMIN_PASSWORD:-}" ]]; then
  read -rsp "Introduce la contraseña del usuario admin del panel: " ADMIN_PASSWORD
  echo
  read -rsp "Repite la contraseña del usuario admin del panel: " ADMIN_PASSWORD_CONFIRM
  echo

  if [[ "$ADMIN_PASSWORD" != "$ADMIN_PASSWORD_CONFIRM" ]]; then
    echo "ERROR: las contraseñas del admin no coinciden."
    exit 1
  fi
fi

if [[ -z "$ADMIN_PASSWORD" ]]; then
  echo "ERROR: la contraseña del admin no puede estar vacía."
  exit 1
fi

echo "==> Configurando credenciales del panel"
sed -i -E 's|^ADMIN_USER=.*|ADMIN_USER=admin|' "$INSTALL_DIR/config.env"
ADMIN_PASSWORD_ESCAPED="$(printf '%s' "$ADMIN_PASSWORD" | sed 's/[\/&]/\\&/g')"
sed -i -E "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ADMIN_PASSWORD_ESCAPED}|" "$INSTALL_DIR/config.env"

echo "==> Creando entorno virtual"
sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"

echo "==> Instalando dependencias Python"
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -m pip install --upgrade pip setuptools wheel
sudo -u "$APP_USER" "$VENV_DIR/bin/python" -m pip install -r "$INSTALL_DIR/requirements.txt"

if [[ ! -x "$VENV_DIR/bin/uvicorn" ]]; then
  echo "ERROR: no existe $VENV_DIR/bin/uvicorn después de instalar dependencias"
  exit 1
fi

echo "==> Preparando SSH aislado de DASC"
touch "$DASC_KNOWN_HOSTS"
chown "$APP_USER:$APP_GROUP" "$DASC_KNOWN_HOSTS"
chmod 644 "$DASC_KNOWN_HOSTS"

if [[ ! -f "$DASC_KEY" ]]; then
  echo "==> Generando clave SSH propia de DASC"
  sudo -u "$APP_USER" ssh-keygen -t rsa -b 4096 -N "" -f "$DASC_KEY"
else
  echo "==> La clave SSH propia de DASC ya existe, se reutiliza"
fi

chown "$APP_USER:$APP_GROUP" "$DASC_KEY" "${DASC_KEY}.pub"
chmod 600 "$DASC_KEY"
chmod 644 "${DASC_KEY}.pub"

cp "${DASC_KEY}.pub" "${INSTALL_DIR}/api_panel.pub"
chown "$APP_USER:$APP_GROUP" "${INSTALL_DIR}/api_panel.pub"
chmod 644 "${INSTALL_DIR}/api_panel.pub"
echo "==> Clave pública exportada a ${INSTALL_DIR}/api_panel.pub"

BACKUP_HOST="$(awk -F= '/^BACKUPS_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$BACKUP_HOST" ]]; then
  echo "ERROR: no se ha podido obtener BACKUPS_HOST desde config.env"
  exit 1
fi

DATABASE_HOST="$(awk -F= '/^TERMINAL_DATABASE_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$DATABASE_HOST" ]]; then
  DATABASE_HOST="$(awk -F= '/^LOGS_DB_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
fi
if [[ -z "$DATABASE_HOST" ]]; then
  DATABASE_HOST="192.168.60.20"
fi

configure_ssh_target() {
  local TARGET_HOST="$1"
  local TARGET_LABEL="$2"
  local TARGET_PASS="${3:-}"

  if [[ -z "$TARGET_HOST" ]]; then
    echo "==> Saltando ${TARGET_LABEL}: host vacío"
    return 0
  fi

  echo "==> Limpiando huellas SSH antiguas para ${TARGET_LABEL} (${TARGET_HOST})"
  sudo -u "$APP_USER" ssh-keygen -R "$TARGET_HOST" -f "$DASC_KNOWN_HOSTS" >/dev/null 2>&1 || true

  echo "==> Registrando host key actual de ${TARGET_LABEL} (${TARGET_HOST})"
  if ! sudo -u "$APP_USER" ssh-keyscan -H "$TARGET_HOST" >> "$DASC_KNOWN_HOSTS" 2>/dev/null; then
    echo "ERROR: no se pudo obtener la host key con ssh-keyscan para ${TARGET_HOST}"
    exit 1
  fi
  chown "$APP_USER:$APP_GROUP" "$DASC_KNOWN_HOSTS"
  chmod 644 "$DASC_KNOWN_HOSTS"

  if [[ -z "$TARGET_PASS" ]]; then
    echo
    read -rsp "Introduce la contraseña actual del usuario dasc en ${TARGET_LABEL} (${TARGET_HOST}): " TARGET_PASS
    echo
  fi

  if [[ -z "$TARGET_PASS" ]]; then
    echo "ERROR: la contraseña de dasc para ${TARGET_LABEL} no puede estar vacía."
    exit 1
  fi

  echo "==> Copiando clave SSH de DASC a ${TARGET_LABEL} (${TARGET_HOST})"
  sudo -u "$APP_USER" sshpass -p "$TARGET_PASS" ssh-copy-id \
    -i "${DASC_KEY}.pub" \
    -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
    -o StrictHostKeyChecking=no \
    "dasc@${TARGET_HOST}" || {
      echo "ERROR: no se pudo copiar la clave automáticamente a dasc@${TARGET_HOST}."
      exit 1
    }

  echo "==> Verificando SSH sin contraseña contra ${TARGET_LABEL} (${TARGET_HOST})"
  sudo -u "$APP_USER" ssh \
    -i "$DASC_KEY" \
    -o BatchMode=yes \
    -o StrictHostKeyChecking=yes \
    -o UserKnownHostsFile="$DASC_KNOWN_HOSTS" \
    "dasc@${TARGET_HOST}" "hostname >/dev/null" || {
      echo "ERROR: la verificación SSH sin contraseña ha fallado contra ${TARGET_HOST}."
      exit 1
    }
}

configure_ssh_target "$BACKUP_HOST" "servidor de backups" "${DASC_BACKUP_PASS:-${DASC_PASS:-}}"

if [[ "$DATABASE_HOST" == "$BACKUP_HOST" ]]; then
  echo "==> TERMINAL_DATABASE_HOST coincide con BACKUPS_HOST; no se repite la configuración SSH."
else
  configure_ssh_target "$DATABASE_HOST" "servidor de base de datos" "${DASC_DB_PASS:-${DASC_PASS:-}}"
fi

echo "==> Creando servicio systemd"
cat > "$SERVICE_FILE" <<EOF2
[Unit]
Description=DASC Panel + API (FastAPI/Uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
User=${APP_USER}
Group=${APP_GROUP}
WorkingDirectory=${INSTALL_DIR}
EnvironmentFile=${INSTALL_DIR}/config.env
ExecStart=${VENV_DIR}/bin/uvicorn main:app --host 0.0.0.0 --port 8000
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF2
chmod 644 "$SERVICE_FILE"

echo "==> Recargando systemd"
systemctl daemon-reload

echo "==> Activando servicio al arranque"
systemctl enable "$SERVICE_NAME"

echo "==> Reiniciando servicio"
systemctl restart "$SERVICE_NAME"

echo "==> Reajustando permisos finales"
chown -R "$APP_USER:$APP_GROUP" "$PADRE_DIR"
chmod 640 "$INSTALL_DIR/config.env"
chmod 700 "$DASC_SSH_DIR"
chmod 600 "$DASC_KEY"
chmod 644 "${DASC_KEY}.pub" "$DASC_KNOWN_HOSTS"

echo "==> Comprobando estado"
systemctl --no-pager --full status "$SERVICE_NAME" || true
sleep 2
curl -I http://127.0.0.1:8000 || true

echo
echo "============================================"
echo "Instalación completada"
echo "Panel instalado en: $INSTALL_DIR"
echo "Servicio: $SERVICE_NAME"
echo "Usuario admin del panel: admin"
echo "SSH aislado de DASC: ${DASC_SSH_DIR}"
echo "Clave usada: ${DASC_KEY}"
echo "Known hosts usado: ${DASC_KNOWN_HOSTS}"
echo "SSH automático configurado contra backups: $BACKUP_HOST"
echo "SSH automático configurado contra DB terminal: $DATABASE_HOST"
echo "URL local: http://127.0.0.1:8000"
echo "URL red:   http://<IP_DEL_SERVIDOR>:8000"
echo "============================================"
