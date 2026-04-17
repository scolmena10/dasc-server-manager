from dotenv import load_dotenv
load_dotenv("config.env")

from urllib.parse import quote
from urllib.request import Request as UrlRequest, urlopen
from urllib.error import URLError, HTTPError
import os
import json
import sqlite3
import subprocess
from pathlib import Path
from datetime import datetime
from typing import Any

import pymysql
from fastapi import FastAPI, Request, Form
from fastapi.templating import Jinja2Templates
from fastapi.staticfiles import StaticFiles
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import RedirectResponse, JSONResponse
from starlette.middleware.sessions import SessionMiddleware
from starlette.middleware.base import BaseHTTPMiddleware

app = FastAPI()

# =====================
# CONFIG LOGIN / SESIÓN
# =====================
SECRET_KEY = os.getenv("SECRET_KEY", "cambia-esta-clave-por-una-segura")
ADMIN_USER = os.getenv("ADMIN_USER", "admin")
ADMIN_PASSWORD = os.getenv("ADMIN_PASSWORD", "admin123")

templates = Jinja2Templates(directory="templates")
app.mount("/static", StaticFiles(directory="static"), name="static")

# =====================
# CONFIG MULTI-SERVIDOR
# =====================
USUARIO = os.getenv("SSH_USER", "dasc")
SERVIDOR_BACKUPS = os.getenv("BACKUPS_HOST", "192.168.60.30")
SERVIDOR_SERVICIOS = os.getenv("SERVICIOS_HOST", "192.168.60.30")
CACTI_URL = os.getenv("CACTI_URL", "http://127.0.0.1/cacti/")

LOGS_DB_HOST = os.getenv("LOGS_DB_HOST", "192.168.60.20")
LOGS_DB_NAME = os.getenv("LOGS_DB_NAME", "dasc_logs")
LOGS_DB_USER = os.getenv("LOGS_DB_USER", "dasc_logs")
LOGS_DB_PASS = os.getenv("LOGS_DB_PASS", "dascpass")
LOGS_ORIGIN = os.getenv("LOGS_ORIGIN", "dasc-web")

SCRIPT_SERVICIOS = os.getenv("SCRIPT_SERVICIOS", "/usr/local/bin/servicios_api.sh")
SCRIPT_BACKUPS = os.getenv("SCRIPT_BACKUPS", "/usr/local/bin/backups_api.sh")

# =====================
# ALERTAS TELEGRAM
# =====================
TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN", "").strip()
TELEGRAM_CHAT_ID = os.getenv("TELEGRAM_CHAT_ID", "").strip()
ALERTS_DB_PATH = os.getenv("ALERTS_DB_PATH", "data/alerts.db")
ALERTS_DEFAULT_CHANNEL = os.getenv("ALERTS_DEFAULT_CHANNEL", "telegram")

# =====================
# USUARIOS Y PERMISOS
# =====================
BASE_DIR = Path(__file__).resolve().parent
DATA_DIR = BASE_DIR / "data"
USERS_FILE = DATA_DIR / "users.json"

AVAILABLE_PERMISSIONS = {
    "logs": "Logs",
    "backups": "Copias",
    "servicios": "Servicios",
    "alertas": "Alertas",
}


def ensure_users_file() -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not USERS_FILE.exists():
        USERS_FILE.write_text("[]", encoding="utf-8")


def normalize_permissions(permissions: Any) -> list[str]:
    if not isinstance(permissions, list):
        return []

    result: list[str] = []
    for p in permissions:
        if p in AVAILABLE_PERMISSIONS and p not in result:
            result.append(p)
    return result


def load_users() -> list[dict[str, Any]]:
    ensure_users_file()
    try:
        data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, list):
            valid_users: list[dict[str, Any]] = []
            for item in data:
                if isinstance(item, dict) and item.get("username"):
                    valid_users.append(
                        {
                            "username": str(item.get("username")).strip(),
                            "password": str(item.get("password", "")),
                            "permissions": normalize_permissions(item.get("permissions", [])),
                        }
                    )
            return valid_users
    except Exception:
        pass
    return []


