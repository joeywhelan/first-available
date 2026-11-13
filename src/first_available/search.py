"""Notebook helpers for showing AlloyDB search results as small tables."""

import pandas as pd

from first_available.db import query

TOP = 3  # rows shown per column, so the tables fit the notebook output

# One search leg (BM25 or ScaNN) for parts, best match first.
LEG_SQL = """
    SELECT p.part_number || '  ' || p.name AS part
    FROM {leg}(%s, %s) r
    JOIN parts p ON p.id = r.item_id
    ORDER BY r.item_rank, p.id
    LIMIT %s
"""

# The hybrid search_parts() result, in order (the agent gets 5; we show the top few).
HYBRID_SQL = """
    SELECT x.part ->> 'part_number' || '  ' || (x.part ->> 'name') AS part
    FROM jsonb_array_elements(search_parts(%s, %s) -> 'parts') WITH ORDINALITY AS x (part, n)
    ORDER BY x.n
    LIMIT %s
"""


def compare_search(conn, text, brand=None):
    """Top 3 parts for one query: BM25 only, ScaNN only, and hybrid (what the agent gets)."""
    params = (text, brand, TOP)
    keyword = query(conn, LEG_SQL.format(leg="parts_keyword_ranks"), params)["part"]
    vector = query(conn, LEG_SQL.format(leg="parts_vector_ranks"), params)["part"]
    hybrid = query(conn, HYBRID_SQL, params)["part"]
    table = pd.DataFrame(
        {"BM25 (keyword)": keyword, "ScaNN (vector)": vector, "Hybrid (agent)": hybrid}
    )
    table.insert(0, "rank", range(1, len(table) + 1))
    return table.fillna("")


def technicians_for(conn, zip_code, brand, issue):
    """Run search_technicians() as admin and show the result as a table."""
    result = query(conn, "SELECT search_technicians(%s, %s, %s) AS r", (zip_code, brand, issue))
    return technicians_table(result.loc[0, "r"])


def technicians_table(result):
    """Turn a search_technicians() result into one row per technician."""
    rows = [
        {
            "technician": t["technician"],
            "city": t["city"],
            "rating": t["rating"],
            "open times": ", ".join(t["times"]),
        }
        for t in result["technicians"]
    ]
    return pd.DataFrame(rows, columns=["technician", "city", "rating", "open times"])
