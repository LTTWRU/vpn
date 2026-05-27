import os
import json
import base64
import secrets
import sqlite3
import logging
from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException, Header, Depends
from fastapi.responses import Response

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

SERVER_DOMAIN = os.getenv("SERVER_DOMAIN", "")
ADMIN_TOKEN   = os.getenv("ADMIN_TOKEN", "")
SUB_DB_PATH   = "/app/data/subscriptions.db"
XUI_DB_PATH   = "/app/xui_db/x-ui.db"


def init_db():
    conn = sqlite3.connect(SUB_DB_PATH)
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


# ── 3x-ui SQLite reader ────────────────────────────────────────────────────────

def get_user_links(client_email: str) -> list[str]:
    """Build VLESS links by reading directly from 3x-ui SQLite."""
    try:
        conn = sqlite3.connect(XUI_DB_PATH)
        rows = conn.execute(
            "SELECT settings, stream_settings, port FROM inbounds"
            " WHERE enable=1 AND protocol='vless'"
        ).fetchall()
        conn.close()
    except Exception as e:
        logger.error("Failed to read x-ui.db: %s", e)
        return []

    links = []
    for settings_str, stream_str, port in rows:
        try:
            settings = json.loads(settings_str)
            stream   = json.loads(stream_str)
        except (json.JSONDecodeError, TypeError):
            continue

        client_cfg = next(
            (c for c in settings.get("clients", []) if c.get("email") == client_email),
            None,
        )
        if not client_cfg:
            continue

        if stream.get("security") != "reality":
            continue

        reality    = stream.get("realitySettings", {})
        public_key = reality.get("publicKey", "")
        short_ids  = reality.get("shortIds", [""])
        short_id   = short_ids[0] if short_ids else ""
        server_names = reality.get("serverNames", ["apple.com"])
        sni        = server_names[0] if server_names else "apple.com"
        uuid       = client_cfg.get("id", "")
        flow       = client_cfg.get("flow", "xtls-rprx-vision")
        remark     = client_email.replace(" ", "+")

        link = (
            f"vless://{uuid}@{SERVER_DOMAIN}:{port}"
            f"?encryption=none&flow={flow}&security=reality"
            f"&sni={sni}&fp=chrome&pbk={public_key}"
            f"&sid={short_id}&type=tcp&headerType=none#{remark}"
        )
        links.append(link)

    return links


# ── Auth ────────────────────────────────────────────────────────────────────────

def require_admin(x_admin_token: str = Header(None)):
    if not ADMIN_TOKEN or x_admin_token != ADMIN_TOKEN:
        raise HTTPException(403, "Forbidden")


# ── Public endpoints ────────────────────────────────────────────────────────────

@app.get("/sub/{token}")
async def get_subscription(token: str):
    """Return base64-encoded VLESS subscription for the given token."""
    conn = sqlite3.connect(SUB_DB_PATH)
    cursor = conn.cursor()
    cursor.execute(
        "SELECT client_email FROM subscriptions WHERE token = ? AND active = 1",
        (token,),
    )
    row = cursor.fetchone()
    conn.close()

    if not row:
        raise HTTPException(404, "Not found")

    links = get_user_links(row[0])
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


# ── Admin endpoints ───────────────────────────────────────────────────────────────

@app.post("/admin/users", dependencies=[Depends(require_admin)])
async def create_subscription(body: dict):
    """Register a subscription token for a 3x-ui client email."""
    email = body.get("email", "").strip()
    if not email:
        raise HTTPException(400, "email is required")

    token = secrets.token_urlsafe(24)
    conn = sqlite3.connect(SUB_DB_PATH)
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
                "sub_url": f"https://{SERVER_DOMAIN}/sub/{row[0]}"}
    conn.close()
    return {
        "token": token,
        "email": email,
        "sub_url": f"https://{SERVER_DOMAIN}/sub/{token}",
    }


@app.delete("/admin/users/{email}", dependencies=[Depends(require_admin)])
async def deactivate_user(email: str):
    """Deactivate a subscription."""
    conn = sqlite3.connect(SUB_DB_PATH)
    conn.execute(
        "UPDATE subscriptions SET active = 0 WHERE client_email = ?", (email,)
    )
    conn.commit()
    conn.close()
    return {"status": "deactivated", "email": email}


@app.get("/admin/users", dependencies=[Depends(require_admin)])
async def list_users():
    """List all registered subscriptions."""
    conn = sqlite3.connect(SUB_DB_PATH)
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
            "sub_url": f"https://{SERVER_DOMAIN}/sub/{r[0]}",
        }
        for r in rows
    ]