def save_users(users: list[dict[str, Any]]) -> None:
    ensure_users_file()
    USERS_FILE.write_text(
        json.dumps(users, indent=2, ensure_ascii=False),
        encoding="utf-8",
    )


def find_user(username: str) -> dict[str, Any] | None:
    username = (username or "").strip()
    for user in load_users():
        if user["username"] == username:
            return user
    return None


def get_auth_user(username: str, password: str) -> dict[str, Any] | None:
    username = (username or "").strip()
    password = password or ""

    if username == ADMIN_USER and password == ADMIN_PASSWORD:
        return {
            "username": ADMIN_USER,
            "password": ADMIN_PASSWORD,
            "permissions": list(AVAILABLE_PERMISSIONS.keys()),
            "is_admin": True,
        }

    user = find_user(username)
    if user and user["password"] == password:
        return {
            "username": user["username"],
            "password": user["password"],
            "permissions": normalize_permissions(user.get("permissions", [])),
            "is_admin": False,
        }

    return None


def is_authenticated(request: Request) -> bool:
    return request.session.get("user") is not None


def is_admin(request: Request) -> bool:
    return bool(request.session.get("is_admin", False))


def get_permissions(request: Request) -> list[str]:
    permissions = request.session.get("permissions", [])
    if not isinstance(permissions, list):
        return []
    return permissions


def has_permission(request: Request, permission: str) -> bool:
    return is_admin(request) or permission in get_permissions(request)


def permission_labels_from_keys(keys: list[str]) -> list[str]:
    return [AVAILABLE_PERMISSIONS[k] for k in keys if k in AVAILABLE_PERMISSIONS]


def get_common_context(request: Request) -> dict[str, Any]:
    perms = get_permissions(request)
    admin = is_admin(request)
    effective_keys = list(AVAILABLE_PERMISSIONS.keys()) if admin else perms

    return {
        "user": request.session.get("user"),
        "is_admin": admin,
        "role_label": "Administrador" if admin else "Usuario",
        "can_logs": admin or "logs" in perms,
        "can_backups": admin or "backups" in perms,
        "can_servicios": admin or "servicios" in perms,
        "can_alertas": admin or "alertas" in perms,
        "permission_labels": permission_labels_from_keys(effective_keys),
        "permissions_count": len(effective_keys),
    }


def permission_redirect(message: str = "No tienes permisos para acceder a esta sección."):
    return RedirectResponse(url=f"/?msg={quote(message)}", status_code=303)


# =====================
# ALERTAS SQLITE
# =====================
def resolve_alerts_db_path() -> Path:
    raw_path = (ALERTS_DB_PATH or "").strip()
    if not raw_path or raw_path.startswith("/ruta/real/al/proyecto"):
        return BASE_DIR / "data" / "alerts.db"

    db_path = Path(raw_path)
    if not db_path.is_absolute():
        db_path = BASE_DIR / db_path
    return db_path


def get_db() -> sqlite3.Connection:
    db_path = resolve_alerts_db_path()
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    conn.row_factory = sqlite3.Row
    return conn


