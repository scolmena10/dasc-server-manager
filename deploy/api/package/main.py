from dotenv import load_dotenv
load_dotenv("config.env")

from urllib.parse import quote
import os
import json
import subprocess
from pathlib import Path
from datetime import datetime

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

SCRIPT_SERVICIOS = "/usr/local/bin/servicios_api.sh"
SCRIPT_BACKUPS = "/usr/local/bin/backups_api.sh"

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
}


def ensure_users_file():
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    if not USERS_FILE.exists():
        USERS_FILE.write_text("[]", encoding="utf-8")


def load_users():
    ensure_users_file()
    try:
        data = json.loads(USERS_FILE.read_text(encoding="utf-8"))
        if isinstance(data, list):
            valid_users = []
            for item in data:
                if isinstance(item, dict) and item.get("username"):
                    valid_users.append({
                        "username": str(item.get("username")).strip(),
                        "password": str(item.get("password", "")),
                        "permissions": normalize_permissions(item.get("permissions", [])),
                    })
            return valid_users
    except Exception:
        pass
    return []


def save_users(users):
    ensure_users_file()
    USERS_FILE.write_text(
        json.dumps(users, indent=2, ensure_ascii=False),
        encoding="utf-8"
    )


def normalize_permissions(permissions):
    if not isinstance(permissions, list):
        return []
    result = []
    for p in permissions:
        if p in AVAILABLE_PERMISSIONS and p not in result:
            result.append(p)
    return result


def find_user(username: str):
    username = (username or "").strip()
    for user in load_users():
        if user["username"] == username:
            return user
    return None


def get_auth_user(username: str, password: str):
    username = (username or "").strip()
    password = password or ""

    # Admin fijo por defecto
    if username == ADMIN_USER and password == ADMIN_PASSWORD:
        return {
            "username": ADMIN_USER,
            "password": ADMIN_PASSWORD,
            "permissions": list(AVAILABLE_PERMISSIONS.keys()),
            "is_admin": True,
        }

    # Usuarios creados desde panel
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


def get_permissions(request: Request):
    permissions = request.session.get("permissions", [])
    if not isinstance(permissions, list):
        return []
    return permissions


def has_permission(request: Request, permission: str) -> bool:
    return is_admin(request) or permission in get_permissions(request)


def permission_labels_from_keys(keys: list[str]) -> list[str]:
    return [AVAILABLE_PERMISSIONS[k] for k in keys if k in AVAILABLE_PERMISSIONS]


def get_common_context(request: Request):
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
        "permission_labels": permission_labels_from_keys(effective_keys),
        "permissions_count": len(effective_keys),
    }


def permission_redirect(message: str = "No tienes permisos para acceder a esta sección."):
    return RedirectResponse(url=f"/?msg={quote(message)}", status_code=303)


def ssh_run(host: str, script: str, args: list[str]) -> str:
    cmd = ["ssh", f"{USUARIO}@{host}", script] + args
    res = subprocess.run(cmd, capture_output=True, text=True)
    out = (res.stdout or "").strip()
    err = (res.stderr or "").strip()

    if res.returncode != 0:
        return f"ERROR ({res.returncode}): {err or out}"

    return out


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

        response = await call_next(request)

        usuario = request.session.get("user", "anon")
        status = response.status_code

        if path in ["/", "/servicios", "/backups", "/logs", "/admin/usuarios"]:
            tipo = "acceso"
        elif path.startswith("/servicios"):
            tipo = "servicio"
        elif path.startswith("/backups") or path.startswith("/api/backups"):
            tipo = "backup"
        elif path.startswith("/admin"):
            tipo = "admin"
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

# Crear data/users.json si no existe
ensure_users_file()

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
    context["managed_sections"] = sum([
        1 if context["can_backups"] else 0,
        1 if context["can_logs"] else 0,
        1 if context["can_servicios"] else 0,
        1 if context["is_admin"] else 0,
    ])
    context["users_count"] = len(load_users()) + 1 if context["is_admin"] else None
    return templates.TemplateResponse(request, "index.html", context)


# =====================
# ADMINISTRACIÓN USUARIOS
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
    users.append({
        "username": username,
        "password": password,
        "permissions": permissions,
    })
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
# SERVICIOS
# =====================
@app.get("/servicios")
def ver_servicios(request: Request):
    if not has_permission(request, "servicios"):
        return permission_redirect()

    salida = ssh_run(SERVIDOR_SERVICIOS, SCRIPT_SERVICIOS, ["list"])
    ok = request.query_params.get("ok")
    msg = request.query_params.get("msg")

    if salida.startswith("ERROR") and not msg:
        ok = "0"
        msg = salida

    lista_servicios = []
    for linea in salida.split("\n"):
        if "|" in linea:
            nombre, estado = linea.split("|", 1)
            lista_servicios.append({
                "nombre": nombre.strip(),
                "estado": estado.strip(),
            })

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
    ok = 0 if result.startswith("ERROR") else 1
    return RedirectResponse(url=f"/servicios?ok={ok}&msg={quote(result)}", status_code=303)


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

    salida = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, [tipo])
    ok = not salida.startswith("ERROR")

    return {
        "ok": ok,
        "tipo": tipo,
        "resultado": salida,
        "timestamp": datetime.now().isoformat(),
    }


@app.post("/api/test-backups")
def test_backups(request: Request):
    if not has_permission(request, "backups"):
        return JSONResponse(
            {"ok": False, "error": "No tienes permisos"},
            status_code=403,
        )

    salida = ssh_run(SERVIDOR_BACKUPS, "/bin/bash", ["-lc", "hostname && date"])
    ok = not salida.startswith("ERROR")

    return {
        "ok": ok,
        "resultado": salida,
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
    out = ssh_run(SERVIDOR_BACKUPS, SCRIPT_BACKUPS, args)

    ok = 1 if is_ok(out) else 0
    return RedirectResponse(url=f"/backups?ok={ok}&msg={quote(out)}", status_code=303)
