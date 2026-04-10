import httpx
from fastapi import FastAPI, Request
from fastapi.responses import Response, StreamingResponse

app = FastAPI()

BASE_HELICONE_URL = "https://gateway.helicone.ai"
OPENROUTER_API_KEY = "sk-or-v1-..."
HELICONE_API_KEY = "sk-helicone-..."
TARGET_URL = "https://000d-213-74-41-126.ngrok-free.app/"

TIMEOUT = httpx.Timeout(connect=30.0, read=None, write=30.0, pool=None)


def build_upstream_headers(request: Request) -> dict:
    headers = {
        "Authorization": f"Bearer {OPENROUTER_API_KEY}",
        "Helicone-Auth": f"Bearer {HELICONE_API_KEY}",
        "Helicone-Target-Url": TARGET_URL,
    }

    # Bazı header'ları aynen geçirmek yararlı olur
    passthrough = [
        "content-type",
        "accept",
        "anthropic-version",
        "x-api-key",
        "user-agent",
    ]

    for name in passthrough:
        value = request.headers.get(name)
        if value:
            headers[name] = value

    # Host/content-length gibi problem çıkarabilecek header'ları kopyalamıyoruz
    headers.pop("host", None)
    headers.pop("content-length", None)

    return headers


@app.api_route(
    "/{full_path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
)
async def proxy(full_path: str, request: Request):
    body = await request.body()
    upstream_url = f"{BASE_HELICONE_URL}/{full_path}"

    headers = build_upstream_headers(request)
    params = list(request.query_params.multi_items())

    client = httpx.AsyncClient(timeout=TIMEOUT)

    try:
        upstream_req = client.build_request(
            method=request.method,
            url=upstream_url,
            headers=headers,
            params=params,
            content=body,
        )

        upstream_resp = await client.send(upstream_req, stream=True)
    except Exception as e:
        await client.aclose()
        return Response(
            content=f'{{"error":"upstream_connection_failed","detail":"{str(e)}"}}',
            status_code=502,
            media_type="application/json",
        )

    content_type = upstream_resp.headers.get("content-type", "")
    is_streaming = (
        "text/event-stream" in content_type
        or request.headers.get("accept", "").lower() == "text/event-stream"
    )

    response_headers = {}
    for h in [
        "content-type",
        "cache-control",
        "connection",
        "x-request-id",
        "anthropic-request-id",
    ]:
        v = upstream_resp.headers.get(h)
        if v:
            response_headers[h] = v

    if is_streaming:

        async def stream_generator():
            try:
                async for chunk in upstream_resp.aiter_raw():
                    if chunk:
                        yield chunk
            finally:
                await upstream_resp.aclose()
                await client.aclose()

        return StreamingResponse(
            stream_generator(),
            status_code=upstream_resp.status_code,
            headers=response_headers,
            media_type=upstream_resp.headers.get("content-type", "text/event-stream"),
        )

    try:
        content = await upstream_resp.aread()
        return Response(
            content=content,
            status_code=upstream_resp.status_code,
            headers=response_headers,
            media_type=upstream_resp.headers.get("content-type"),
        )
    finally:
        await upstream_resp.aclose()
        await client.aclose()
