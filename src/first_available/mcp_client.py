"""Run the local MCP server and talk to it the way Netomi does: HTTPS plus a bearer token.

The MCP SDK client is async, so list_tools() and call_tool() are awaited in the
notebook (`await list_tools(...)`). This file is the agreed exception to "no async".
"""

import os
import socket
import subprocess
import sys
import time

import httpx2
import requests
from dotenv import load_dotenv
from mcp import Client
from mcp.client.streamable_http import streamable_http_client

load_dotenv()


def port_in_use(port):
    """True if something on this machine is already listening on the port."""
    with socket.socket() as probe:
        return probe.connect_ex(("127.0.0.1", int(port))) == 0


def start_server(log_path="mcp_server.log"):
    """Start the MCP server in the background, unless it's already running."""
    if port_in_use(os.environ["MCP_PORT"]):
        print("MCP server already running.")
        return
    with open(log_path, "a", encoding="utf-8") as log:
        # Not a with-block: the server keeps running until Section 12 stops it.
        subprocess.Popen(  # pylint: disable=consider-using-with
            [sys.executable, "-m", "first_available.mcp_server"],
            stdout=subprocess.DEVNULL, stderr=log,
            # Its own session: interrupting a notebook cell signals the kernel's whole
            # process group, which would otherwise stop the server mid-conversation.
            start_new_session=True)
    time.sleep(3)
    if not port_in_use(os.environ["MCP_PORT"]):
        raise RuntimeError(f"The MCP server didn't start; see {log_path}")
    print(f"MCP server running on port {os.environ['MCP_PORT']} (log: {log_path}).")


def ngrok_url():
    """The public HTTPS URL of the running ngrok tunnel, read from ngrok's local API."""
    endpoints = requests.get("http://127.0.0.1:4040/api/endpoints", timeout=5).json()["endpoints"]
    return endpoints[0]["url"]


def start_tunnel():
    """Publish the MCP server at https://NGROK_DOMAIN, unless ngrok is already running.
    Returns the MCP URL to give Netomi."""
    if not port_in_use(4040):  # 4040 is ngrok's local API
        # Not a with-block: ngrok keeps running until Section 12 stops it.
        subprocess.Popen(  # pylint: disable=consider-using-with
            # ngrok uses the authtoken saved by `ngrok config add-authtoken`.
            ["ngrok", "http", os.environ["MCP_PORT"],
             "--url", f"https://{os.environ['NGROK_DOMAIN']}"],
            stdout=subprocess.DEVNULL, start_new_session=True)  # survives a cell interrupt
        time.sleep(3)
    return f"{ngrok_url()}/mcp"


def status_without_token(mcp_url):
    """What the server answers a tools/list request with no bearer token: should be 401."""
    response = requests.post(mcp_url, json={"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
                             headers={"Accept": "application/json, text/event-stream"}, timeout=30)
    return f"{response.status_code} {response.reason}"


def http_client(token):
    """An HTTP client that sends the bearer token on every request."""
    return httpx2.AsyncClient(
        headers={"Authorization": f"Bearer {token}"},
        timeout=httpx2.Timeout(30.0, read=120.0),
    )


async def list_tools(mcp_url, token):
    """Names of the tools the MCP server exposes."""
    async with http_client(token) as http:
        async with Client(streamable_http_client(mcp_url, http_client=http)) as client:
            result = await client.list_tools()
    return [tool.name for tool in result.tools]


async def call_tool(mcp_url, token, name, arguments):
    """Call one tool and return its result as a dict."""
    async with http_client(token) as http:
        async with Client(streamable_http_client(mcp_url, http_client=http)) as client:
            result = await client.call_tool(name, arguments)
    return result.structured_content
