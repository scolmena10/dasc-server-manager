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

echo "==> Instalando ${APP_NAME}"
echo "==> Usuario de ejecución: ${APP_USER}"
echo "==> Ruta destino: ${INSTALL_DIR}"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Ejecuta este script con sudo."
  exit 1
fi

echo "==> Instalando dependencias del sistema"
apt update
apt install -y python3 python3-venv python3-pip openssh-client

echo "==> Creando estructura destino"
mkdir -p "$PADRE_DIR"
mkdir -p "$INSTALL_DIR"

echo "==> Copiando archivos del proyecto"

if [[ ! -d "$PACKAGE_DIR" ]]; then
  echo "Error: No existe la carpeta package"
  exit 1
fi

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
cat > "$SERVICE_FILE" <<EOF
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
EOF

chmod 644 "$SERVICE_FILE"

echo "==> Recargando systemd"
systemctl daemon-reload

echo "==> Activando servicio al arranque"
systemctl enable "$SERVICE_NAME"

echo "==> Reiniciando servicio"
systemctl restart "$SERVICE_NAME"

echo "==> Comprobando estado"
systemctl --no-pager --full status "$SERVICE_NAME" || true

echo
echo "============================================"
echo "Instalación completada"
echo "Panel instalado en: $INSTALL_DIR"
echo "Servicio: $SERVICE_NAME"
echo "URL local: http://127.0.0.1:8000"
echo "URL red:   http://<IP_DEL_SERVIDOR>:8000"
echo "============================================”
