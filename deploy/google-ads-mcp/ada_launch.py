"""Runs Google's Google Ads MCP server (github.com/googleads/google-ads-mcp) for Ada.

Ada's server starts this next to itself and connects to it as one of her MCP servers. It serves
Streamable HTTP on 127.0.0.1 only and signs in to Google Ads with the credentials file Ada writes
(GOOGLE_APPLICATION_CREDENTIALS), so the upstream OAuth proxy is not used. Every request must
carry Ada's per-start bearer token, because programs Ada runs in this container share loopback.
"""

import hmac
import os
import sys

from ads_mcp.server import mcp

TOKEN = os.environ.pop("ADA_MCP_TOKEN", "")
if len(TOKEN) < 32:
    sys.exit("ADA_MCP_TOKEN must be set to Ada's per-start token.")
EXPECTED = ("Bearer " + TOKEN).encode()


class RequireAdaToken:
    """Refuses HTTP requests without Ada's token, then drops the header so it never reaches Google."""

    def __init__(self, app):
        self.app = app

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            given = b""
            kept = []
            for key, value in scope["headers"]:
                if key == b"authorization":
                    given = value
                else:
                    kept.append((key, value))
            if not hmac.compare_digest(given, EXPECTED):
                await send({"type": "http.response.start", "status": 401, "headers": [(b"content-type", b"text/plain")]})
                await send({"type": "http.response.body", "body": b"Ada's token is required."})
                return
            scope = dict(scope, headers=kept)
        await self.app(scope, receive, send)


if __name__ == "__main__":
    from starlette.middleware import Middleware

    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=int(os.environ.get("PORT", "8765")),
        middleware=[Middleware(RequireAdaToken)],
        show_banner=False,
        uvicorn_config={"access_log": False},
    )
