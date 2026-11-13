-- Summit Home Services: scheduling data plus two searchable catalogs.
-- Safe to re-run. Indexes are created in catalog.sql, after the data loads.

-- AlloyDB AI: embedding() calls Vertex AI from SQL. AlloyDB preinstalls it and keeps
-- it updated (it's owned by Google's alloydbadmin role, so we can't ALTER it).
-- Version 1.5.3+ is needed for gemini-embedding-001 without transform functions.
CREATE EXTENSION IF NOT EXISTS google_ml_integration;

-- ScaNN vector index. CASCADE also installs the vector type (pgvector).
CREATE EXTENSION IF NOT EXISTS alloydb_scann CASCADE;

-- BM25 keyword index (pg_textsearch).
CREATE EXTENSION IF NOT EXISTS pg_textsearch;

-- Technicians. profile is free text describing what each technician is good at.
-- profile_embedding is computed by AlloyDB itself when a row is inserted.
CREATE TABLE IF NOT EXISTS technicians (
    id                serial PRIMARY KEY,
    name              text NOT NULL,
    city              text NOT NULL,
    service_zips      text[] NOT NULL,
    certified_brands  text[] NOT NULL,
    rating            numeric(2,1) NOT NULL,
    profile           text NOT NULL,
    profile_embedding vector(3072)
        GENERATED ALWAYS AS (embedding('gemini-embedding-001', profile)) STORED
);

CREATE TABLE IF NOT EXISTS slots (
    id            serial PRIMARY KEY,
    technician_id int NOT NULL REFERENCES technicians (id),
    start_time    timestamptz NOT NULL,
    status        text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'booked'))
);

CREATE TABLE IF NOT EXISTS bookings (
    id            serial PRIMARY KEY,
    slot_id       int NOT NULL UNIQUE REFERENCES slots (id),
    customer_name text NOT NULL,
    issue         text NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now()
);

-- Replacement parts.
-- search_text holds everything a keyword search should match: part number, name,
-- compatible models, description. The embedding uses only name + description,
-- because part numbers carry no meaning for a vector.
CREATE TABLE IF NOT EXISTS parts (
    id               serial PRIMARY KEY,
    part_number      text NOT NULL UNIQUE,
    name             text NOT NULL,
    brand            text NOT NULL,
    models           text NOT NULL,   -- compatible model numbers, space-separated
    description      text NOT NULL,
    price            numeric(7,2) NOT NULL,
    stock            int NOT NULL,
    search_text      text
        GENERATED ALWAYS AS (part_number || ' ' || name || ' ' || models || ' ' || description) STORED,
    search_embedding vector(3072)
        GENERATED ALWAYS AS (embedding('gemini-embedding-001', name || '. ' || description)) STORED
);
