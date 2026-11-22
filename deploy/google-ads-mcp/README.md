# Google Ads MCP server for Ada

Ada can run Google's official [Google Ads MCP server](https://github.com/googleads/google-ads-mcp)
next to herself in the Railway container and use its tools through her MCP client.

## Turning it on

1. Connect Google Ads in Ada (Settings → Connections), as before.
2. On the Railway service, set `AGENTSAM_GOOGLE_ADS_MCP=1` and redeploy.
3. The logs say `Google Ads MCP server is on: 6 tools at http://127.0.0.1:8765/mcp`, and
   Settings → Connections → MCP servers lists *Google Ads MCP*.

To turn it off, remove the variable (and remove the server from the MCP list if you like). Turning
the entry off in Settings also stops Ada using it, and that choice survives restarts.

## How it works

- `deploy/Dockerfile` installs the pinned `requirements.txt` into `/opt/google-ads-mcp`, a
  virtualenv apart from the `python3` Ada's programs use, plus `ada_launch.py` and
  `tools_config.yaml`.
- `GoogleAdsMCPRunner` (Server/Sources/AgentSamServer/GoogleAdsMCP.swift) writes an Application
  Default Credentials file from Ada's Google Ads connection into a private temp folder, starts
  `ada_launch.py` with only the variables it needs, waits for it to answer, and adds it to Ada's
  MCP servers by URL. The developer token and customer ID come from the same connection
  (`GOOGLE_ADS_DEVELOPER_TOKEN`, `GOOGLE_ADS_LOGIN_CUSTOMER_ID`).
- `ada_launch.py` serves the upstream server over Streamable HTTP on 127.0.0.1 only, without the
  upstream OAuth proxy, and refuses any request without Ada's bearer token. The token is new on
  every start, because programs Ada runs in this container can reach loopback too.
- The server's read tools (`search_search`, `metadata_get_resource_metadata`,
  `customers_list_accessible_customers`) are marked read-only and run at once. Asset and label
  changes go through Ada's approval cards, and the upstream server adds its own propose-and-confirm
  checksum step.
- `upload_video_asset` is off in `tools_config.yaml`: it uploads a file from this machine's disk.

Settings: `AGENTSAM_GOOGLE_ADS_MCP_PORT` (default 8765), `AGENTSAM_GOOGLE_ADS_MCP_HOME`
(default `/opt/google-ads-mcp`).

## Upgrading

In a clean Python 3.12 virtualenv: `pip install google-ads-mcp==NEW && pip freeze > requirements.txt`
(drop any `-e` line), then rebuild. Check `ada_launch.py` still starts: it uses
`ads_mcp.server.mcp` and FastMCP's `run(transport="streamable-http", middleware=...)`.
