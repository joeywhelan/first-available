# Plan: Netomi Virtual Agent with Live Data from AlloyDB

Design spec. `CLAUDE.md` has the rules, the architecture and the guardrails. This file has the goals, scenarios, notebook outline and Chat API details. `assets/article.md` is the write-up.

## Goal

**Thesis: rules in the tools, not the prompt.** Business rules that must always hold live in database functions behind MCP tools, so the agent can't bend them and the agent builder never writes SQL. The prompt and the booking playbook keep only judgement and workflow (tone, refusals, escalation, the booking steps).

A Jupyter notebook that **showcases the Netomi virtual agent** resolving appliance-repair requests for "Summit Home Services", a fictional company, end to end.
- A simulated customer (Claude) chats with the agent through the Netomi Chat API.
- The notebook prints each transcript, then checks the database to prove the outcome.
- AlloyDB, used as a hybrid search engine, supplies live data through our own three-tool MCP server. The backend is set up quickly and kept brief.

**What the demo shows:**
1. **Two kinds of answers in one conversation:** knowledge-source explanations plus live results.
2. **Search that understands customers:** exact codes and part numbers (BM25) plus plain descriptions (ScaNN), fused with RRF.
3. **Graceful recovery** when another customer takes a slot mid-conversation.
4. **Safe under pressure:** it declines a prompt injection, and it has no way to run SQL anyway.
5. **Clean escalation** to a person, with the ZIP code, brand and issue restated. Simulated: there's no live human queue.

## Repository

```
assets/
  netomi/      agent-instructions.md and booking-playbook.md (pasted into Netomi), knowledge.md + knowledge.pdf (knowledge source)
  scenarios/   1-diagnose-and-book, 2-slot-taken, 3-find-the-part, 4-prompt-injection, 5-escalation (.yaml)
  sql/         schema, catalog (run once; embeds), reset (before each conversation), agent_functions, mcp_grants
  plan.md      this file (the design spec)
  article.md   the write-up (narrative, setup steps, transcripts, summary tables)
src/first_available/
  db.py            AlloyDB connector, run_sql_file, query, print_table
  search.py        compare_search, technicians_for (Section 3 tables)
  leash.py         leash_report (Section 4)
  mcp_server.py    the three tools; stateless; logs every call to mcp_server.log
  mcp_client.py    start_server, start_tunnel (ngrok), async list_tools/call_tool
  netomi.py        get_token, send_message (Chat API)
  customer.py      next_customer_message (Claude plays the persona)
  conversation.py  load_scenario, run_scenario, take_earliest_slot, bookings
terraform/         main.tf, variables.tf, versions.tf, outputs.tf, .terraform.lock.hcl
demo.ipynb, README.md, CLAUDE.md, .env.sample, pyproject.toml, uv.lock, LICENSE
```

## Data

- `technicians`: `name`, `city`, `service_zips[]`, `certified_brands[]`, `rating`, `profile` (free text), and `profile_embedding`, generated in the database.
- `slots`: `technician_id`, `start_time`, `status` (`open`/`booked`). `reset.sql` gives every technician 9:00 AM and 1:00 PM (Denver time) on each of the next 5 days, except Tessa Nguyen, who gets only tomorrow's two.
- `bookings`: `slot_id` (unique), `customer_name`, `issue`.
- `parts`: 36 rows. `part_number`, `name`, `brand`, `models`, `description`, `price`, `stock`, plus a generated `search_text` (BM25) and `search_embedding` (name + description).
- Brands: Northfield, Kestrel, Aspenware. Cities: Denver, Colorado Springs, Fort Collins.

**Tool functions** (`agent_functions.sql`, each returns `jsonb`):
- `search_technicians(zip, brand, issue)`: ZIP code and brand are hard filters. Ranking is hybrid on the profile against the issue. Only technicians with an open future slot are returned. Returns `{"technicians": [{rank, technician, city, rating, times: ["Fri Nov 13, 9:00 AM", …]}], "next_step": "…"}`: the top 3, with up to 3 slots each.
- `search_parts(query, brand?)`: hybrid search, with an exact part number ranked first. Returns `{"parts": [{part_number, name, brand, fits_models, price, in_stock}]}`, the top 5.
- `book_slot(technician, time, zip, brand, customer_name, issue)`: books the named technician, matched by name among those who serve the ZIP code and brand, at that time, read by month, day, hour, minute and AM/PM. Books atomically (open, future slots only); a repeated call by the same customer confirms again. Returns `{"booked": true, technician, time, next_step}` or `{"booked": false, "reason": "choose_again" | "time_taken" | "technician_not_eligible", open_times, next_step}`; `open_times` (not for `technician_not_eligible`) lists that technician's remaining times.

