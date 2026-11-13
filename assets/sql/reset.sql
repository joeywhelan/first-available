-- Reset the schedule before each conversation: no bookings, fresh open slots.
-- The catalog (technicians, parts, embeddings) is left alone, so nothing is re-embedded.

TRUNCATE bookings, slots RESTART IDENTITY;

-- Every technician except Tessa Nguyen: 9:00 AM and 1:00 PM (Denver time)
-- on each of the next 5 days.
INSERT INTO slots (technician_id, start_time)
SELECT t.id,
       ((now() AT TIME ZONE 'America/Denver')::date + d + h) AT TIME ZONE 'America/Denver'
FROM technicians t
CROSS JOIN generate_series(1, 5) AS d
CROSS JOIN (VALUES (time '09:00'), (time '13:00')) AS slot_times (h)
WHERE t.name <> 'Tessa Nguyen';

-- Conversation 2: Tessa Nguyen has exactly 2 open slots, tomorrow at 9:00 AM and 1:00 PM.
INSERT INTO slots (technician_id, start_time)
SELECT t.id,
       ((now() AT TIME ZONE 'America/Denver')::date + 1 + h) AT TIME ZONE 'America/Denver'
FROM technicians t
CROSS JOIN (VALUES (time '09:00'), (time '13:00')) AS slot_times (h)
WHERE t.name = 'Tessa Nguyen';
