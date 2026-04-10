"""
FastAPI Proxy/Gateway
Ports 8010 → 8001 ile şeffaf proxy + Langfuse loglama
"""

import asyncio
import json
import time
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Optional

import httpx
from fastapi import FastAPI, Request, Response
from fastapi.responses import StreamingResponse

# ──────────────────────────────────────────────
# Langfuse istemcisi (lightweight, SDK'sız)
# ──────────────────────────────────────────────


class LangfuseLogger:
    """Langfuse REST API ile minimum bağımlılıkla loglama."""

    def __init__(
        self,
        public_key: str,
        secret_key: str,
        host: str = "https://cloud.langfuse.com",
    ):
        self.host = host.rstrip("/")
        self.auth = (public_key, secret_key)
        self._client: Optional[httpx.AsyncClient] = None

    async def start(self):
        self._client = httpx.AsyncClient(
            auth=self.auth,
            timeout=10.0,
            headers={"Content-Type": "application/json"},
        )

    async def stop(self):
        if self._client:
            await self._client.aclose()

    async def log_request(
        self,
        *,
        trace_id: str,
        method: str,
        path: str,
        request_body: bytes,
        response_body: bytes,
        status_code: int,
        duration_ms: float,
        request_headers: dict,
    ):
        """Bir proxy isteğini Langfuse'a generation olarak gönder."""
        if not self._client:
            return

        # İstek gövdesini parse et (OpenAI formatı varsayımı)
        req_json: dict = {}
        try:
            req_json = json.loads(request_body) if request_body else {}
        except Exception:
            req_json = {"raw": request_body.decode(errors="replace")[:2000]}

        res_json: dict = {}
        try:
            res_json = json.loads(response_body) if response_body else {}
        except Exception:
            res_json = {"raw": response_body.decode(errors="replace")[:2000]}

        # Model bilgisini çıkar
        model = req_json.get("model", "unknown")
        messages = req_json.get("messages", [])

        # Kullanım istatistikleri
        usage = res_json.get("usage", {})

        payload = {
            "batch": [
                {
                    "id": str(uuid.uuid4()),
                    "type": "generation",
                    "timestamp": datetime.utcnow().isoformat() + "Z",
                    "body": {
                        "traceId": trace_id,
                        "name": f"{method} {path}",
                        "model": model,
                        "input": messages or req_json,
                        "output": res_json.get("choices", res_json),
                        "startTime": datetime.utcnow().isoformat() + "Z",
                        "metadata": {
                            "method": method,
                            "path": path,
                            "status_code": status_code,
                            "duration_ms": round(duration_ms, 2),
                            "proxy_port": 8010,
                            "target_port": 8001,
                        },
                        "usage": {
                            "input": usage.get("prompt_tokens"),
                            "output": usage.get("completion_tokens"),
                            "total": usage.get("total_tokens"),
                        },
                    },
                }
            ]
        }

        try:
            resp = await self._client.post(
                f"{self.host}/api/public/ingestion", json=payload
            )
            resp.raise_for_status()
        except Exception as e:
            print(f"[Langfuse] Log gönderilemedi: {e}")


# ──────────────────────────────────────────────
# Uygulama fabrikası
# ──────────────────────────────────────────────


