"""Money Ledger — thin config server.

DESIGN CONSTRAINT, load-bearing, do not violate:
    This server knows NOTHING about any user.

It serves three static, versioned JSON documents to the Android app:
    * categories     — the category taxonomy
    * merchants      — merchant/VPA -> category dictionary
    * parser-rules   — declarative bank-SMS parsing templates

There are deliberately NO write endpoints, NO auth, NO database and NO logging
of request bodies. Transactions, SMS text, account numbers and merchant strings
never leave the user's phone. That is the app's core privacy claim, it is what
makes the Google Play SMS permission declaration defensible, and it is only true
for as long as this file stays read-only.

If you are about to add a POST endpoint here, stop and re-read the above.
"""

from __future__ import annotations

import hashlib
import json
import logging
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Response
from fastapi.responses import JSONResponse

logger = logging.getLogger("ledger.config")

# rules/ lives at the repo root and is the single source of truth, shared by
# this server and by the app's bundled offline copy. Railway's service root
# must therefore be the repo root, not server/.
REPO_ROOT = Path(__file__).resolve().parent.parent
RULES_DIR = REPO_ROOT / "rules"

DOCUMENTS = {
    "categories": "categories.json",
    "merchants": "merchants.json",
    "parser-rules": "parser_rules.json",
}

# name -> {"payload": dict, "etag": str, "version": int}
_cache: dict[str, dict[str, Any]] = {}


@asynccontextmanager
async def lifespan(_: FastAPI):
    load_all()
    missing = [n for n in DOCUMENTS if n not in _cache]
    if missing:
        logger.error("startup with missing documents: %s", ", ".join(missing))
    yield


app = FastAPI(
    title="Money Ledger Config",
    description="Read-only parser rules and merchant dictionary. Stores no user data.",
    version="0.1.0",
    docs_url="/docs",
    lifespan=lifespan,
)


def _load(name: str, filename: str) -> dict[str, Any]:
    path = RULES_DIR / filename
    raw = path.read_bytes()
    payload = json.loads(raw)

    # Content hash is the ETag, so a redeploy that changes nothing does not
    # force every client to re-download.
    etag = hashlib.sha256(raw).hexdigest()[:16]

    version = payload.get("version")
    if not isinstance(version, int):
        raise ValueError(f"{filename} must carry an integer top-level 'version'")

    return {"payload": payload, "etag": etag, "version": version}


def load_all() -> None:
    for name, filename in DOCUMENTS.items():
        try:
            _cache[name] = _load(name, filename)
            logger.info("loaded %s v%s", name, _cache[name]["version"])
        except FileNotFoundError:
            logger.error("missing rules file: %s", filename)
        except (ValueError, json.JSONDecodeError) as exc:
            # Refuse to serve a malformed document rather than shipping garbage
            # rules to every installed app.
            logger.error("invalid rules file %s: %s", filename, exc)


@app.get("/health", include_in_schema=False)
def health() -> dict[str, Any]:
    """Railway healthcheck. Degraded (not failed) if a document is unreadable."""
    return {
        "status": "ok" if len(_cache) == len(DOCUMENTS) else "degraded",
        "documents": {n: _cache[n]["version"] for n in sorted(_cache)},
    }


@app.get("/v1/manifest")
def manifest() -> dict[str, Any]:
    """One cheap call the app makes on launch to decide what to re-fetch.

    The app compares these versions against its bundled/cached copies and pulls
    only what actually moved, so a normal launch costs a single small response.
    """
    return {
        "documents": {
            name: {
                "version": entry["version"],
                "etag": entry["etag"],
                "url": f"/v1/{name}",
            }
            for name, entry in _cache.items()
        }
    }


def _serve(name: str, if_none_match: str | None) -> Response:
    entry = _cache.get(name)
    if entry is None:
        raise HTTPException(status_code=503, detail=f"{name} unavailable")

    etag = f'"{entry["etag"]}"'
    if if_none_match and if_none_match.strip() == etag:
        return Response(status_code=304, headers={"ETag": etag})

    return JSONResponse(
        content=entry["payload"],
        headers={
            "ETag": etag,
            # Long max-age is safe: the manifest drives updates, and the ETag
            # changes whenever content does.
            "Cache-Control": "public, max-age=3600",
        },
    )


@app.get("/v1/categories")
def categories(if_none_match: str | None = Header(default=None)) -> Response:
    return _serve("categories", if_none_match)


@app.get("/v1/merchants")
def merchants(if_none_match: str | None = Header(default=None)) -> Response:
    return _serve("merchants", if_none_match)


@app.get("/v1/parser-rules")
def parser_rules(if_none_match: str | None = Header(default=None)) -> Response:
    return _serve("parser-rules", if_none_match)