def init_alerts_db() -> None:
    conn = get_db()
    cur = conn.cursor()

    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS alert_channels (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            code TEXT UNIQUE NOT NULL,
            name TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1,
            token TEXT,
            destination TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    )

    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS alert_rules (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_code TEXT NOT NULL,
            severity TEXT NOT NULL,
            channel_code TEXT NOT NULL,
            is_enabled INTEGER NOT NULL DEFAULT 1
        )
        """
    )

    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS alert_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_code TEXT NOT NULL,
            severity TEXT NOT NULL,
            title TEXT NOT NULL,
            message TEXT NOT NULL,
            source TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        )
        """
    )

    cur.execute(
        """
        CREATE TABLE IF NOT EXISTS alert_deliveries (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            event_id INTEGER NOT NULL,
            channel_code TEXT NOT NULL,
            status TEXT NOT NULL,
            response_text TEXT,
            delivered_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY(event_id) REFERENCES alert_events(id)
        )
        """
    )

    cur.execute(
        """
        INSERT OR IGNORE INTO alert_channels(code, name, is_enabled, token, destination)
        VALUES (?, ?, ?, ?, ?)
        """,
        ("telegram", "Telegram", 1, "", TELEGRAM_CHAT_ID),
    )

    default_rules = [
        ("backup.ok", "info", "telegram", 0),
        ("backup.error", "critical", "telegram", 1),
        ("service.ok", "info", "telegram", 0),
        ("service.error", "critical", "telegram", 1),
        ("api.error", "critical", "telegram", 1),
    ]
    for event_code, severity, channel_code, is_enabled in default_rules:
        cur.execute(
            """
            INSERT INTO alert_rules(event_code, severity, channel_code, is_enabled)
            SELECT ?, ?, ?, ?
            WHERE NOT EXISTS (
                SELECT 1 FROM alert_rules
                WHERE event_code = ? AND channel_code = ?
            )
            """,
            (event_code, severity, channel_code, is_enabled, event_code, channel_code),
        )

    cur.execute(
        """
        UPDATE alert_channels
        SET destination = COALESCE(NULLIF(?, ''), destination)
        WHERE code = 'telegram'
        """,
        (TELEGRAM_CHAT_ID,),
    )

    conn.commit()
    conn.close()


@app.on_event("startup")
def startup_event() -> None:
    ensure_users_file()
    init_alerts_db()


def send_telegram_message(text: str, chat_id: str | None = None) -> dict[str, Any]:
    token = TELEGRAM_BOT_TOKEN
    target_chat = (chat_id or TELEGRAM_CHAT_ID).strip()

    if not token or not target_chat:
        return {"ok": False, "status": "ERROR", "text": "Falta TELEGRAM_BOT_TOKEN o TELEGRAM_CHAT_ID en config.env"}

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    payload = json.dumps(
        {
            "chat_id": target_chat,
            "text": text,
            "parse_mode": "HTML",
            "disable_web_page_preview": True,
        }
    ).encode("utf-8")

    req = UrlRequest(
        url,
        data=payload,
        headers={"Content-Type": "application/json; charset=utf-8"},
        method="POST",
    )

    try:
        with urlopen(req, timeout=15) as response:
            raw = response.read().decode("utf-8", errors="replace")
            data = json.loads(raw)
            return {
                "ok": bool(data.get("ok") is True),
                "status": response.status,
                "text": json.dumps(data, ensure_ascii=False),
            }
    except HTTPError as e:
        body = e.read().decode("utf-8", errors="replace") if hasattr(e, "read") else str(e)
        return {"ok": False, "status": e.code, "text": body}
    except URLError as e:
        return {"ok": False, "status": "ERROR", "text": str(e.reason)}
    except Exception as e:
        return {"ok": False, "status": "ERROR", "text": str(e)}


def emit_alert(event_code: str, severity: str, title: str, message: str, source: str) -> int:
    conn = get_db()
    cur = conn.cursor()

    cur.execute(
        """
        INSERT INTO alert_events(event_code, severity, title, message, source)
        VALUES (?, ?, ?, ?, ?)
        """,
        (event_code, severity, title, message, source),
    )
    event_id = int(cur.lastrowid)

    cur.execute(
        """
        SELECT r.channel_code
        FROM alert_rules r
        JOIN alert_channels c ON c.code = r.channel_code
        WHERE r.event_code = ? AND r.is_enabled = 1 AND c.is_enabled = 1
        """,
        (event_code,),
    )
    rules = cur.fetchall()
    channels = [row["channel_code"] for row in rules] or [ALERTS_DEFAULT_CHANNEL]

    for channel_code in channels:
        if channel_code == "telegram":
            result = send_telegram_message(message)
            status = "OK" if result["ok"] else "ERROR"
            cur.execute(
                """
                INSERT INTO alert_deliveries(event_id, channel_code, status, response_text)
                VALUES (?, ?, ?, ?)
                """,
                (event_id, channel_code, status, result["text"]),
            )

    conn.commit()
    conn.close()
    return event_id


