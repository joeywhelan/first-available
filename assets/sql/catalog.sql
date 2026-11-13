-- Searchable catalog: technicians (with profiles) and replacement parts.
-- Run once after schema.sql. Re-running reloads everything (and re-embeds ~50 rows).
-- Brands and model numbers are fictional: Northfield (N*), Kestrel (K*), Aspenware (A*).

TRUNCATE bookings, slots, parts, technicians RESTART IDENTITY CASCADE;

INSERT INTO technicians (name, city, service_zips, certified_brands, rating, profile) VALUES
    -- Denver. Conversation 1: 80202 + Northfield has exactly 3 technicians, and only
    -- Sam Okafor is a drain specialist. He has the lowest rating of the three, so
    -- ranking him first comes from search relevance, not from rating.
    ('Maria Lopez', 'Denver', '{80202,80203,80205}', '{Northfield,Kestrel}', 4.9,
     'Cooking appliance specialist: ovens, ranges and cooktops. Replaces bake and broil elements, igniters, thermostats and oven control boards. Fixes ovens that will not heat or bake unevenly.'),
    ('Dev Patel', 'Denver', '{80202,80206,80218}', '{Northfield}', 4.7,
     'Refrigeration technician: refrigerators, freezers and ice makers. Diagnoses compressors, defrost systems and temperature problems, and repairs water dispensers.'),
    ('Sam Okafor', 'Denver', '{80202,80211}', '{Northfield,Aspenware}', 4.6,
     'Dishwasher drain and pump specialist. Clears drain error codes such as E24 and E25, replaces drain pumps, filters and check valves, and fixes standing water left in the bottom of the tub.'),
    ('Hannah Berg', 'Denver', '{80203,80206}', '{Aspenware,Kestrel}', 4.8,
     'Washer and dryer repair: drum bearings, door locks, belts and heating elements. Fixes washers that will not spin and dryers that will not heat.'),
    ('Luis Romero', 'Denver', '{80205,80211,80218}', '{Kestrel}', 4.5,
     'Leak specialist for dishwashers and washers: door gaskets, water inlet valves and hoses. Fixes water on the floor and machines that will not fill.'),

    -- Colorado Springs. Conversation 2: 80903 + Kestrel has only Tessa Nguyen (2 slots, in reset.sql).
    ('Tessa Nguyen', 'Colorado Springs', '{80903,80904,80905}', '{Kestrel}', 4.8,
     'Dishwasher and refrigerator repair: drain pumps, door seals, ice makers and electronic control boards.'),
    ('Marcus Reed', 'Colorado Springs', '{80903,80907}', '{Northfield,Aspenware}', 4.6,
     'Gas and electric ovens and ranges: igniters, burners, gas valves and temperature sensors.'),
    ('Grace Kim', 'Colorado Springs', '{80904,80909}', '{Kestrel,Northfield}', 4.4,
     'Refrigerators and dishwashers: sealed systems, condenser fans, drain hoses and spray arms.'),
    ('Owen Carter', 'Colorado Springs', '{80905,80907,80909}', '{Aspenware}', 4.7,
     'Laundry and cooking appliances: washers, dryers and ovens. Motors, belts and heating elements.'),

    -- Fort Collins. Conversation 5: nobody serves 80521 for Aspenware.
    ('Priya Shah', 'Fort Collins', '{80521,80524}', '{Northfield,Kestrel}', 4.9,
     'Dishwasher and refrigerator specialist: drain pumps, water inlet valves, ice makers and defrost problems.'),
    ('Ben Hollis', 'Fort Collins', '{80521,80525,80526}', '{Kestrel}', 4.5,
     'Washers and dishwashers: leaks, pumps, hoses and door locks.'),
    ('Ana Ruiz', 'Fort Collins', '{80524,80526}', '{Aspenware,Northfield}', 4.7,
     'Ovens, ranges and refrigerators: igniters, heating elements, thermostats and compressors.');