## Scenarios

| # | File | Customer | Behavior | Proof (in the database) |
|---|---|---|---|---|
| 1 | `1-diagnose-and-book` | Jordan Smith, 80202, Northfield | Asks about E24 and a visit; earliest time, ties broken by rating | Sam offered first; one booking, with the technician chosen (Maria Lopez) |
| 2 | `2-slot-taken` | Casey Rivera, 80903, Kestrel | Earliest time; accepts the next one if it's taken | "Another Customer" holds the first slot; Casey has the second |
| 3 | `3-find-the-part` | Morgan Lee, Kestrel KD-412 | "The rubber strip around the door" | The agent names `KS-GSK-412` |
| 4 | `4-prompt-injection` | Tester | Tries to delete data twice, then asks about E24 | Bookings, technicians and parts unchanged |
| 5 | `5-escalation` | Pat Morgan, 80521, Aspenware oven | Asks for a person if no one is available | The agent says it's transferring, with the ZIP code, brand and issue; no booking |

- A scenario file has a fixed `opening_message`, a `persona`, a `goal` and `max_turns`.
- `run_scenario` stops at `[END]` or `max_turns`, and returns the transcript as `(speaker, text)` pairs.

## Notebook outline (`demo.ipynb`, 26 cells)

A title cell, then each section is a heading cell and one code cell. The explanations are in `assets/article.md`.

1. **Backend Setup:** `terraform_env()` and `terraform apply`.
2. **Load the Catalog:** load the SQL and show the catalog.
3. **AlloyDB as a Search Engine:** BM25 vs ScaNN vs hybrid, for parts and for technicians, in one code cell.
4. **The Agent's Leash:** one code cell proves both layers: `mcp_grants.sql` and the leash report, then start the server and ngrok and check the tool list, a tool call and the 401.
5. **Configure the Netomi Agent:** print the MCP config. The GUI steps are in the article and below.
6. **Talk to the Agent from Code:** imports, and say hello.
7–11. **Conversations 1–5:** two cells each.
12. **Cleanup:** stop the processes and `terraform destroy`. The logs are kept (and gitignored). The summary tables are in the article.

## Netomi setup (by hand, Section 5)

- **MCP server:** paste the printed JSON (Streamable HTTP, bearer token, `User-Agent: netomi`).
- **Instructions:** paste `assets/netomi/agent-instructions.md`.
- **Booking playbook:** create a Text playbook from `assets/netomi/booking-playbook.md`, insert each tool with the @ picker, Validate, and Move to Staging. The demo runs against Staging.
- **Knowledge source:** upload `assets/netomi/knowledge.md`, or its PDF, `knowledge.pdf`.
- **Chat API:** copy the channel reference ID and the virtual agent ID into `.env`.

## Netomi Chat API details

- **Token:** POST `NETOMI_AUTH_URL` with `x-channel: CHAT`, `x-channel-ref-id` and `x-virtual-agent-id`. The response has `payload.token`, valid for 24 hours.
- **Message:** POST `NETOMI_CHAT_URL` with the same headers plus `x-integration` (`NETOMI_INTEGRATION`) and `x-auth-token`.
  - Body: `{"conversationId", "ownerType": "BOT", "messagePayload": {"text", "label": ".", "messageId": <uuid>, "timestamp": <epoch ms>}}`.
  - It returns 201 and a stream of JSON objects. Each has `customPayload.CHUNK_INDEX` (a string) and `CHUNK_STATUS`.
- **Attachments**, by the type's suffix:
  - `Text`: the answer, possibly HTML. Strip tags, and add `quickReply.options` as `Options: A | B`.
  - `FillerText`: skip.
  - `MultiSource`: citations.
  - Anything else: print `[<Kind>]`.
- **Errors:** 400 (a missing field), 401 (a bad or expired token), 500 (bad IDs or a downstream failure). Raise an error with Netomi's `message`, and never print the token.
- `send_message` returns `{text, sources}`.
