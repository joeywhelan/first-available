"""Connections to the AlloyDB instance, plus small SQL helpers."""

import functools
import os
from pathlib import Path

import pandas as pd
from dotenv import load_dotenv
from google.cloud.alloydbconnector import Connector

load_dotenv()

# The MCP server's database user. Fixed, because assets/sql/mcp_grants.sql grants to it by name.
MCP_DB_USER = "mcp_search"

# The .env settings Terraform needs (terraform/variables.tf).
TERRAFORM_SETTINGS = ["GCP_PROJECT_ID", "GCP_REGION", "ALLOYDB_CLUSTER_ID", "ALLOYDB_INSTANCE_ID",
                      "DB_ADMIN_USER", "DB_ADMIN_PASSWORD", "MCP_DB_PASSWORD"]


def terraform_env():
    """Reload .env and hand Terraform its settings as TF_VAR_* environment variables.

    Terraform reads TF_VAR_<name> as the value of variable <name>. Nothing is printed,
    and the passwords are write-only, so they never reach Terraform's state.
    """
    load_dotenv(override=True)
    for name in TERRAFORM_SETTINGS:
        os.environ[f"TF_VAR_{name.lower()}"] = os.environ[name]


@functools.cache
def connector():
    """One shared AlloyDB connector, created on first use (it needs Google credentials)."""
    return Connector()


def instance_uri():
    """The AlloyDB instance path built from .env settings."""
    return (
        f"projects/{os.environ['GCP_PROJECT_ID']}"
        f"/locations/{os.environ['GCP_REGION']}"
        f"/clusters/{os.environ['ALLOYDB_CLUSTER_ID']}"
        f"/instances/{os.environ['ALLOYDB_INSTANCE_ID']}"
    )


def get_connection(user=None, password=None):
    """Connect over the instance's public IP; the admin user by default.

    The MCP server passes its own limited user, MCP_DB_USER.
    Autocommit is on, so every statement takes effect immediately and no cell
    is left inside an open transaction.
    """
    conn = connector().connect(
        instance_uri(),
        "pg8000",
        user=user or os.environ["DB_ADMIN_USER"],
        password=password or os.environ["DB_ADMIN_PASSWORD"],
        db=os.environ["DB_NAME"],
        ip_type="PUBLIC",
    )
    conn.autocommit = True
    return conn


def run_sql_file(conn, path):
    """Run every statement in a .sql file.

    The file is sent as one batch, which Postgres runs as a single transaction:
    if any statement fails, none of them take effect.
    """
    conn.cursor().execute(Path(path).read_text(encoding="utf-8"))


def print_table(table, title):
    """Print a one-line description, then a DataFrame as a Markdown table, ready to paste
    into an article."""
    print(f"{title}\n")
    print(table.to_markdown(index=False))
    print()


def query(conn, sql, params=()):
    """Run a query and return the rows as a pandas DataFrame."""
    cursor = conn.cursor()
    cursor.execute(sql, params)
    columns = [c[0] for c in cursor.description]
    return pd.DataFrame(cursor.fetchall(), columns=columns)
