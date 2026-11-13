-- The database side of the agent's three MCP tools:
--   search_technicians(), search_parts(), book_slot()
-- Each is SECURITY DEFINER (runs with its owner's rights), so the MCP server's
-- database user needs EXECUTE on these three functions and nothing else
-- (see mcp_grants.sql).
--
-- Hybrid search = two ranked lists fused with Reciprocal Rank Fusion (RRF):
--   * keyword leg: BM25 (pg_textsearch), great at exact terms like "E24" or "KS-PMP-410"
--   * vector leg:  ScaNN cosine distance on gemini-embedding-001 embeddings, great at meaning
--   * fusion:      score = 1/(60 + keyword rank) + 1/(60 + vector rank)
-- The search text is always a function argument, never pasted into SQL text.
-- Times are shown in Denver time, e.g. "Thu Nov 12, 9:00 AM".


-- ---------------------------------------------------------------------------
-- Search legs (helpers; not granted to the MCP user)
-- ---------------------------------------------------------------------------

-- BM25 ranks of technicians who serve the ZIP and brand. Inside a function,
-- pg_textsearch needs the index named explicitly (to_bm25query). BM25 scores are
-- negative (lower = better); 0 means no query word matched, so those rows are dropped.
CREATE OR REPLACE FUNCTION technician_keyword_ranks(p_issue text, p_zip text, p_brand text)
RETURNS TABLE (item_id int, item_rank bigint)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT id, RANK() OVER (ORDER BY score)
    FROM (
        SELECT t.id, t.profile <@> to_bm25query(p_issue, 'technicians_profile_bm25') AS score
        FROM technicians t
        WHERE trim(p_zip) = ANY (t.service_zips)
          AND EXISTS (SELECT 1 FROM unnest(t.certified_brands) b WHERE lower(b) = lower(trim(p_brand)))
        ORDER BY score
        LIMIT 20
    ) candidates
    WHERE score < 0;
$$;

-- ScaNN (vector) ranks of the same technicians. The issue is embedded once.
CREATE OR REPLACE FUNCTION technician_vector_ranks(p_issue text, p_zip text, p_brand text)
RETURNS TABLE (item_id int, item_rank bigint)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    issue_embedding vector := embedding('gemini-embedding-001', p_issue);
BEGIN
    RETURN QUERY
    SELECT id, RANK() OVER (ORDER BY distance)
    FROM (
        SELECT t.id, t.profile_embedding <=> issue_embedding AS distance
        FROM technicians t
        WHERE trim(p_zip) = ANY (t.service_zips)
          AND EXISTS (SELECT 1 FROM unnest(t.certified_brands) b WHERE lower(b) = lower(trim(p_brand)))
        ORDER BY distance
        LIMIT 20
    ) candidates;
END;
$$;

-- BM25 ranks of parts (optionally one brand).
CREATE OR REPLACE FUNCTION parts_keyword_ranks(p_query text, p_brand text)
RETURNS TABLE (item_id int, item_rank bigint)
LANGUAGE sql
STABLE
SET search_path = public
AS $$
    SELECT id, RANK() OVER (ORDER BY score)
    FROM (
        SELECT p.id, p.search_text <@> to_bm25query(p_query, 'parts_search_bm25') AS score
        FROM parts p
        WHERE p_brand IS NULL OR lower(p.brand) = lower(trim(p_brand))
        ORDER BY score
        LIMIT 20
    ) candidates
    WHERE score < 0;
$$;

-- ScaNN (vector) ranks of parts (optionally one brand). The query is embedded once.
CREATE OR REPLACE FUNCTION parts_vector_ranks(p_query text, p_brand text)
RETURNS TABLE (item_id int, item_rank bigint)
LANGUAGE plpgsql
STABLE
SET search_path = public
AS $$
DECLARE
    query_embedding vector := embedding('gemini-embedding-001', p_query);
BEGIN
    RETURN QUERY
    SELECT id, RANK() OVER (ORDER BY distance)
    FROM (
        SELECT p.id, p.search_embedding <=> query_embedding AS distance
        FROM parts p
        WHERE p_brand IS NULL OR lower(p.brand) = lower(trim(p_brand))
        ORDER BY distance
        LIMIT 20
    ) candidates;
END;
$$;


-- ---------------------------------------------------------------------------
-- The three tools
-- ---------------------------------------------------------------------------

-- Technicians who serve the ZIP, are certified for the brand, and have open slots,
-- ranked by how well their profile matches the customer's description of the issue.
-- Top 3, with up to 3 of their earliest open slots each. Each carries its rank (1 = best
-- match), so the order survives however the agent presents the list. next_step tells the
-- agent, in words, what to do with the result.
CREATE OR REPLACE FUNCTION search_technicians(p_zip text, p_brand text, p_issue text)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH fused AS (
        SELECT COALESCE(k.item_id, v.item_id) AS id,
               COALESCE(1.0 / (60 + k.item_rank), 0) + COALESCE(1.0 / (60 + v.item_rank), 0) AS score
        FROM technician_keyword_ranks(p_issue, p_zip, p_brand) k
        FULL OUTER JOIN technician_vector_ranks(p_issue, p_zip, p_brand) v ON v.item_id = k.item_id
    ),
    best AS (
        SELECT t.id, t.name, t.city, t.rating, f.score,
               row_number() OVER (ORDER BY f.score DESC, t.rating DESC) AS rank
        FROM fused f
        JOIN technicians t ON t.id = f.id
        WHERE EXISTS (SELECT 1 FROM slots s
                      WHERE s.technician_id = t.id AND s.status = 'open' AND s.start_time > now())
        ORDER BY f.score DESC, t.rating DESC
        LIMIT 3
    )
    SELECT jsonb_build_object(
               'technicians',
               COALESCE(jsonb_agg(
                   jsonb_build_object(
                       'rank', best.rank,
                       'technician', best.name,
                       'city', best.city,
                       'rating', best.rating,
                       'times', (SELECT jsonb_agg(
                                            to_char(s.start_time AT TIME ZONE 'America/Denver',
                                                    'Dy Mon FMDD, FMHH12:MI AM')
                                            ORDER BY s.start_time)
                                 FROM (SELECT start_time FROM slots
                                       WHERE technician_id = best.id AND status = 'open' AND start_time > now()
                                       ORDER BY start_time
                                       LIMIT 3) s))
                   ORDER BY best.rank),
                   '[]'::jsonb),
               'next_step',
               CASE WHEN count(*) = 0
                    THEN 'No technician who serves this ZIP code and brand has an open time. '
                         'Tell the customer, then transfer them to a human agent.'
                    ELSE 'Offer these technicians in rank order (1 first), each with their '
                         'rating and times, and ask which technician and time the customer wants.'
               END)
    FROM best;
$$;

-- Parts that best match a part number, model number, or plain-language description.
-- p_brand is optional (NULL = all brands). Top 5.
-- One rule on top of RRF: a part whose exact part number appears in the query ranks
-- first. RRF flattens rank differences (1st vs 4th in one list barely changes the
-- score), and a bare part number means nothing to the vector leg, so without this
-- rule a near-miss could outrank the exact part the customer asked for.
CREATE OR REPLACE FUNCTION search_parts(p_query text, p_brand text DEFAULT NULL)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
    WITH fused AS (
        SELECT COALESCE(k.item_id, v.item_id) AS id,
               COALESCE(1.0 / (60 + k.item_rank), 0) + COALESCE(1.0 / (60 + v.item_rank), 0) AS score
        FROM parts_keyword_ranks(p_query, p_brand) k
        FULL OUTER JOIN parts_vector_ranks(p_query, p_brand) v ON v.item_id = k.item_id
    ),
    best AS (
        SELECT p.*, f.score, strpos(upper(p_query), p.part_number) > 0 AS exact_match
        FROM fused f
        JOIN parts p ON p.id = f.id
        ORDER BY exact_match DESC, f.score DESC
        LIMIT 5
    )
    SELECT jsonb_build_object(
               'parts',
               COALESCE(jsonb_agg(
                   jsonb_build_object(
                       'part_number', best.part_number,
                       'name', best.name,
                       'brand', best.brand,
                       'fits_models', best.models,
                       'price', best.price,
                       'in_stock', best.stock > 0)
                   ORDER BY best.exact_match DESC, best.score DESC),
                   '[]'::jsonb))
    FROM best;
$$;

-- Book a visit with the technician the customer chose, at the time they chose.
--
-- Built so that every reasonable call books, and nothing a model is likely to do
-- turns into a refusal:
--   * No IDs. The agent passes the technician's name and the time, the two things
--     the customer said, so there is nothing to copy from the wrong list.
--   * The name is looked up only among technicians who serve the ZIP code and brand
--     (the eligibility rule), and may be the full name, the first name, or a longer
--     text that contains the full name ("Maria Lopez (4.9 stars)").
--   * The time is read by its parts (month, day, hour, minute, AM/PM), so the
--     weekday and wording don't matter: "Fri Nov 13, 9:00 AM", "Friday, November 13th
--     at 9 am" and "2026-11-13 09:00" are all the same time.
--   * Idempotent: calling again for a booking this customer already holds returns
--     booked: true again, so a retried call never reads as a failure.
-- Every result carries next_step, one sentence telling the agent what to do now.
--   * "time_taken":   someone else booked that time first (or it is in the past);
--   * "choose_again": the time isn't one of that technician's times.
--     Both list the technician's open_times, and next_step says to offer them.
--   * "technician_not_eligible": no technician by that name serves the ZIP and brand.
-- Only one caller can change a slot from open to booked: the UPDATE locks the row, and
-- a second caller re-checks status = 'open' after the first commits, so it updates nothing.
-- Older versions are dropped first: a new argument list would otherwise add a second
-- function rather than replace it.
DROP FUNCTION IF EXISTS book_slot(int, text, text);
DROP FUNCTION IF EXISTS book_slot(int, text, text, text, text);
DROP FUNCTION IF EXISTS book_slot(int, text, text, text, text, text);

CREATE OR REPLACE FUNCTION book_slot(p_technician text, p_time text, p_zip text,
                                     p_brand text, p_customer_name text, p_issue text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
    v_tech_id    int;
    v_technician text;
    v_parts      text[];     -- month, day, hour, minute, a/p read from p_time
    v_local      timestamp;  -- p_time as a Denver wall-clock time
    v_slot_id    int;
    v_start      timestamptz;
    v_open       jsonb;      -- the technician's open times, offered when not booked
    v_offer      text;
BEGIN
    -- 1. The technician: by name, among those who serve this ZIP code and brand.
    SELECT t.id, t.name INTO v_tech_id, v_technician
    FROM technicians t
    WHERE trim(p_zip) = ANY (t.service_zips)
      AND EXISTS (SELECT 1 FROM unnest(t.certified_brands) b WHERE lower(b) = lower(trim(p_brand)))
      AND (position(lower(t.name) IN lower(p_technician)) > 0               -- full name
           OR starts_with(lower(t.name), lower(trim(p_technician)) || ' '))  -- first name
    ORDER BY lower(t.name) = lower(trim(p_technician)) DESC, t.name
    LIMIT 1;

    IF v_tech_id IS NULL THEN
        RETURN jsonb_build_object(
            'booked', false, 'reason', 'technician_not_eligible',
            'next_step', format('No technician named %s serves this ZIP code and brand. Call '
                                'search_technicians again and offer only the technicians it returns.',
                                trim(p_technician)));
    END IF;

    SELECT jsonb_agg(to_char(s.start_time AT TIME ZONE 'America/Denver', 'Dy Mon FMDD, FMHH12:MI AM')
                     ORDER BY s.start_time)
    INTO v_open
    FROM slots s
    WHERE s.technician_id = v_tech_id AND s.status = 'open' AND s.start_time > now();
    v_open := COALESCE(v_open, '[]'::jsonb);
    v_offer := CASE WHEN v_open = '[]'::jsonb
                    THEN format('%s has no other open times. Call search_technicians again to '
                                'offer other technicians.', v_technician)
                    ELSE format('Offer the customer these open times with %s, and when they pick '
                                'one, call book_slot with it.', v_technician)
               END;

    -- 2. The time: read month, day, hour, minute and AM/PM; else try an ISO timestamp.
    v_parts := regexp_match(lower(p_time),
        '(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s*(\d{1,2})(?:st|nd|rd|th)?\M'
        '.*?\m(\d{1,2})(?::(\d{2}))?\s*([ap])\.?\s*m\M');
    IF v_parts IS NULL THEN
        BEGIN
            v_local := p_time::timestamp;
        EXCEPTION WHEN others THEN
            v_local := NULL;
        END;
    END IF;

    SELECT s.id, s.start_time INTO v_slot_id, v_start
    FROM slots s
    WHERE s.technician_id = v_tech_id
      AND CASE WHEN v_parts IS NOT NULL THEN
                   to_char(s.start_time AT TIME ZONE 'America/Denver', 'mon') = v_parts[1]
               AND extract(day FROM s.start_time AT TIME ZONE 'America/Denver') = v_parts[2]::int
               AND to_char(s.start_time AT TIME ZONE 'America/Denver', 'HH12')::int = v_parts[3]::int
               AND extract(minute FROM s.start_time AT TIME ZONE 'America/Denver')
                   = COALESCE(v_parts[4], '0')::int
               AND to_char(s.start_time AT TIME ZONE 'America/Denver', 'am') = v_parts[5] || 'm'
          ELSE s.start_time AT TIME ZONE 'America/Denver' = v_local
          END
    ORDER BY s.start_time DESC   -- the latest year, if a month and day repeat
    LIMIT 1;

    IF v_slot_id IS NULL THEN
        RETURN jsonb_build_object(
            'booked', false, 'reason', 'choose_again', 'open_times', v_open,
            'next_step', format('%s isn''t one of %s''s times. ', trim(p_time), v_technician)
                         || v_offer);
    END IF;

    -- 3. Book it: only an open, future slot, and only once.
    UPDATE slots SET status = 'booked'
    WHERE id = v_slot_id AND status = 'open' AND start_time > now();

    IF FOUND THEN
        INSERT INTO bookings (slot_id, customer_name, issue)
        VALUES (v_slot_id, trim(p_customer_name), p_issue);
    ELSIF NOT EXISTS (SELECT 1 FROM bookings
                      WHERE slot_id = v_slot_id
                        AND lower(customer_name) = lower(trim(p_customer_name))) THEN
        RETURN jsonb_build_object(
            'booked', false, 'reason', 'time_taken', 'open_times', v_open,
            'next_step', 'Someone else just booked that time. Apologize briefly. ' || v_offer);
    END IF;
    -- (Not FOUND but already this customer's booking: a repeated call. Confirm it again.)

    RETURN jsonb_build_object(
        'booked', true,
        'technician', v_technician,
        'time', to_char(v_start AT TIME ZONE 'America/Denver', 'Dy Mon FMDD, FMHH12:MI AM'),
        'next_step', format('Confirm to the customer: %s, %s.', v_technician,
                            to_char(v_start AT TIME ZONE 'America/Denver', 'Dy Mon FMDD, FMHH12:MI AM')));
END;
$$;
