# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A Jupyter-notebook demo of the **Netomi virtual agent** doing appliance-repair support for a fictional company, "Summit Home Services". A simulated customer (Claude API, persona from a scenario file) talks to the agent through the **Netomi Headless Chat API**; the notebook prints each transcript and checks the database. The agent's live data is in **AlloyDB**, used as a **search engine** (BM25 + ScaNN hybrid), reached only through **our local MCP server** with three tools.

**The thesis (the title: "Rules in the Tools"):** business rules that must always hold live in the SQL functions behind the MCP tools (hard); the prompt and tool descriptions keep only judgement (soft). `assets/article.md` leads with it, and its Summary's "The rules in the tools" table lists every business rule and the function or privilege that enforces it; nothing that is a business rule is left to a docstring. Keep that table true when a tool or function changes.

- `assets/article.md` is the write-up: the narrative, the setup steps, the transcripts and the summary tables. The notebook itself is only headings and code.
- `assets/plan.md` is the design spec: goals, scenarios, notebook outline, and Chat API details. If it and the repo disagree, follow the repo and point out the mismatch.
- Package: `src/first_available`. Python 3.14 (`.python-version`).
- **Status:** Sections 1–12 run end to end on GCP, with all five conversations passing. Open items:
  - A multi-chunk Chat API reply hasn't been seen yet (`TODO: verify` in `netomi.py`).
  - Whether `NETOMI_INTEGRATION` should be `NETOMI_WEB_WIDGET` or `CHAT_API` (`TODO: verify` in `.env.sample`).

## Commands

```bash
uv sync                                                # install deps into .venv
uv add <pkg>                                           # add a dependency
uv run jupyter lab demo.ipynb                          # run the demo (or VS Code with the .venv kernel)
uv run python -m first_available.mcp_server            # the MCP server (Section 4 starts it)
terraform -chdir=terraform validate                    # check Terraform (apply/destroy run from the notebook)
```

- There's no test suite or linter. Check code by running notebook cells in order (the user runs GCP cells), by running a scenario outside the notebook, or locally against Docker Postgres with stand-ins for AlloyDB-only features.
- Settings come only from `.env` (template `.env.sample`, loaded with `python-dotenv`). Terraform gets them as `TF_VAR_*` from `db.terraform_env()`, called in Sections 1 and 12. Keep its `TERRAFORM_SETTINGS` list in line with `terraform/variables.tf`. Never print secrets.
  - **The one exception:** Section 5's `c5-config` cell prints the MCP configuration for Netomi, including the bearer token, for copy and paste. Netomi accepts this format:
    ```json
    {"summit_home_services": {"transport": "streamable_http", "url": "https://<NGROK_DOMAIN>/mcp",
      "headers": {"Authorization": "Bearer <MCP_AUTH_TOKEN>", "User-Agent": "netomi"}}}
    ```

## Architecture

```
Simulated customer (Claude + assets/scenarios/*.yaml)
   │  Netomi Chat API
   ▼
Netomi agent ── knowledge source (assets/netomi/knowledge.md / knowledge.pdf)
             ── MCP (Streamable HTTP, stateless, Bearer MCP_AUTH_TOKEN) via ngrok (NGROK_DOMAIN)
             │     ▼
             │   mcp_server.py (MCP SDK 2.x MCPServer): search_technicians · search_parts · book_slot
             │     ▼  connects as mcp_search (EXECUTE on the 3 tool functions only)
             │   AlloyDB (us-east4, c4a-highmem-1, PostgreSQL 18): BM25 + ScaNN + gemini-embedding-001
             └─ escalation (simulated: the agent says it's transferring; no human queue)
```

