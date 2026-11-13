"""Prove the database layer of the leash: what the MCP server's user can and can't do."""

import os

import pandas as pd
from pg8000.dbapi import DatabaseError

from first_available.db import MCP_DB_USER, get_connection, query

# (what the statement tries to do, the SQL, the expected result)
CHECKS = [
    ("call a tool function", "SELECT search_parts('drain pump')", "allowed"),
    ("read a table", "SELECT count(*) FROM bookings", "denied"),
    ("delete bookings", "DELETE FROM bookings", "denied"),
    ("change slots", "UPDATE slots SET status = 'open'", "denied"),
    ("create a table", "CREATE TABLE stolen (x int)", "denied"),
    ("call a search helper", "SELECT * FROM parts_keyword_ranks('pump', NULL)", "denied"),
]

ROLE_MEMBERSHIPS_SQL = """
    SELECT r.rolname
    FROM pg_auth_members m
    JOIN pg_roles r ON r.oid = m.roleid
    WHERE m.member = %s::regrole
"""


def attempt(conn, sql):
    """Run one statement and report whether the database allowed it."""
    try:
        conn.cursor().execute(sql)
        return "allowed"
    except DatabaseError:
        return "denied"


def leash_report(admin_conn):
    """One table: mcp_search's role memberships, then each check run as mcp_search."""
    roles = query(admin_conn, ROLE_MEMBERSHIPS_SQL, (MCP_DB_USER,))["rolname"].tolist()
    rows = [("role memberships", "", "none", ", ".join(roles) or "none")]
    mcp_conn = get_connection(MCP_DB_USER, os.environ["MCP_DB_PASSWORD"])
    try:
        for action, sql, expected in CHECKS:
            rows.append((action, sql, expected, attempt(mcp_conn, sql)))
    finally:
        mcp_conn.close()
    report = pd.DataFrame(rows, columns=["as mcp_search, try to…", "SQL", "expected", "result"])
    report["ok"] = report["expected"] == report["result"]
    return report