def get_alert_stats() -> dict[str, Any]:
    conn = get_db()
    cur = conn.cursor()

    cur.execute("SELECT COUNT(*) AS total FROM alert_events")
    total_events = int(cur.fetchone()["total"])

    cur.execute("SELECT COUNT(*) AS total FROM alert_deliveries")
    total_deliveries = int(cur.fetchone()["total"])

    cur.execute("SELECT COUNT(*) AS total FROM alert_deliveries WHERE status = 'OK'")
    ok_deliveries = int(cur.fetchone()["total"])

    cur.execute("SELECT delivered_at FROM alert_deliveries ORDER BY id DESC LIMIT 1")
    last_delivery = cur.fetchone()

    conn.close()

    return {
        "alerts_total": total_events,
        "alerts_deliveries": total_deliveries,
        "alerts_ok": ok_deliveries,
        "alerts_error": total_deliveries - ok_deliveries,
        "alerts_last": last_delivery["delivered_at"] if last_delivery else None,
    }


# =====================
# SSH + LOGS
# =====================
def ssh_run(host: str, script: str, args: list[str]) -> dict[str, Any]:
    cmd = ["ssh", f"{USUARIO}@{host}", script] + args
    res = subprocess.run(cmd, capture_output=True, text=True)

    out = (res.stdout or "").strip()
    err = (res.stderr or "").strip()

    return {
        "ok": res.returncode == 0,
        "code": res.returncode,
        "host": host,
        "stdout": out,
        "stderr": err,
        "text": out if res.returncode == 0 else f"ERROR ({res.returncode}): {err or out}",
    }


