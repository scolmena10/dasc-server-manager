#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="dasc-api"
INSTALL_DIR="/opt/dasc/api"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

if [[ "$EUID" -ne 0 ]]; then
  echo "ERROR: Ejecuta este script con sudo."
  exit 1
fi

echo "Vas a desinstalar el panel DASC de esta máquina."
echo "Se eliminarán:"
echo "  - $INSTALL_DIR"
echo "  - $SERVICE_FILE"
echo
read -r -p "Escribe SI para continuar: " CONFIRM

if [[ "$CONFIRM" != "SI" ]]; then
  echo "Cancelado."
  exit 0
fi

echo "==> Parando servicio"
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

echo "==> Deshabilitando servicio"
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

echo "==> Eliminando fichero systemd"
rm -f "$SERVICE_FILE"

echo "==> Recargando systemd"
systemctl daemon-reload
systemctl reset-failed || true

echo "==> Eliminando directorio de instalación"
rm -rf "$INSTALL_DIR"

echo
echo "============================================"
echo "Desinstalación completada"
echo "============================================”
