-- Complete Medipim Replication System
-- This migration captures the final state of all tables, functions, and configurations
-- Applied incrementally via previous migrations and apply_migration calls

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Core Product Table (from architecture specification)
CREATE TABLE IF NOT EXISTS products (
  -- Core identifiers
  id TEXT PRIMARY KEY,                    -- "Medipim ID of the product (string, unique)"
  status TEXT,                           -- "active, inactive, replaced, no_selection"
  replacement TEXT,                      -- "Medipim ID of the replacing product"
  
  -- Australian regulatory identifiers
  artg_id TEXT,                         -- "ARTG ID (string)"
  pbs TEXT,                             -- "PBS code (string)"
  fred TEXT,                            -- "Fred code (string)"
  z_code TEXT,                          -- "Z code (string)"
  
  -- SNOMED codes (all 7 required for AU)
  snomed_mp TEXT,                       -- "SNOMED-MP code (string)"
  snomed_mpp TEXT,                      -- "SNOMED-MPP code (string)"
  snomed_mpuu TEXT,                     -- "SNOMED-MPUU code (string)"
  snomed_tp TEXT,                       -- "SNOMED-TP code (string)"
  snomed_tpp TEXT,                      -- "SNOMED-TPP code (string)"
  snomed_tpuu TEXT,                     -- "SNOMED-TPUU code (string)"
  snomed_ctpp TEXT,                     -- "SNOMED-CTPP code (string)"
  
  -- Standard identifiers
  ean TEXT[],                           -- "EAN codes (integer[])"
  ean_gtin8 TEXT,                       -- "integer with exactly 8 digits"
  ean_gtin12 TEXT,                      -- "integer with exactly 12 digits"
  ean_gtin13 TEXT,                      -- "integer with exactly 13 digits"
  ean_gtin14 TEXT,                      -- "integer with exactly 14 digits"
  
  -- Core product data
  name_en TEXT,                         -- English name (primary for AU)
  seo_name_en TEXT,
  requires_legal_text BOOLEAN,
  biocide BOOLEAN,
  
  -- Pricing (in cents as per API docs)
  public_price INTEGER,                 -- "Public price (integer, in $) (⚠️value is including VAT)"
  manufacturer_price INTEGER,           -- "Manufacturer price (integer, in $) (⚠️value is excluding VAT)"
  pharmacist_price INTEGER,             -- "Pharmacist price (integer, in $) (⚠️value is excluding VAT)"
  
  -- Complete API response preserved
  raw_data JSONB,                       -- Native Postgres JSONB
  
  -- Metadata
  created_at BIGINT,                    -- "unix timestamp"
  updated_at BIGINT                     -- "unix timestamp"
);

-- Required indexes on products table
CREATE INDEX IF NOT EXISTS idx_products_updated_at ON products(updated_at);
CREATE INDEX IF NOT EXISTS idx_products_artg_id ON products(artg_id) WHERE artg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_pbs ON products(pbs) WHERE pbs IS NOT NULL;

-- Reference Data Tables
CREATE TABLE IF NOT EXISTS organizations (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the organization (integer, unique)"
  name TEXT,                           -- "Name of the organization (string)"
  type TEXT,                           -- "supplier, marketing, medical_professional, other"
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS brands (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the brand (integer, unique)"
  name TEXT,                           -- "Name of the brand (string)"
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public_categories (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the public category (integer, unique)"
  name_en TEXT,                        -- "Name of the public category (string, localized)"
  parent INTEGER,                      -- "Id of the parent category (integer)"
  order_index INTEGER,                 -- "Sort order of the public category (integer)"
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS product_families (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS active_ingredients (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the active ingredient (integer, unique)"
  name_en TEXT,                        -- "Name of the active ingredient (string, localized)"
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS media (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the media item (integer, unique)"
  type TEXT,                           -- "photo" or "link"
  photo_type TEXT,                     -- "packshot, productshot, lifestyle_image, pillshot"
  storage_path TEXT,                   -- Path in Supabase Storage (NULL for metadata-only approach)
  raw_data JSONB
);

-- Junction tables for many-to-many relationships
CREATE TABLE IF NOT EXISTS product_organizations (
  product_id TEXT REFERENCES products(id),
  organization_id INTEGER REFERENCES organizations(id),
  PRIMARY KEY (product_id, organization_id)
);

CREATE TABLE IF NOT EXISTS product_brands (
  product_id TEXT REFERENCES products(id),
  brand_id INTEGER REFERENCES brands(id),
  PRIMARY KEY (product_id, brand_id)
);

CREATE TABLE IF NOT EXISTS product_categories (
  product_id TEXT REFERENCES products(id),
  category_id INTEGER REFERENCES public_categories(id),
  PRIMARY KEY (product_id, category_id)
);

CREATE TABLE IF NOT EXISTS product_media (
  product_id TEXT REFERENCES products(id),
  media_id INTEGER REFERENCES media(id),
  PRIMARY KEY (product_id, media_id)
);

-- Sync Infrastructure Tables
CREATE TABLE IF NOT EXISTS sync_state (
  entity_type TEXT PRIMARY KEY,
  last_sync_timestamp BIGINT,          -- Unix timestamp for updatedSince filter
  last_sync_status TEXT,
  sync_count INTEGER DEFAULT 0,
  current_page INTEGER DEFAULT 0,      -- For resumable pagination
  chunk_status TEXT DEFAULT 'pending', -- Track chunk processing state
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS sync_errors (
  id BIGSERIAL PRIMARY KEY,
  sync_type TEXT,
  error_message TEXT,
  error_data JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS deferred_relationships (
  id SERIAL PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  relationship_type TEXT NOT NULL,
  relationship_data JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create task queue with native visibility timeout and archiving
SELECT pgmq.create('medipim_sync_tasks');
SELECT pgmq.set_vt('medipim_sync_tasks', 300); -- 5 minute visibility timeout

-- Configure pg_net for Medipim rate limits
ALTER ROLE postgres SET pg_net.batch_size = 1;  -- 1 request per second max
SELECT net.worker_restart();

-- Note: Database functions, RLS policies, and cron jobs are defined in separate migration files
-- This migration establishes the core schema structure