def log_event(
    tipo: str,
    resultado: str,
    usuario: str | None = "anon",
    ip_origen: str | None = None,
    recurso: str | None = None,
    detalle: str | None = None,
) -> None:
    try:
        conn = pymysql.connect(
            host=LOGS_DB_HOST,
            user=LOGS_DB_USER,
            password=LOGS_DB_PASS,
            database=LOGS_DB_NAME,
            autocommit=True,
            connect_timeout=2,
        )
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO eventos(origen,tipo,usuario,ip_origen,recurso,resultado,detalle)
                VALUES (%s,%s,%s,%s,%s,%s,%s)
                """,
                (LOGS_ORIGIN, tipo, usuario, ip_origen, recurso, resultado, detalle),
            )
        conn.close()
    except Exception as e:
        print(f"Error guardando evento: {e}")


class AuthAndLogMiddleware(BaseHTTPMiddleware):
    async def dispatch(self, request: Request, call_next):
        ip = request.client.host if request.client else None
        path = request.url.path
        method = request.method

        public_routes = {"/login"}
        public_prefixes = ("/static", "/favicon.ico")

        is_public = path in public_routes or any(path.startswith(p) for p in public_prefixes)

        if not is_public and not is_authenticated(request):
            log_event(
                tipo="acceso",
                resultado="ERROR",
                usuario="anon",
                ip_origen=ip,
                recurso=f"{method} {path}",
                detalle="Acceso bloqueado por no autenticado",
            )
            return RedirectResponse(url="/login", status_code=303)

        try:
            response = await call_next(request)
        except Exception as e:
            usuario = request.session.get("user", "anon")
            detalle = f"Excepción no controlada: {e}"
            log_event(
                tipo="api",
                resultado="ERROR",
                usuario=usuario,
                ip_origen=ip,
                recurso=f"{method} {path}",
                detalle=detalle,
            )
            try:
                emit_alert(
                    "api.error",
                    "critical",
                    "Error interno de la API",
                    (
                        "<b>API ERROR</b>\n"
                        f"Ruta: {path}\n"
                        f"Método: {method}\n"
                        f"Detalle: {str(e)}"
                    ),
                    "api",
                )
            except Exception as alert_error:
                print(f"Error enviando alerta de API: {alert_error}")
            raise

        usuario = request.session.get("user", "anon")
        status = response.status_code

        if path in ["/", "/servicios", "/backups", "/logs", "/admin/usuarios", "/alertas"]:
            tipo = "acceso"
        elif path.startswith("/servicios"):
            tipo = "servicio"
        elif path.startswith("/backups") or path.startswith("/api/backups"):
            tipo = "backup"
        elif path.startswith("/admin"):
            tipo = "admin"
        elif path.startswith("/alertas"):
            tipo = "alerta"
        elif path.startswith("/login") or path.startswith("/logout"):
            tipo = "login"
        else:
            tipo = "acceso"

        resultado = "OK" if status < 400 else "ERROR"
        log_event(
            tipo=tipo,
            resultado=resultado,
            usuario=usuario,
            ip_origen=ip,
            recurso=f"{method} {path}",
            detalle=f"HTTP {status}",
        )

        return response


app.add_middleware(AuthAndLogMiddleware)
app.add_middleware(SessionMiddleware, secret_key=SECRET_KEY)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =====================
# LOGIN / LOGOUT
# =====================
@app.get("/login")
def login_page(request: Request):
    if is_authenticated(request):
        return RedirectResponse(url="/", status_code=303)

    error = request.query_params.get("error")
    return templates.TemplateResponse(
        request,
        "login.html",
        {
            "error": error,
        },
    )


@app.post("/login")
def login(request: Request, username: str = Form(...), password: str = Form(...)):
    auth_user = get_auth_user(username, password)
    if auth_user:
        request.session["user"] = auth_user["username"]
        request.session["is_admin"] = auth_user["is_admin"]
        request.session["permissions"] = auth_user["permissions"]
        return RedirectResponse(url="/", status_code=303)

    return RedirectResponse(url="/login?error=1", status_code=303)


@app.get("/logout")
def logout_get(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


@app.post("/logout")
def logout_post(request: Request):
    request.session.clear()
    return RedirectResponse(url="/login", status_code=303)


# =====================
# PANEL PRINCIPAL
# =====================
@app.get("/")
def home(request: Request):
    context = get_common_context(request)
    context["msg"] = request.query_params.get("msg")
    context["managed_sections"] = sum(
        [
            1 if context["can_backups"] else 0,
            1 if context["can_logs"] else 0,
            1 if context["can_servicios"] else 0,
            1 if context["can_alertas"] else 0,
            1 if context["is_admin"] else 0,
        ]
    )
    context["users_count"] = len(load_users()) + 1 if context["is_admin"] else None
    context.update(get_alert_stats())
    return templates.TemplateResponse(request, "index.html", context)


# =====================
# ADMIN USUARIOS
# =====================
@app.get("/admin/usuarios")
def admin_users_page(request: Request):
    if not is_admin(request):
        return permission_redirect()

    context = get_common_context(request)
    context["ok"] = request.query_params.get("ok")
    context["msg"] = request.query_params.get("msg")
    context["users"] = load_users()
    context["available_permissions"] = AVAILABLE_PERMISSIONS
    context["users_count"] = len(context["users"]) + 1
    return templates.TemplateResponse(request, "admin_users.html", context)


@app.post("/admin/usuarios")
def create_user(
    request: Request,
    username: str = Form(...),
    password: str = Form(...),
    permissions: list[str] = Form([]),
):
    if not is_admin(request):
        return permission_redirect()

    username = (username or "").strip()
    password = (password or "").strip()
    permissions = normalize_permissions(permissions)

    if " " in username:
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=El+usuario+no+puede+contener+espacios",
            status_code=303,
        )

    if not username or not password:
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=Usuario+y+contraseña+son+obligatorios",
            status_code=303,
        )

    if username == ADMIN_USER:
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=No+puedes+crear+otro+usuario+con+el+nombre+del+admin",
            status_code=303,
        )

    if find_user(username):
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=Ese+usuario+ya+existe",
            status_code=303,
        )

    users = load_users()
    users.append(
        {
            "username": username,
            "password": password,
            "permissions": permissions,
        }
    )
    save_users(users)

    return RedirectResponse(
        url="/admin/usuarios?ok=1&msg=Usuario+creado+correctamente",
        status_code=303,
    )


@app.post("/admin/usuarios/delete")
def delete_user(
    request: Request,
    username: str = Form(...),
):
    if not is_admin(request):
        return permission_redirect()

    username = (username or "").strip()

    if username == ADMIN_USER:
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=El+usuario+admin+no+se+puede+eliminar",
            status_code=303,
        )

    users = load_users()
    filtered = [u for u in users if u["username"] != username]

    if len(filtered) == len(users):
        return RedirectResponse(
            url="/admin/usuarios?ok=0&msg=Usuario+no+encontrado",
            status_code=303,
        )

    save_users(filtered)
    return RedirectResponse(
        url="/admin/usuarios?ok=1&msg=Usuario+eliminado+correctamente",
        status_code=303,
    )


# =====================
# LOGS
# =====================
@app.get("/logs")
def ver_logs(request: Request):
    if not has_permission(request, "logs"):
        return permission_redirect()

    try:
        conn = pymysql.connect(
            host=LOGS_DB_HOST,
            user=LOGS_DB_USER,
            password=LOGS_DB_PASS,
            database=LOGS_DB_NAME,
            autocommit=True,
            connect_timeout=2,
            cursorclass=pymysql.cursors.DictCursor,
        )
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT id, fecha, origen, tipo, usuario, ip_origen, recurso, resultado, detalle
                FROM eventos
                ORDER BY fecha DESC
                LIMIT 100
                """
            )
            eventos = cur.fetchall()
        conn.close()
    except Exception as e:
        eventos = []
        print(f"Error cargando eventos: {e}")

    context = get_common_context(request)
    context["cacti_url"] = CACTI_URL
    context["eventos"] = eventos
    context["logs_total"] = len(eventos)
    context["logs_ok"] = sum(1 for e in eventos if e.get("resultado") == "OK")
    context["logs_error"] = sum(1 for e in eventos if e.get("resultado") != "OK")
    context["logs_last"] = eventos[0].get("fecha") if eventos else None
    return templates.TemplateResponse(request, "logs.html", context)