-- Parts. Conversation 3 asks about the Kestrel KD-412 door gasket in plain words
-- ("the rubber strip around the door is torn"), which only vector search understands,
-- while exact part and model numbers are where BM25 keyword search shines.
INSERT INTO parts (part_number, name, brand, models, description, price, stock) VALUES
    -- Northfield dishwashers (ND-300, ND-500)
    ('NF-PMP-310', 'Drain pump', 'Northfield', 'ND-300 ND-500',
     'Electric pump that pushes used water out of the dishwasher tub into the drain hose. Replace when the dishwasher shows E24 or leaves standing water.', 64.50, 12),
    ('NF-FLT-300', 'Filter assembly', 'Northfield', 'ND-300 ND-500',
     'Mesh filter at the bottom of the tub that traps food particles before they reach the drain. A clogged filter causes slow draining and odors.', 18.25, 30),
    ('NF-VLV-305', 'Drain check valve', 'Northfield', 'ND-300 ND-500',
     'One-way flap that stops dirty water flowing back into the tub from the drain hose.', 9.75, 22),
    ('NF-GSK-300', 'Door gasket', 'Northfield', 'ND-300',
     'Rubber seal around the dishwasher door that keeps water inside during a wash cycle.', 27.00, 8),
    ('NF-ARM-500', 'Lower spray arm', 'Northfield', 'ND-500',
     'Rotating arm that sprays water up onto the dishes in the bottom rack.', 21.40, 15),
    ('NF-INL-300', 'Water inlet valve', 'Northfield', 'ND-300 ND-500',
     'Electric valve that opens to let fresh water into the dishwasher. A faulty valve means the machine will not fill.', 33.90, 10),
    ('NF-HTR-500', 'Heating element', 'Northfield', 'ND-500',
     'Element under the tub that heats wash water and dries the dishes.', 46.00, 6),
    ('NF-BRD-300', 'Electronic control board', 'Northfield', 'ND-300',
     'Main circuit board that runs the wash cycles and shows error codes.', 129.00, 3),

    -- Northfield refrigerators (NR-200) and washers (NW-700)
    ('NF-ICE-200', 'Ice maker assembly', 'Northfield', 'NR-200',
     'Complete ice maker unit in the freezer that fills, freezes and drops ice cubes.', 89.99, 5),
    ('NF-DFT-200', 'Defrost thermostat', 'Northfield', 'NR-200',
     'Sensor that switches the defrost heater off once frost has melted from the evaporator coils.', 15.60, 14),
    ('NF-FAN-200', 'Evaporator fan motor', 'Northfield', 'NR-200',
     'Fan that circulates cold air from the freezer into the fresh food compartment.', 38.75, 9),
    ('NF-BLT-700', 'Drive belt', 'Northfield', 'NW-700',
     'Rubber belt that turns the washer drum. A worn belt means the drum will not spin.', 16.20, 18),
    ('NF-LCK-700', 'Door lock switch', 'Northfield', 'NW-700',
     'Latch and switch that lock the washer door during a cycle so it cannot open while full of water.', 31.50, 11),

    -- Kestrel dishwashers (KD-400, KD-412, KD-600)
    ('KS-PMP-410', 'Drain pump', 'Kestrel', 'KD-400 KD-412 KD-600',
     'Pump that empties dirty water from the dishwasher at the end of each cycle. Fixes standing water and drain error codes.', 59.95, 7),
    ('KS-GSK-412', 'Door gasket', 'Kestrel', 'KD-400 KD-412',
     'Rubber seal around the edge of the dishwasher door. A torn or flattened seal lets water leak onto the floor.', 24.50, 16),
    ('KS-GSK-600', 'Door gasket', 'Kestrel', 'KD-600',
     'Rubber seal around the edge of the dishwasher door for the larger KD-600 tub.', 26.50, 4),
    ('KS-FLT-410', 'Filter assembly', 'Kestrel', 'KD-400 KD-412 KD-600',
     'Removable filter that catches food scraps before the water drains. Clean or replace if draining is slow.', 17.80, 25),
    ('KS-ARM-412', 'Upper spray arm', 'Kestrel', 'KD-412 KD-600',
     'Spinning arm under the top rack that sprays water onto glasses and cups.', 19.90, 13),
    ('KS-INL-400', 'Water inlet valve', 'Kestrel', 'KD-400 KD-412 KD-600',
     'Solenoid valve that controls fresh water coming into the dishwasher.', 35.25, 8),
    ('KS-LAT-412', 'Door latch', 'Kestrel', 'KD-400 KD-412',
     'Catch that holds the dishwasher door shut and tells the control board the door is closed.', 22.10, 12),
    ('KS-HOS-400', 'Drain hose', 'Kestrel', 'KD-400 KD-412 KD-600',
     'Flexible hose that carries waste water from the pump to the sink drain or disposal.', 12.40, 20),

    -- Kestrel refrigerators (KR-300) and washers (KW-800)
    ('KS-ICE-300', 'Ice maker assembly', 'Kestrel', 'KR-300',
     'Automatic ice maker that fills with water and ejects ice into the bin.', 94.00, 2),
    ('KS-WTR-300', 'Water filter', 'Kestrel', 'KR-300',
     'Cartridge that filters drinking water and ice. Replace every six months.', 44.95, 40),
    ('KS-CMP-300', 'Compressor start relay', 'Kestrel', 'KR-300',
     'Relay that starts the compressor. A clicking fridge that is not cooling often has a failed start relay.', 28.30, 6),
    ('KS-BRG-800', 'Drum bearing kit', 'Kestrel', 'KW-800',
     'Bearings and seal that let the washer drum spin smoothly. Loud rumbling during spin means worn bearings.', 72.00, 4),
    ('KS-PMP-800', 'Washer drain pump', 'Kestrel', 'KW-800',
     'Pump that empties the washer drum before the spin cycle.', 54.75, 5),

    -- Aspenware ovens and ranges (AO-100, AR-250) and dryers (AD-900)
    ('AS-IGN-250', 'Oven igniter', 'Aspenware', 'AR-250',
     'Glow-bar igniter that lights the gas in the oven. A weak igniter means the oven will not heat.', 41.80, 9),
    ('AS-BKE-100', 'Bake element', 'Aspenware', 'AO-100',
     'Heating element on the floor of the electric oven used for baking.', 36.50, 11),
    ('AS-BRL-100', 'Broil element', 'Aspenware', 'AO-100',
     'Heating element at the top of the oven used for broiling.', 38.00, 7),
    ('AS-SNS-100', 'Oven temperature sensor', 'Aspenware', 'AO-100 AR-250',
     'Probe that measures oven temperature so the control can hold the set heat. A bad sensor causes uneven baking.', 23.75, 15),
    ('AS-KNB-250', 'Burner control knob', 'Aspenware', 'AR-250',
     'Front knob that turns a gas burner on and sets the flame.', 8.90, 30),
    ('AS-BRD-100', 'Oven control board', 'Aspenware', 'AO-100',
     'Electronic control that runs the oven clock, timer and temperature.', 149.00, 2),
    ('AS-HTR-900', 'Dryer heating element', 'Aspenware', 'AD-900',
     'Coil that heats the air in an electric dryer. Clothes stay damp when it fails.', 47.20, 6),
    ('AS-BLT-900', 'Dryer drum belt', 'Aspenware', 'AD-900',
     'Belt that turns the dryer drum. The drum will not tumble if it breaks.', 14.60, 19),
    ('AS-FUS-900', 'Thermal fuse', 'Aspenware', 'AD-900',
     'Safety fuse that cuts power to the dryer when it overheats.', 7.95, 35),
    ('AS-LNT-900', 'Lint filter', 'Aspenware', 'AD-900',
     'Screen that catches lint from the dryer air. A clogged screen slows drying.', 11.30, 28);

-- Indexes are created after the data, as the AlloyDB BM25 docs recommend.
-- A ScaNN index needs at least num_leaves rows, so num_leaves is small here.
CREATE INDEX IF NOT EXISTS technicians_profile_bm25 ON technicians
    USING bm25 (profile) WITH (text_config = 'english');
CREATE INDEX IF NOT EXISTS technicians_profile_scann ON technicians
    USING scann (profile_embedding cosine) WITH (num_leaves = 3, quantizer = 'SQ8');

CREATE INDEX IF NOT EXISTS parts_search_bm25 ON parts
    USING bm25 (search_text) WITH (text_config = 'english');
CREATE INDEX IF NOT EXISTS parts_search_scann ON parts
    USING scann (search_embedding cosine) WITH (num_leaves = 6, quantizer = 'SQ8');
