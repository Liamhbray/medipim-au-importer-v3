-- Complete Medipim Database Schema
-- Creates all 14 tables with exact field mappings from architecture specification

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net; 
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Create PGMQ task queue
SELECT pgmq.create('medipim_sync_tasks');

-- Core Product Table (from architecture specification)
CREATE TABLE public.products (
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
CREATE INDEX idx_products_updated_at ON public.products(updated_at);
CREATE INDEX idx_products_artg_id ON public.products(artg_id) WHERE artg_id IS NOT NULL;
CREATE INDEX idx_products_pbs ON public.products(pbs) WHERE pbs IS NOT NULL;

-- Reference Data Tables
CREATE TABLE public.organizations (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the organization (integer, unique)"
  name TEXT,                           -- "Name of the organization (string)"
  type TEXT,                           -- "supplier, marketing, medical_professional, other"
  raw_data JSONB
);

CREATE TABLE public.brands (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the brand (integer, unique)"
  name TEXT,                           -- "Name of the brand (string)"
  raw_data JSONB
);

CREATE TABLE public.public_categories (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the public category (integer, unique)"
  name_en TEXT,                        -- "Name of the public category (string, localized)"
  parent INTEGER,                      -- "Id of the parent category (integer)"
  order_index INTEGER,                 -- "Sort order of the public category (integer)"
  raw_data JSONB
);

CREATE TABLE public.product_families (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  raw_data JSONB
);

CREATE TABLE public.active_ingredients (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the active ingredient (integer, unique)"
  name_en TEXT,                        -- "Name of the active ingredient (string, localized)"
  raw_data JSONB
);

CREATE TABLE public.media (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the media item (integer, unique)"
  type TEXT,                           -- "photo" or "link"
  photo_type TEXT,                     -- "packshot, productshot, lifestyle_image, pillshot"
  storage_path TEXT,                   -- Metadata only - no file storage
  raw_data JSONB
);

-- Junction Tables for Many-to-Many Relationships
CREATE TABLE public.product_organizations (
  product_id TEXT NOT NULL,
  organization_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, organization_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (organization_id) REFERENCES public.organizations(id)
);

CREATE TABLE public.product_brands (
  product_id TEXT NOT NULL,
  brand_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, brand_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (brand_id) REFERENCES public.brands(id)
);

CREATE TABLE public.product_categories (
  product_id TEXT NOT NULL,
  category_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, category_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (category_id) REFERENCES public.public_categories(id)
);

CREATE TABLE public.product_media (
  product_id TEXT NOT NULL,
  media_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, media_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (media_id) REFERENCES public.media(id)
);

-- Sync Infrastructure Tables
CREATE TABLE public.sync_state (
  entity_type TEXT PRIMARY KEY,
  last_sync_timestamp BIGINT,
  last_sync_status TEXT,
  sync_count INTEGER DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  current_page INTEGER DEFAULT 0,
  chunk_status TEXT DEFAULT 'pending'
);

CREATE SEQUENCE public.sync_errors_id_seq;
CREATE TABLE public.sync_errors (
  id BIGINT PRIMARY KEY DEFAULT nextval('public.sync_errors_id_seq'),
  sync_type TEXT,
  error_message TEXT,
  error_data JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE SEQUENCE public.deferred_relationships_id_seq;
CREATE TABLE public.deferred_relationships (
  id INTEGER PRIMARY KEY DEFAULT nextval('public.deferred_relationships_id_seq'),
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  relationship_type TEXT NOT NULL,
  relationship_data JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Initialize sync state for all entity types
INSERT INTO public.sync_state (entity_type, last_sync_timestamp, last_sync_status, sync_count, current_page, chunk_status)
VALUES 
  ('products', 0, 'ready', 0, 0, 'pending'),
  ('organizations', 0, 'ready', 0, 0, 'pending'),
  ('brands', 0, 'ready', 0, 0, 'pending'),
  ('public_categories', 0, 'ready', 0, 0, 'pending'),
  ('product_families', 0, 'ready', 0, 0, 'pending'),
  ('active_ingredients', 0, 'ready', 0, 0, 'pending'),
  ('media', 0, 'ready', 0, 0, 'pending');

-- Enable RLS on all tables
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.public_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.active_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.product_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sync_errors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.deferred_relationships ENABLE ROW LEVEL SECURITY;