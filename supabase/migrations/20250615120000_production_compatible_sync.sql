-- Production Compatible Medipim Sync Migration
-- Works with existing production schema, ensures Git repository matches production exactly
-- Migration timestamp: 20250615120000 (after existing: 20250614102727, 20250614102916)

-- Enable required extensions (idempotent)
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net; 
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Create PGMQ task queue if not exists (idempotent)
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pgmq.list_queues() WHERE queue_name = 'medipim_sync_tasks') THEN
    PERFORM pgmq.create('medipim_sync_tasks');
  END IF;
END $$;

-- Ensure all tables exist with exact schema (idempotent)
CREATE TABLE IF NOT EXISTS public.products (
  -- Core identifiers
  id TEXT PRIMARY KEY,
  status TEXT,
  replacement TEXT,
  
  -- Australian regulatory identifiers
  artg_id TEXT,
  pbs TEXT,
  fred TEXT,
  z_code TEXT,
  
  -- SNOMED codes (all 7 required for AU)
  snomed_mp TEXT,
  snomed_mpp TEXT,
  snomed_mpuu TEXT,
  snomed_tp TEXT,
  snomed_tpp TEXT,
  snomed_tpuu TEXT,
  snomed_ctpp TEXT,
  
  -- Standard identifiers
  ean TEXT[],
  ean_gtin8 TEXT,
  ean_gtin12 TEXT,
  ean_gtin13 TEXT,
  ean_gtin14 TEXT,
  
  -- Core product data
  name_en TEXT,
  seo_name_en TEXT,
  requires_legal_text BOOLEAN,
  biocide BOOLEAN,
  
  -- Pricing
  public_price INTEGER,
  manufacturer_price INTEGER,
  pharmacist_price INTEGER,
  
  -- Raw data preservation
  raw_data JSONB,
  
  -- Metadata
  created_at BIGINT,
  updated_at BIGINT
);

-- Ensure required indexes exist (idempotent)
CREATE INDEX IF NOT EXISTS idx_products_updated_at ON public.products(updated_at);
CREATE INDEX IF NOT EXISTS idx_products_artg_id ON public.products(artg_id) WHERE artg_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_products_pbs ON public.products(pbs) WHERE pbs IS NOT NULL;

-- Reference Data Tables (idempotent)
CREATE TABLE IF NOT EXISTS public.organizations (
  id INTEGER PRIMARY KEY,
  name TEXT,
  type TEXT,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public.brands (
  id INTEGER PRIMARY KEY,
  name TEXT,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public.public_categories (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  parent INTEGER,
  order_index INTEGER,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public.product_families (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public.active_ingredients (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  raw_data JSONB
);

CREATE TABLE IF NOT EXISTS public.media (
  id INTEGER PRIMARY KEY,
  type TEXT,
  photo_type TEXT,
  storage_path TEXT,
  raw_data JSONB
);

-- Junction Tables (idempotent)
CREATE TABLE IF NOT EXISTS public.product_organizations (
  product_id TEXT NOT NULL,
  organization_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, organization_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (organization_id) REFERENCES public.organizations(id)
);

CREATE TABLE IF NOT EXISTS public.product_brands (
  product_id TEXT NOT NULL,
  brand_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, brand_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (brand_id) REFERENCES public.brands(id)
);

CREATE TABLE IF NOT EXISTS public.product_categories (
  product_id TEXT NOT NULL,
  category_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, category_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (category_id) REFERENCES public.public_categories(id)
);

CREATE TABLE IF NOT EXISTS public.product_media (
  product_id TEXT NOT NULL,
  media_id INTEGER NOT NULL,
  PRIMARY KEY (product_id, media_id),
  FOREIGN KEY (product_id) REFERENCES public.products(id),
  FOREIGN KEY (media_id) REFERENCES public.media(id)
);

-- Sync Infrastructure Tables (idempotent)
CREATE TABLE IF NOT EXISTS public.sync_state (
  entity_type TEXT PRIMARY KEY,
  last_sync_timestamp BIGINT,
  last_sync_status TEXT,
  sync_count INTEGER DEFAULT 0,
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  current_page INTEGER DEFAULT 0,
  chunk_status TEXT DEFAULT 'pending'
);

-- Create sequences if they don't exist
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'sync_errors_id_seq') THEN
    CREATE SEQUENCE public.sync_errors_id_seq;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.sync_errors (
  id BIGINT PRIMARY KEY DEFAULT nextval('public.sync_errors_id_seq'),
  sync_type TEXT,
  error_message TEXT,
  error_data JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_sequences WHERE schemaname = 'public' AND sequencename = 'deferred_relationships_id_seq') THEN
    CREATE SEQUENCE public.deferred_relationships_id_seq;
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.deferred_relationships (
  id INTEGER PRIMARY KEY DEFAULT nextval('public.deferred_relationships_id_seq'),
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  relationship_type TEXT NOT NULL,
  relationship_data JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Initialize sync state for missing entity types (idempotent)
INSERT INTO public.sync_state (entity_type, last_sync_timestamp, last_sync_status, sync_count, current_page, chunk_status)
VALUES 
  ('products', 0, 'ready', 0, 0, 'pending'),
  ('organizations', 0, 'ready', 0, 0, 'pending'),
  ('brands', 0, 'ready', 0, 0, 'pending'),
  ('public_categories', 0, 'ready', 0, 0, 'pending'),
  ('product_families', 0, 'ready', 0, 0, 'pending'),
  ('active_ingredients', 0, 'ready', 0, 0, 'pending'),
  ('media', 0, 'ready', 0, 0, 'pending')
ON CONFLICT (entity_type) DO NOTHING;

-- Ensure RLS is enabled on all tables (idempotent)
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

-- Add comment to confirm Git repository synchronization
COMMENT ON SCHEMA public IS 'Medipim AU Importer v3 MVP - Git repository synchronized with production 2025-06-15';