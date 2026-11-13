-- Lock the MCP server's database user (mcp_search) down to the three tool functions.
-- Run after agent_functions.sql, and again whenever a function is added or changed:
-- new functions are executable by PUBLIC by default.
-- The user itself is created by Terraform (terraform/main.tf), so its password never
-- appears in SQL.

-- Tables and sequences need nothing here: Postgres never grants PUBLIC access to them.
-- Functions are different: Postgres lets everyone EXECUTE a new function by default.
REVOKE EXECUTE ON FUNCTION
    technician_keyword_ranks(text, text, text),
    technician_vector_ranks(text, text, text),
    parts_keyword_ranks(text, text),
    parts_vector_ranks(text, text),
    search_technicians(text, text, text),
    search_parts(text, text),
    book_slot(text, text, text, text, text, text)
FROM PUBLIC;

-- The MCP server may call exactly the three tools.
GRANT USAGE ON SCHEMA public TO mcp_search;
GRANT EXECUTE ON FUNCTION
    search_technicians(text, text, text),
    search_parts(text, text),
    book_slot(text, text, text, text, text, text)
TO mcp_search;

-- Cap any single call (embedding a query takes well under a second).
ALTER ROLE mcp_search SET statement_timeout = '15s';