**MCP server (`mcp_server.py`):**
- **One tool, one function.** Each tool runs one `SELECT <function>(%s, …)` with bound parameters. The functions in `agent_functions.sql` are `SECURITY DEFINER` and return `jsonb`.
- **Return types must be annotated `dict[str, Any]`.** A bare `dict` gives no `structured_content`.
- **Keep it stateless** (`stateless_http=True`). With sessions, a server restart leaves Netomi sending an unknown session ID: 404, and failed tool calls. Nothing here needs sessions.
- **Every call is logged** to `mcp_server.log`: `tool call: name(args)`, then `result: <json>` or `failed: <error>`. Look there first when the agent misbehaves.
- **Where the agent's guidance lives** (one place each, so they never disagree):
  - **Tool docstrings** (read by Netomi from the MCP server): when to use each tool, its arguments, and the exact return fields. Keep them in line with the SQL. After a change, restart the server and refresh the tool list in Netomi.
  - **`next_step`** in the `search_technicians` and `book_slot` results, built in SQL: one sentence saying what to do with that result.
  - **`assets/netomi/booking-playbook.md`**: the booking workflow, as a Netomi Text playbook (search, offer in rank order, book on the customer's choice, recover from `booked: false`, confirm or transfer). It uses Netomi's format: `Step N - Name`, `Step N.M` branches, `Invoke @tool`, `→END PROCESS HERE`, and an Enforcement Summary; no curly brackets or em dashes. Every `book_slot` reason has its own branch. After a change, paste it into Netomi, insert each tool with the @ picker, Validate, and Move to Staging.
  - **`assets/netomi/agent-instructions.md`**: tone, refusals, and escalation outside the playbook. It never names tools. Paste it into Netomi again after a change.
- **Netomi runs in Staging only.** The Chat API reaches the Staging agent; nothing is synced to Production.
- **To restart the server,** stop it and start it in separate commands: a one-line `pkill -f "[f]irst_available.mcp_server"; … -m first_available.mcp_server` matches its own shell and kills it.

**Data and scenarios:**
- `catalog.sql` (12 technicians with profiles, 36 parts, BM25 and ScaNN indexes) runs once, because it embeds every row. `reset.sql` (empty bookings, fresh slots) runs before each conversation.
- **Booking is checked and atomic, and any reasonable call books.** `book_slot(technician, time, zip, brand, name, issue)` takes no IDs:
  - It finds the technician by name only among those who serve that ZIP code and brand (`technician_not_eligible` otherwise). The full name, the first name, or text containing the full name all work.
  - It reads the time by its parts (month, day, hour, minute, AM/PM), so "Fri Nov 13, 9:00 AM", "Friday, November 13th at 9 am" and "2026-11-13 09:00" are the same. A time that isn't one of the technician's gives `choose_again`.
  - It runs `UPDATE … WHERE status='open' AND start_time > now()`; a taken or past slot gives `time_taken`.
  - `choose_again` and `time_taken` include the technician's `open_times`, so the agent offers them without a second search.
  - It's idempotent: a repeated call for a booking the same customer already holds returns `booked: true` again.
  - Test changes locally on Docker Postgres against name and time variants. Changing its argument list needs the `DROP FUNCTION IF EXISTS` of the old signature in `agent_functions.sql`, and the new signature in `mcp_grants.sql`.
  - Conversation 2's `take_earliest_slot` hook plays "another customer" by calling `book_slot` for Tessa's earliest time.
- **Scenario rows:**
  - 80202/Northfield has 3 technicians. Sam Okafor, the drain specialist with the lowest rating, ranks first by search.
  - 80903/Kestrel has only Tessa Nguyen, with 2 slots.
  - 80521/Aspenware has no one.
- **Conversation 1 books Maria Lopez on purpose.** The customer breaks the equal-time tie by rating. The proof is that Sam is *offered* first and the booking matches the customer's choice. Don't change the persona to force Sam.

**Netomi Chat API (`netomi.py`):**
- Get a token, then send one POST per customer message with the same `conversationId`. A POST returns 201, so treat any 2xx as success.
- The reply is a stream of JSON objects, decoded with `json.JSONDecoder().raw_decode`.
  - Sort them by `customPayload.CHUNK_INDEX`, which is a string, so sort it numerically.
  - The turn is finished at `CHUNK_STATUS == "SUCCESS"`.
  - Text attachments are typed `ai.msg.domain.responses.core.Text`; skip `FillerText`.
- **Escalation is simulated, on purpose,** and the code doesn't look for a real handoff (`ownerType == "AGENT"`): the agent says it's transferring and restates the ZIP code, brand and issue, and the reply stays `BOT`. Don't add a real handoff, and don't describe Conversation 5 as handed off.
- `plan.md` has the headers, the request body, and the error codes.

## Search design (AlloyDB as a search engine)

- **Hybrid search is plain RRF SQL,** not `ai.hybrid_search`, whose text leg doesn't support BM25.
  - Each leg is a helper, `*_keyword_ranks` or `*_vector_ranks`, returning `(item_id, item_rank)` with up to 20 candidates.
  - The tool functions fuse them: `COALESCE(1/(60+k.rank),0) + COALESCE(1/(60+v.rank),0)`.
- **BM25** (`pg_textsearch`):
  - Index with `USING bm25 (col) WITH (text_config='english')`.
  - **Inside a function, name the index:** `col <@> to_bm25query(p_query, 'index_name')`.
  - Scores are negative, so sort ascending; drop rows that score 0 (no match).
  - The indexed columns are `technicians.profile` and the generated `parts.search_text`. Generated columns need immutable functions, so build it with `||`.
- **ScaNN:** `CREATE EXTENSION alloydb_scann CASCADE` (it also installs `vector`). Index with `USING scann (emb cosine) WITH (num_leaves = N, quantizer = 'SQ8')`, where N is at most the row count (3 for technicians, 6 for parts). Indexes are built after the data loads.
- **Embeddings:**
  - `embedding('gemini-embedding-001', text)` returns 3072 dimensions and needs no model registration.
  - Stored embeddings are generated columns. Each query is embedded once, into a plpgsql variable.
  - `google_ml_integration` is owned by `alloydbadmin` and kept updated by Google. `postgres` can't `ALTER EXTENSION` it, so don't try.
- **An exact part number in the query always ranks that part first.** RRF alone lets a near-miss win.
- **Vertex AI access** is in Terraform: AlloyDB's service agent (`google_project_service_identity`) gets `roles/aiplatform.user`. The grant can take a few minutes to work.

## Provisioning and teardown (Terraform)

Terraform (`terraform/`, providers `google`/`google-beta` `~> 8.10`, Terraform ≥ 1.11) owns **every** GCP resource. Section 1 runs `apply` and Section 12 runs `destroy`. Add new resources to `main.tf`; never put provisioning `gcloud` in the notebook.

- **Builds:**
  - **APIs:** `alloydb`, `aiplatform`, `compute`, `servicenetworking`, with `disable_on_destroy = false`, so they stay on.
  - **Network:** the dedicated VPC `summit-demo-net` with private services access: `alloydb-psa-range`, `VPC_PEERING` /16. The project's `default` network isn't ours.
  - **AlloyDB:** a PostgreSQL 18 cluster with one `c4a-highmem-1` zonal primary instance with a public IP. It needs `database_flags = { "password.enforce_complexity" = "on" }`.
  - **`mcp_search`:** a built-in user with no roles.
  - **IAM:** the Vertex AI grant above.
- **Passwords** are write-only (`password_wo`, ephemeral sensitive variables), so they never reach the state or plan files. Don't add outputs or `tfvars` for secrets.
- **Deletion settings:**
  - The service networking connection uses `deletion_policy = "REMOVE_PEERING"`, because AlloyDB holds the connection briefly after deletion.
  - The cluster uses `deletion_policy = "FORCE"` and `deletion_protection = false`.
  - `google_alloydb_user.mcp_search` uses `deletion_policy = "ABANDON"`: its grants block a direct drop, and the cluster's deletion removes it anyway.
- **Snap Terraform can't write to a redirected file** (`> file` gives 0 bytes). Pipe instead: `terraform … 2>&1 | tee -a terraform/terraform.log | grep --line-buffered -E "…"`.
- **State is local** (`terraform/terraform.tfstate`, gitignored). Keep `.terraform.lock.hcl`.
- **To check without creating anything:** `terraform init -backend=false`, `validate`, then `plan`, which shows 12 resources to add.
- **Section 12** stops the server and ngrok (`pkill -f "[f]…"`; the bracket stops `pkill` matching itself), runs `destroy`, then `terraform state list`, which should print nothing.
- **Logs are kept, never deleted, and never committed** (`.gitignore` has `*.log`). Both are appended to: `mcp_server.log` on each server start, `terraform/terraform.log` (`tee -a`) on each init, apply and destroy. Don't add cleanup that removes or overwrites them.

## Agent guardrails (the leash)

The agent has no SQL capability. Three layers:
1. **Tool descriptions, playbook and instructions (soft).** The docstrings say how to use each tool, `booking-playbook.md` is the booking workflow, and `agent-instructions.md` says to decline editing, deleting or revealing stored data, and when to escalate. Conversation 4 tests a prompt injection.
2. **The MCP server.**
   - It has three typed tools and no SQL tool, and arguments are bound as parameters.
   - It requires the static bearer token (`StaticTokenVerifier`); without it, 401.
   - `allowed_hosts` is localhost and `NGROK_DOMAIN`; any other Host header gets 421.
3. **Postgres privileges (the hard leash).**
   - `mcp_grants.sql` revokes `PUBLIC` access to our tables, sequences and all 7 functions.
   - It grants `mcp_search` `USAGE` on `public` and `EXECUTE` on the 3 tool functions only, with `statement_timeout = 15s`.
   - The tool functions are `SECURITY DEFINER` with `SET search_path = public`.

**Must stay true:**
- Section 4's `leash_report(conn)` (`leash.py`) shows `ok = True` on every row: no roles, tool function allowed, table reads and writes, `CREATE` and helper functions denied.
- Rerun `mcp_grants.sql` after adding or changing a function, because new functions are executable by `PUBLIC`.
- Search text never becomes SQL text.

**Accepted for the demo:**
- `book_slot` will book any eligible open slot, not only one the agent offered in this conversation (the server is stateless, so it can't know). The eligibility check limits that to technicians who serve the customer's ZIP code and brand.
- `mcp_search` can read the system catalogs.
- **Every database user can call AlloyDB's AI functions** (`public.embedding`, `ai.*`, `google_ml.*`), and `postgres` can't revoke that. Layer 2 is what stops the agent. Don't add a `leash_report` row or revokes that claim otherwise.

**Where the leash is shown:**
- Notebook Section 4 proves layers 2 and 3: the leash report, the tool list, a tool call, and the 401.
- Conversation 4 shows the injection transcript and the unchanged row counts.
- The article narrates all three layers.

## Notebook rules

The notebook has 26 cells: a title cell, then Sections 1–12, each a heading cell (`c<section>-intro`) and one code cell (`c<section>-<role>`). The headings hold no text; the explanations are in `assets/article.md`.
- **Keep it small.** The user always wants simplification: point out cells that could be merged or removed, and lead with the simpler option.
- **Group cells by teaching moment.** Show repeated examples in one cell (loop and `display()`). Put mechanics in package helpers.
- **Conversations 1–5 (Sections 7–11):** the code cell runs `reset.sql`, `run_scenario(...)`, then the verification table.
- **Section 12** is cleanup only: stop the processes and `terraform destroy`.
- **Clear all output before publishing.** Saved output includes the bearer token (`c5-config`), the ngrok domain and GCP project details.
- Section headings use exactly `## Section N - Title`.

## Guiding principles (apply to every file)

- **Netomi first.** In the article, keep backend sections brief and put the narrative weight on the agent's behavior.
- **Simplicity and readability beat efficiency.** Plain functions, plain SQL, obvious code; only what the demo needs.
- **No classes, no ORMs, no async.** The exceptions: `StaticTokenVerifier`, the SDK's token-check pattern, and `mcp_client.py`'s async `list_tools`/`call_tool`, awaited by the notebook.
- The notebook imports from the package. Never change `sys.path`.
- **Code cells ≤ ~10 lines.** Longer code goes in `.py`, `.sql` or `.yaml` files. The one agreed exception is Section 4's `c4-check` (about 15 lines), which proves the database and server layers of the leash in one cell.
- **Narrative and Netomi GUI steps go in the article,** not in notebook markdown.
- **Idempotent cells** where practical: `IF NOT EXISTS`, `CREATE OR REPLACE`, truncate first, skip if already running.
- **Readable output:** plain `Customer:` / `Agent:` transcripts, small DataFrames, never raw JSON.
- **Every demo output starts with one line saying what it is.** `print_table(table, title)` requires the title, and `run_scenario` prints a `Transcript:` line. A proof table's title says what to expect ("expect …"), not what happened.
- **Don't invent CLI flags, IAM roles, API fields or MCP parameters.** Verify them with `--help`, the provider docs and `terraform validate`, the installed SDK, real Netomi responses, or the vendor docs; read the relevant docs before proposing a live probe. Otherwise leave a `# TODO: verify`.
- The Netomi Headless Chat API doc (`headless-chat.htm` PDF) is kept outside the repo. Never commit it.