# =====================
# ALERTAS
# =====================
@app.get("/alertas")
def alertas(request: Request):
    if not has_permission(request, "alertas"):
        return permission_redirect()

    conn = get_db()
    cur = conn.cursor()

    cur.execute("SELECT * FROM alert_channels ORDER BY id")
    channels = [dict(row) for row in cur.fetchall()]

    cur.execute("SELECT * FROM alert_rules ORDER BY event_code")
    rules = [dict(row) for row in cur.fetchall()]

    cur.execute(
        """
        SELECT d.delivered_at, e.event_code, e.title, d.channel_code, d.status
        FROM alert_deliveries d
        JOIN alert_events e ON e.id = d.event_id
        ORDER BY d.id DESC
        LIMIT 20
        """
    )
    deliveries = [dict(row) for row in cur.fetchall()]
    conn.close()

    context = get_common_context(request)
    context["channels"] = channels
    context["rules"] = rules
    context["deliveries"] = deliveries
    context["ok"] = request.query_params.get("ok")
    context["msg"] = request.query_params.get("msg")
    context.update(get_alert_stats())

    return templates.TemplateResponse(request, "alertas.html", context)


@app.post("/alertas/test")
def alertas_test(request: Request):
    if not has_permission(request, "alertas"):
        return RedirectResponse(
            url="/alertas?ok=0&msg=No+tienes+permisos",
            status_code=303,
        )

    text = (
        "<b>DASC</b>\n"
        "Prueba de alerta Telegram desde el panel.\n"
        f"Usuario: {request.session.get('user', 'anon')}\n"
        f"Hora: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
    )

    result = send_telegram_message(text)

    if result.get("ok"):
        msg = "Prueba+de+Telegram+enviada+correctamente"
    else:
        error_text = str(result.get("text") or result.get("error") or "Error+desconocido")
        msg = quote(error_text)

    return RedirectResponse(
        url=f"/alertas?ok={1 if result.get('ok') else 0}&msg={msg}",
        status_code=303,
    )


