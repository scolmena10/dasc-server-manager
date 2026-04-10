#!/bin/bash

ACCION="$1"
SERVICIO="$2"

if [[ "$ACCION" == "list" ]]; then
    systemctl list-units --type=service --all --no-pager --no-legend | awk '{print $1}' | while read service; do
        estado=$(systemctl is-active "$service")
        echo "$service|$estado"
    done
    exit 0
fi

if [[ "$ACCION" == "start" || "$ACCION" == "stop" || "$ACCION" == "restart" ]]; then
    sudo systemctl $ACCION "$SERVICIO"
    estado=$(systemctl is-active "$SERVICIO")
    echo "$SERVICIO|$estado"
    exit 0
fi

echo "Acción no válida"
exit 1

