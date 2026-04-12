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
mkdir -p "$PADRE_DIR"
mkdir -p "$INSTALL_DIR"

echo "==> Copiando archivos del proyecto"
cp -r "$PACKAGE_DIR"/. "$INSTALL_DIR"

echo "==> Ajustando permisos"
chown -R "$APP_USER:$APP_GROUP" /opt/dasc
chmod 640 "$INSTALL_DIR/config.env"

echo "==> Creando entorno virtual"
sudo -u "$APP_USER" python3 -m venv "$VENV_DIR"

echo "==> Instalando dependencias Python"
sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install --upgrade pip
sudo -u "$APP_USER" "$VENV_DIR/bin/pip" install -r "$INSTALL_DIR/requirements.txt"

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

echo "==> Preparando clave SSH para la API"
APP_HOME="$(eval echo "~${APP_USER}")"
sudo -u "$APP_USER" mkdir -p "${APP_HOME}/.ssh"
sudo -u "$APP_USER" chmod 700 "${APP_HOME}/.ssh"

if [[ ! -f "${APP_HOME}/.ssh/id_rsa" ]]; then
  sudo -u "$APP_USER" ssh-keygen -t rsa -b 4096 -N "" -f "${APP_HOME}/.ssh/id_rsa"
  echo "==> Clave SSH generada"
else
  echo "==> La clave SSH ya existe, se reutiliza"
fi

cp "${APP_HOME}/.ssh/id_rsa.pub" "${INSTALL_DIR}/api_panel.pub"
chown "$APP_USER:$APP_GROUP" "${INSTALL_DIR}/api_panel.pub"
chmod 644 "${INSTALL_DIR}/api_panel.pub"
echo "==> Clave pública exportada a ${INSTALL_DIR}/api_panel.pub"

BACKUP_HOST="$(awk -F= '/^BACKUPS_HOST=/{print $2}' "$INSTALL_DIR/config.env" | tail -n1 | tr -d '[:space:]' || true)"
if [[ -z "$BACKUP_HOST" ]]; then
  echo "ERROR: no se ha podido obtener BACKUPS_HOST desde config.env"
  exit 1
fi

echo "==> Configurando acceso SSH automático al servidor de backups (${BACKUP_HOST})"
if [[ -z "${DASC_PASS:-}" ]]; then
  echo
  read -rsp "Introduce la contraseña actual del usuario dasc en ${BACKUP_HOST}: " DASC_PASS
  echo
fi

if [[ -z "$DASC_PASS" ]]; then
  echo "ERROR: la contraseña de dasc no puede estar vacía."
  exit 1
fi

sudo -u "$APP_USER" sshpass -p "$DASC_PASS" ssh-copy-id -o StrictHostKeyChecking=no "dasc@${BACKUP_HOST}" || {
  echo "ERROR: no se pudo copiar la clave automáticamente a dasc@${BACKUP_HOST}."
  exit 1
}

echo "==> Verificando acceso SSH sin contraseña"
sudo -u "$APP_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=no "dasc@${BACKUP_HOST}" "hostname >/dev/null" || {
  echo "ERROR: la verificación SSH sin contraseña ha fallado."
  exit 1
}

echo "==> Comprobando estado"
systemctl --no-pager --full status "$SERVICE_NAME" || true
sleep 2
curl -I http://127.0.0.1:8000 || true

echo
echo "============================================"
echo "Instalación completada"
echo "Panel instalado en: $INSTALL_DIR"
echo "Servicio: $SERVICE_NAME"
echo "SSH automático configurado contra: $BACKUP_HOST"
echo "URL local: http://127.0.0.1:8000"
echo "URL red:   http://<IP_DEL_SERVIDOR>:8000"
echo "============================================"
