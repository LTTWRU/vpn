import os
import json
import base64
import secrets
import sqlite3
import logging
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.responses import Response
import httpx

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

XUI_URL = os.getenv("XUI_URL", "http://3xui:2053")
XUI_USERNAME = os.getenv("XUI_USERNAME", "admin")
XUI_PASSWORD = os.getenv("XUI_PASSWORD", "admin")
SERVER_DOMAIN = os.getenv("SERVER_DOMAIN", "")
ADMIN_TOKEN = os.getenv("ADMIN_TOKEN", "")
INBOUND_ID = int(os.getenv("INBOUND_ID", "1"))
DB_PATH = "/app/data/subscriptions.db"


def init_db():
    conn = sqlite3.connect(DB_PATH)
    conn.execute("""
        CREATE TABLE IF NOT EXISTS subscriptions (
            token        TEXT PRIMARY KEY,
            client_email TEXT UNIQUE NOT NULL,
            created_at   TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            active       INTEGER DEFAULT 1
        )
    """)
    conn.commit()
    conn.close()


@asynccontextmanager
async def lifespan(app: FastAPI):
    init_db()
    logger.info("Subscription service started. SERVER_DOMAIN=%s", SERVER_DOMAIN)
    yield


app = FastAPI(
    lifespan=lifespan,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


# ── 3x-ui helpers ─────────────────────────────────────────────────────────────

async def xui_login() -> dict:
    async with httpx.AsyncClient() as client:
        resp = await client.post(
            f"{XUI_URL}/login",
            data={"username": XUI_USERNAME, "password": XUI_PASSWORD},
            timeout=10,
        )
    if resp.status_code != 200 or not resp.json().get("success"):
        logger.error("3x-ui login failed: %s", resp.text)
        raise HTTPException(503, "3x-ui authentication failed")
    return dict(resp.cookies)


async def fetch_inbounds(cookies: dict) -> list:
    async with httpx.AsyncClient() as client:
        resp = await client.get(
            f"{XUI_URL}/xui/API/inbounds",
            cookies=cookies,
            timeout=10,
        )
    if resp.status_code != 200:
        raise HTTPException(503, "Failed to fetch inbounds")
    data = resp.json()
    if not data.get("success"):
        raise HTTPException(503, "3x-ui API error")
    return data.get("obj", [])


def build_vless_link(
    inbound: dict, client_email: str, server_addr: str
) -> Optional[str]:
    try:
        settings = json.loads(inbound.get("settings", "{}"))
        stream = json.loads(inbound.get("streamSettings", "{}"))
    except (json.JSONDecodeError, TypeError):
        return None

    client_cfg = next(
        (c for c in settings.get("clients", []) if c.get("email") == client_email),
        None,
    )
    if not client_cfg:
        return None

    uuid = client_cfg.get("id", "")
    port = inbound.get("port", 443)
    security = stream.get("security", "")

    if security != "reality":
        return None

    reality = stream.get("realitySettings", {})
    public_key = reality.get("publicKey", "")
    short_ids = reality.get("shortIds", [""])
    short_id = short_ids[0] if short_ids else ""
    server_names = reality.get("serverNames", ["apple.com"])
    sni = server_names[0] if server_names else "apple.com"
    flow = client_cfg.get("flow", "xtls-rprx-vision")
    remark = client_email.replace(" ", "+")

    return (
        f"vless://{uuid}@{server_addr}:{port}"
        f"?encryption=none&flow={flow}&security=reality"
        f"&sni={sni}&fp=chrome&pbk={public_key}"
        f"&sid={short_id}&type=tcp&headerType=none#{remark}"
    )


async def get_user_links(client_email: str) -> list[str]:
    cookies = await xui_login()
    inbounds = await fetch_inbounds(cookies)
    links = []
    for inbound in inbounds:
        if inbound.get("protocol") != "vless":
            continue
        link = build_vless_link(inbound, client_email, SERVER_DOMAIN)
        if link:
            links.append(link)
    return links


# ── Auth ──────────────────────────────────────────────────────────────────────

def require_admin(x_admin_token: str = Header(None)):
    if not ADMIN_TOKEN or x_admin_token != ADMIN_TOKEN:
        raise HTTPException(403, "Forbidden")


# ── Public endpoints ──────────────────────────────────────────────────────────

@app.get("/sub/{token}")
async def get_subscription(token: str):
    """Return base64-encoded VLESS subscription for the given token."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT client_email FROM subscriptions WHERE token = ? AND active = 1",
        (token,),
    )
    row = cursor.fetchone()
    conn.close()

    if not row:
        raise HTTPException(404, "Not found")

    links = await get_user_links(row[0])
    if not links:
        raise HTTPException(404, "No active configurations")

    content = base64.b64encode("\n".join(links).encode()).decode()
    return Response(
        content=content,
        media_type="text/plain",
        headers={"subscription-userinfo": "upload=0; download=0; total=0; expire=0"},
    )


@app.get("/health")
async def health():
    return {"status": "ok"}


# ── Admin endpoints (internal, not exposed via nginx) ─────────────────────────

@app.post("/admin/users", dependencies=[Depends(require_admin)])
async def create_subscription(body: dict):
    """Register a subscription token for a 3x-ui client email."""
    email = body.get("email", "").strip()
    if not email:
        raise HTTPException(400, "email is required")

    token = secrets.token_urlsafe(24)
    conn = sqlite3.connect(DB_PATH)
    try:
        conn.execute(
            "INSERT INTO subscriptions (token, client_email) VALUES (?, ?)",
            (token, email),
        )
        conn.commit()
    except sqlite3.IntegrityError:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT token FROM subscriptions WHERE client_email = ?", (email,)
        )
        row = cursor.fetchone()
        conn.close()
        return {"token": row[0], "email": email, "already_exists": True,
                "sub_url": f"http://{SERVER_DOMAIN}/sub/{row[0]}"}
    conn.close()
    return {
        "token": token,
        "email": email,
        "sub_url": f"http://{SERVER_DOMAIN}/sub/{token}",
    }


@app.delete("/admin/users/{email}", dependencies=[Depends(require_admin)])
async def deactivate_user(email: str):
    """Deactivate a subscription (user loses access immediately)."""
    conn = sqlite3.connect(DB_PATH)
    conn.execute(
        "UPDATE subscriptions SET active = 0 WHERE client_email = ?", (email,)
    )
    conn.commit()
    conn.close()
    return {"status": "deactivated", "email": email}


@app.get("/admin/users", dependencies=[Depends(require_admin)])
async def list_users():
    """List all registered subscriptions."""
    conn = sqlite3.connect(DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT token, client_email, created_at, active FROM subscriptions"
        " ORDER BY created_at DESC"
    )
    rows = cursor.fetchall()
    conn.close()
    return [
        {
            "token": r[0],
            "email": r[1],
            "created_at": r[2],
            "active": bool(r[3]),
            "sub_url": f"http://{SERVER_DOMAIN}/sub/{r[0]}",
        }
        for r in rows
    ]