def create_app(
    target_url: str = "http://localhost:8001",
    langfuse_public_key: str = "",
    langfuse_secret_key: str = "",
    langfuse_host: str = "https://cloud.langfuse.com",
    verbose: bool = False,
) -> FastAPI:
    logger = (
        LangfuseLogger(
            public_key=langfuse_public_key,
            secret_key=langfuse_secret_key,
            host=langfuse_host,
        )
        if langfuse_public_key and langfuse_secret_key
        else None
    )

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if logger:
            await logger.start()
            print(f"[Gateway] Langfuse loglama aktif → {langfuse_host}")
        async with httpx.AsyncClient(
            base_url=target_url,
            timeout=httpx.Timeout(60.0, connect=10.0),
            follow_redirects=True,
            limits=httpx.Limits(max_keepalive_connections=100, max_connections=200),
        ) as client:
            app.state.http_client = client
            print(f"[Gateway] Proxy başlatıldı  :8010 → {target_url}")
            yield
        if logger:
            await logger.stop()

    app = FastAPI(lifespan=lifespan, title="Proxy Gateway")

    @app.api_route(
        "/{path:path}",
        methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS", "HEAD"],
    )
    async def proxy(request: Request, path: str):
        client: httpx.AsyncClient = request.app.state.http_client
        trace_id = str(uuid.uuid4())
        start = time.monotonic()

        # İstek gövdesini oku
        body = await request.body()

        # Hedef URL
        url = httpx.URL(
            path=f"/{path}",
            query=request.url.query.encode("utf-8"),
        )

        # Başlıkları aktar (host hariç)
        headers = {
            k: v
            for k, v in request.headers.items()
            if k.lower() not in ("host", "content-length")
        }
        headers["x-proxy-trace-id"] = trace_id

        if verbose:
            print(f"[{trace_id[:8]}] {request.method} /{path}")

        # Streaming mi?
        is_stream = _is_streaming_request(body)

        if is_stream:
            return await _handle_streaming(
                client,
                request,
                url,
                headers,
                body,
                trace_id,
                start,
                path,
                logger,
                verbose,
            )

        # Normal (buffered) proxy
        try:
            resp = await client.request(
                method=request.method,
                url=url,
                headers=headers,
                content=body,
            )
        except httpx.ConnectError as e:
            return Response(
                content=json.dumps({"error": f"Upstream bağlantı hatası: {e}"}),
                status_code=502,
                media_type="application/json",
            )

        duration_ms = (time.monotonic() - start) * 1000
        resp_body = resp.content

        if verbose:
            print(f"[{trace_id[:8]}] ← {resp.status_code}  {duration_ms:.0f}ms")

        # Langfuse'a gönder (arka planda)
        if logger:
            asyncio.create_task(
                logger.log_request(
                    trace_id=trace_id,
                    method=request.method,
                    path=f"/{path}",
                    request_body=body,
                    response_body=resp_body,
                    status_code=resp.status_code,
                    duration_ms=duration_ms,
                    request_headers=dict(request.headers),
                )
            )

        # Yanıt başlıklarını temizle
        resp_headers = {
            k: v
            for k, v in resp.headers.items()
            if k.lower()
            not in ("content-encoding", "transfer-encoding", "content-length")
        }

        return Response(
            content=resp_body,
            status_code=resp.status_code,
            headers=resp_headers,
            media_type=resp.headers.get("content-type"),
        )

    return app


def _is_streaming_request(body: bytes) -> bool:
    try:
        return json.loads(body).get("stream", False) is True
    except Exception:
        return False


async def _handle_streaming(
    client, request, url, headers, body, trace_id, start, path, logger, verbose
):
    """SSE/streaming yanıtları chunk-by-chunk ilet, sonunda logla."""

    chunks: list[bytes] = []

    async def generate():
        async with client.stream(
            method=request.method,
            url=url,
            headers=headers,
            content=body,
        ) as resp:
            async for chunk in resp.aiter_bytes():
                chunks.append(chunk)
                yield chunk

        duration_ms = (time.monotonic() - start) * 1000
        if verbose:
            print(f"[{trace_id[:8]}] ← stream done  {duration_ms:.0f}ms")

        if logger:
            asyncio.create_task(
                logger.log_request(
                    trace_id=trace_id,
                    method=request.method,
                    path=f"/{path}",
                    request_body=body,
                    response_body=b"".join(chunks),
                    status_code=200,
                    duration_ms=duration_ms,
                    request_headers=dict(request.headers),
                )
            )

    return StreamingResponse(generate(), media_type="text/event-stream")
