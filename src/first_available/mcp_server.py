"""The Netomi agent's only way into AlloyDB: an MCP server with three tools.

Run it with:  python -m first_available.mcp_server
It listens on 127.0.0.1:MCP_PORT at /mcp and is published to Netomi through ngrok.

The leash:
  * There is no SQL tool. Each tool calls one database function with bound parameters.
  * The server connects as mcp_search, which may EXECUTE only those three functions.
  * Every request must carry "Authorization: Bearer <MCP_AUTH_TOKEN>".
"""

import json
import os
import secrets
import sys
import time
from typing import Any

from dotenv import load_dotenv
from mcp.server import MCPServer
from mcp.server.auth.provider import AccessToken, TokenVerifier
from mcp.server.auth.settings import AuthSettings
from mcp.server.transport_security import TransportSecuritySettings
from pydantic import AnyHttpUrl

from first_available.db import MCP_DB_USER, get_connection

load_dotenv()
PORT = int(os.environ["MCP_PORT"])
PUBLIC_HOST = os.environ["NGROK_DOMAIN"]   # e.g. something.ngrok-free.app
AUTH_TOKEN = os.environ["MCP_AUTH_TOKEN"]


# The SDK's documented way to check a bearer token is a small TokenVerifier
# subclass. This is the one class in the repo (an agreed exception).
class StaticTokenVerifier(TokenVerifier):  # pylint: disable=too-few-public-methods
    """Accept exactly one token: MCP_AUTH_TOKEN from .env."""

    async def verify_token(self, token):
        if secrets.compare_digest(token, AUTH_TOKEN):
            return AccessToken(token=token, client_id="netomi", scopes=[])
        return None


mcp = MCPServer(
    "Summit Home Services",
    instructions="Search technicians and replacement parts, and book technician visits.",
    token_verifier=StaticTokenVerifier(),
    auth=AuthSettings(
        # Required by the SDK. There is no OAuth server here; the token is static.
        issuer_url=AnyHttpUrl(f"https://{PUBLIC_HOST}"),
        resource_server_url=AnyHttpUrl(f"https://{PUBLIC_HOST}/mcp"),
    ),
)


def log(message):
    """One line on stderr, which the notebook sends to mcp_server.log."""
    print(f"{time.strftime('%H:%M:%S')} {message}", file=sys.stderr, flush=True)


def call_function(sql, params):
    """Run one SELECT of a database function as the MCP user and return its JSON.

    Each call is logged with its arguments and its result (or error), so the log
    shows exactly what the agent asked for and what it got back.
    """
    name = sql.removeprefix("SELECT ").split("(")[0]
    log(f"tool call: {name}{params!r}")
    try:
        conn = get_connection(MCP_DB_USER, os.environ["MCP_DB_PASSWORD"])
        try:
            cursor = conn.cursor()
            cursor.execute(sql, params)
            result = cursor.fetchone()[0]
        finally:
            conn.close()
    except Exception as error:
        log(f"  failed: {error!r}")
        raise
    log(f"  result: {json.dumps(result)}")
    return result


@mcp.tool()
def search_technicians(zip_code: str, brand: str, issue: str) -> dict[str, Any]:
    """Find technicians who can visit: they serve the ZIP code, are certified for the
    brand, and have open times. Use it as soon as you have the customer's ZIP code,
    brand, and issue. You book visits yourself with book_slot.

    Arguments:
    - zip_code: the customer's ZIP code.
    - brand: exactly Northfield, Kestrel, or Aspenware (the only brands serviced).
    - issue: the problem in the customer's own words, including any error code.

    Returns {"technicians": [...], "next_step": "..."}. Each technician has a rank
    (1 = best match for the problem), name, city, rating, and up to 3 open times.

    Always do what next_step says.
    """
    return call_function("SELECT search_technicians(%s, %s, %s)", (zip_code, brand, issue))


@mcp.tool()
def search_parts(query: str, brand: str | None = None) -> dict[str, Any]:
    """Search replacement parts. Use it when the customer asks which part they need,
    whether a part is in stock, or what it costs.

    Arguments:
    - query: whatever the customer gave you: a part number, a model number, a
      description in their own words, or a mix (for example "KS-PMP-410",
      "KD-412 door seal", or "the rubber strip around the door is torn").
    - brand: optional. Exactly Northfield, Kestrel, or Aspenware, if you know it.
      Leave it out if you don't.

    Returns {"parts": [...]}: up to 5, best match first, each with part_number, name,
    brand, fits_models (the model numbers the part fits), price, and in_stock.

    Using the result:
    - The results are the closest matches, not guaranteed matches. Before presenting
      a part, check that its name, brand and fits_models correspond to what the
      customer asked for.
    - For a part that matches, share the part number, name, price, and whether it's
      in stock.
    - If the customer gave a model number, use fits_models to confirm the part fits,
      and say so if it doesn't.
    - If several parts could fit, ask a short clarifying question.
    - If the list is empty or nothing in it matches, say you couldn't find the part
      and ask for the model number or part number if you don't have it yet.
    - If the call fails with an error, the search did not run. Don't guess at part
      numbers, prices or stock; tell the customer you can't look this up right now.
    """
    return call_function("SELECT search_parts(%s, %s)", (query, brand))


@mcp.tool()
def book_slot(technician: str, time: str, zip_code: str, brand: str,
              customer_name: str, issue: str) -> dict[str, Any]:
    """Book a visit as soon as the customer picks a technician and a time.

    Arguments:
    - technician: the name of the technician the customer picked.
    - time: the date and time the customer picked, as search_technicians showed it
      (for example "Fri Nov 13, 9:00 AM").
    - zip_code, brand, issue: the same ones you gave search_technicians.
    - customer_name: the customer's name.

    Returns {"booked": true, "technician", "time", "next_step"}, or, when that time
    can't be booked, {"booked": false, "reason", "open_times", "next_step"}. "booked":
    false is not an error: offer the open_times, and when the customer picks one, call
    book_slot again. Tell the customer a visit is booked only after "booked": true.
    Calling it again for the same visit is safe: it confirms the booking again.

    Always do what next_step says.

    This tool only creates bookings. Changing or cancelling one needs a human agent.
    """
    return call_function("SELECT book_slot(%s, %s, %s, %s, %s, %s)",
                         (technician, time, zip_code, brand, customer_name, issue))


def main():
    """Serve the tools over Streamable HTTP at http://127.0.0.1:MCP_PORT/mcp."""
    mcp.run(
        transport="streamable-http",
        host="127.0.0.1",
        port=PORT,
        # No sessions: each tool call is one database query, and a server restart
        # can't leave Netomi holding a session ID the server no longer knows.
        stateless_http=True,
        # Requests arrive through ngrok with the public host name in the Host header.
        transport_security=TransportSecuritySettings(
            allowed_hosts=[f"127.0.0.1:{PORT}", f"localhost:{PORT}", PUBLIC_HOST],
            allowed_origins=[],
        ),
    )


if __name__ == "__main__":
    main()