@app.post("/alertas/rule/toggle")
def alertas_rule_toggle(request: Request, rule_id: int = Form(...)):
    if not has_permission(request, "alertas"):
        return permission_redirect()

    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE alert_rules
        SET is_enabled = CASE WHEN is_enabled = 1 THEN 0 ELSE 1 END
        WHERE id = ?
        """,
        (rule_id,),
    )
    conn.commit()
    conn.close()

    return RedirectResponse(
        url="/alertas?ok=1&msg=Regla+actualizada",
        status_code=303,
    )


@app.post("/alertas/channel/toggle")
def alertas_channel_toggle(request: Request, channel_code: str = Form(...)):
    if not has_permission(request, "alertas"):
        return permission_redirect()

    conn = get_db()
    cur = conn.cursor()
    cur.execute(
        """
        UPDATE alert_channels
        SET is_enabled = CASE WHEN is_enabled = 1 THEN 0 ELSE 1 END
        WHERE code = ?
        """,
        (channel_code,),
    )
    conn.commit()
    conn.close()

    return RedirectResponse(
        url="/alertas?ok=1&msg=Canal+actualizado",
        status_code=303,
    )


# =====================
# SERVICIOS
# =====================
@app.get("/servicios")
def ver_servicios(request: Request):
    if not has_permission(request, "servicios"):
        return permission_redirect()

    result = ssh_run(SERVIDOR_SERVICIOS, SCRIPT_SERVICIOS, ["list"])
    salida = result["text"]

    ok = request.query_params.get("ok")
    msg = request.query_params.get("msg")

    if salida.startswith("ERROR") and not msg:
        ok = "0"
        msg = salida

    lista_servicios: list[dict[str, str]] = []
    for linea in salida.split("\n"):
        if "|" in linea:
            nombre, estado = linea.split("|", 1)
            lista_servicios.append(
                {
                    "nombre": nombre.strip(),
                    "estado": estado.strip(),
                }
            )

    context = get_common_context(request)
    context["servicios"] = lista_servicios
    context["ok"] = ok
    context["msg"] = msg
    context["services_total"] = len(lista_servicios)
    context["services_active"] = sum(1 for s in lista_servicios if s["estado"] == "active")
    context["services_inactive"] = len(lista_servicios) - context["services_active"]
    return templates.TemplateResponse(request, "servicios.html", context)


@app.post("/servicios/accion")
def accion_servicio(
    request: Request,
    service: str = Form(...),
    action: str = Form(...),
):
    if not has_permission(request, "servicios"):
        return permission_redirect()

    result = ssh_run(SERVIDOR_SERVICIOS, SCRIPT_SERVICIOS, [action, service])
    ok = 1 if result["ok"] else 0

    if result["ok"]:
        emit_alert(
            "service.ok",
            "info",
            "Acción de servicio completada",
            (
                "<b>Servicio OK</b>\n"
                f"Acción: {action}\n"
                f"Servicio: {service}\n"
                f"Servidor: {SERVIDOR_SERVICIOS}"
            ),
            "services",
        )
    else:
        emit_alert(
            "service.error",
            "critical",
            "Error en servicio",
            (
                "<b>Servicio ERROR</b>\n"
                f"Acción: {action}\n"
                f"Servicio: {service}\n"
                f"Servidor: {SERVIDOR_SERVICIOS}\n"
                f"Detalle: {result['text']}"
            ),
            "services",
        )

    return RedirectResponse(
        url=f"/servicios?ok={ok}&msg={quote(result['text'])}",
        status_code=303,
    )


# =====================
# BACKUPS
# =====================
@app.get("/backups")
def backups(request: Request):
    if not has_permission(request, "backups"):
        return permission_redirect()

    ok = request.query_params.get("ok")
    msg = request.query_params.get("msg")

    context = get_common_context(request)
    context["ok"] = ok
    context["msg"] = msg
    context["cacti_url"] = CACTI_URL
    return templates.TemplateResponse(request, "backups.html", context)


@app.post("/api/backups/{tipo}")
def ejecutar_backup(request: Request, tipo: str):
    if not has_permission(request, "backups"):
        return JSONResponse(
            {"ok": False, "error": "No tienes permisos"},
            status_code=403,
        )

    if tipo not in ["full", "incremental", "differential"]:
        return JSONResponse(
            {"ok": False, "error": "Tipo de backup no válido"},
            status_code=400,
        )

    result = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, [tipo])
    ok = result["ok"]

    if ok:
        emit_alert(
            "backup.ok",
            "info",
            "Backup completado",
            (
                "<b>Backup OK</b>\n"
                f"Tipo: {tipo}\n"
                f"Servidor: {SERVIDOR_BACKUPS}"
            ),
            "backups",
        )
    else:
        emit_alert(
            "backup.error",
            "critical",
            "Error en backup",
            (
                "<b>Backup ERROR</b>\n"
                f"Tipo: {tipo}\n"
                f"Servidor: {SERVIDOR_BACKUPS}\n"
                f"Detalle: {result['text']}"
            ),
            "backups",
        )

    return {
        "ok": ok,
        "tipo": tipo,
        "resultado": result["text"],
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/api/test-backups")
def test_backups(request: Request):
    if not has_permission(request, "backups"):
        return JSONResponse(
            {"ok": False, "error": "No tienes permisos"},
            status_code=403,
        )

    result = ssh_run(SERVIDOR_BACKUPS, "/bin/bash", ["-lc", "hostname && date"])
    return {
        "ok": result["ok"],
        "resultado": result["text"],
    }


def is_ok(output: str) -> bool:
    if not output:
        return False

    o = output.lower()
    return (
        o.startswith("ok")
        or "backup creado" in o
        or "backup completed" in o
        or "success" in o
    )


@app.post("/backups/run")
def backups_run(
    request: Request,
    type: str = Form(...),
    db: str = Form(...),
    dest: str = Form("/home/dasc/backups"),
    name: str = Form(...),
    compress: str = Form("gzip"),
    retention: int = Form(7),
    base_ref: str = Form(""),
    notes: str = Form(""),
):
    if not has_permission(request, "backups"):
        return permission_redirect()

    if type not in ["full", "incremental", "differential"]:
        return RedirectResponse(
            url="/backups?ok=0&msg=Tipo+de+backup+no+valido",
            status_code=303,
        )

    args = [type, db, dest, name, compress, str(retention), base_ref, notes]
    result = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, args)
    ok = 1 if (result["ok"] and is_ok(result["text"])) else 0

    if ok:
        emit_alert(
            "backup.ok",
            "info",
            "Backup completado",
            (
                "<b>Backup OK</b>\n"
                f"BD: {db}\n"
                f"Tipo: {type}\n"
                f"Destino: {dest}\n"
                f"Servidor: {SERVIDOR_BACKUPS}"
            ),
            "backups",
        )
    else:
        emit_alert(
            "backup.error",
            "critical",
            "Error en backup",
            (
                "<b>Backup ERROR</b>\n"
                f"BD: {db}\n"
                f"Tipo: {type}\n"
                f"Servidor: {SERVIDOR_BACKUPS}\n"
                f"Detalle: {result['text']}"
            ),
            "backups",
        )

    return RedirectResponse(
        url=f"/backups?ok={ok}&msg={quote(result['text'])}",
        status_code=303,
    )
