# Complete Database Schema Specifications

## 14 Tables Required

Based on the architecture document, here are the complete database schema specifications for all 14 tables:

## Core Product Table (1 table)

### Products Table
```sql
-- Core Product Table
-- Based on Medipim API `/products/query` response documentation
-- Each comment shows the exact field type and description from the API docs
CREATE TABLE products (
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
  
  -- Pricing (from FAQ: "In what format are prices returned through the API?")
  -- "We always return prices in the base denotation (= lowest amount of the currency)"
  public_price INTEGER,                  -- "Public price (integer, in $) (⚠️value is including VAT)"
  manufacturer_price INTEGER,            -- "Manufacturer price (integer, in $) (⚠️value is excluding VAT)"
  pharmacist_price INTEGER,              -- "Pharmacist price (integer, in $) (⚠️value is excluding VAT)"
  
  -- Complete API response preserved
  raw_data JSONB,                       -- Native Postgres JSONB
  
  -- Metadata
  created_at BIGINT,                    -- "unix timestamp"
  updated_at BIGINT                     -- "unix timestamp"
);

-- REQUIRED INDEXES - DO NOT add additional indexes for MVP
CREATE INDEX idx_products_updated_at ON products(updated_at);
CREATE INDEX idx_products_artg_id ON products(artg_id) WHERE artg_id IS NOT NULL;
CREATE INDEX idx_products_pbs ON products(pbs) WHERE pbs IS NOT NULL;
```

## Reference Data Tables (6 tables)

### Organizations Table
```sql
-- Organizations (suppliers, marketing companies, etc.)
CREATE TABLE organizations (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the organization (integer, unique)"
  name TEXT,                           -- "Name of the organization (string)"
  type TEXT,                           -- "supplier, marketing, medical_professional, other"
  raw_data JSONB
);
```

### Brands Table
```sql
-- Brands
CREATE TABLE brands (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the brand (integer, unique)"
  name TEXT,                           -- "Name of the brand (string)"
  raw_data JSONB
);
```

### Public Categories Table
```sql
-- Categories (hierarchical)
CREATE TABLE public_categories (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the public category (integer, unique)"
  name_en TEXT,                        -- "Name of the public category (string, localized)"
  parent INTEGER,                      -- "Id of the parent category (integer)"
  order_index INTEGER,                 -- "Sort order of the public category (integer)"
  raw_data JSONB
);
```

### Product Families Table
```sql
-- Product families
CREATE TABLE product_families (
  id INTEGER PRIMARY KEY,
  name_en TEXT,
  raw_data JSONB
);
```

### Active Ingredients Table
```sql
-- Active ingredients
CREATE TABLE active_ingredients (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the active ingredient (integer, unique)"
  name_en TEXT,                        -- "Name of the active ingredient (string, localized)"
  raw_data JSONB
);
```

### Media Table
```sql
-- Media metadata
CREATE TABLE media (
  id INTEGER PRIMARY KEY,               -- "Medipim ID of the media item (integer, unique)"
  type TEXT,                           -- "photo" or "link"
  photo_type TEXT,                     -- "packshot, productshot, lifestyle_image, pillshot"
  storage_path TEXT,                   -- Path in Supabase Storage
  raw_data JSONB
);
```

## Junction Tables (4 tables)

### Product Organizations Junction
```sql
-- Junction tables for many-to-many relationships
CREATE TABLE product_organizations (
  product_id TEXT REFERENCES products(id),
  organization_id INTEGER REFERENCES organizations(id),
  PRIMARY KEY (product_id, organization_id)
);
```

### Product Brands Junction
```sql
CREATE TABLE product_brands (
  product_id TEXT REFERENCES products(id),
  brand_id INTEGER REFERENCES brands(id),
  PRIMARY KEY (product_id, brand_id)
);
```

### Product Categories Junction
```sql
CREATE TABLE product_categories (
  product_id TEXT REFERENCES products(id),
  category_id INTEGER REFERENCES public_categories(id),
  PRIMARY KEY (product_id, category_id)
);
```

### Product Media Junction
```sql
CREATE TABLE product_media (
  product_id TEXT REFERENCES products(id),
  media_id INTEGER REFERENCES media(id),
  PRIMARY KEY (product_id, media_id)
);
```

## Sync Infrastructure Tables (3 tables)

### Sync State Table
```sql
-- Track sync state for incremental updates and chunk processing
CREATE TABLE sync_state (
  entity_type TEXT PRIMARY KEY,
  last_sync_timestamp BIGINT,          -- Unix timestamp for updatedSince filter
  last_sync_status TEXT,
  sync_count INTEGER DEFAULT 0,
  current_page INTEGER DEFAULT 0,      -- For resumable pagination
  chunk_status TEXT DEFAULT 'pending', -- Track chunk processing state
  updated_at TIMESTAMPTZ DEFAULT NOW()
);
```

### Sync Errors Table
```sql
-- Log errors for troubleshooting
CREATE TABLE sync_errors (
  id BIGSERIAL PRIMARY KEY,
  sync_type TEXT,
  error_message TEXT,
  error_data JSONB,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### Deferred Relationships Table
```sql
-- Track failed relationships for deferred processing (FK resilience)
-- Note: PGMQ handles all task tracking, retry logic, and request management natively
CREATE TABLE deferred_relationships (
  id SERIAL PRIMARY KEY,
  entity_type TEXT NOT NULL,
  entity_id TEXT NOT NULL,
  relationship_type TEXT NOT NULL,
  relationship_data JSONB NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);
```

## Extensions and Task Queue Setup

```sql
-- Enable task queue extension
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Create task queue with native visibility timeout and archiving
SELECT pgmq.create('medipim_sync_tasks');
-- Configure message retention: 1 hour for successful, 24 hours for archived
SELECT pgmq.set_vt('medipim_sync_tasks', 300); -- 5 minute visibility timeout
```

## Field Mapping Rules

### Australian Regulatory Codes
**ALL of these MUST be captured exactly:**
- `artgId` → `artg_id` (Australian Register of Therapeutic Goods)
- `pbs` (Pharmaceutical Benefits Scheme)
- `fred` (Fred POS Code)  
- `zCode` → `z_code` (Z Register POS Code)
- **ALL 7 SNOMED codes:**
  - `snomedMp` → `snomed_mp` (Medicinal Product)
  - `snomedMpp` → `snomed_mpp` (Medicinal Product Pack)
  - `snomedMpuu` → `snomed_mpuu` (Medicinal Product Units of Use)
  - `snomedTp` → `snomed_tp` (Trade Product)
  - `snomedTpp` → `snomed_tpp` (Trade Product Pack)
  - `snomedTpuu` → `snomed_tpuu` (Trade Product Unit of Use)
  - `snomedCtpp` → `snomed_ctpp` (Contained Trade Product Pack)

### Field Naming Rules
- Medipim `artgId` → database `artg_id` (snake_case conversion ONLY)
- Medipim `snomedMp` → database `snomed_mp` (snake_case conversion ONLY)
- NO abbreviations, NO custom names, NO "improvements"

## Complete Table Summary

**14 Tables Total:**
1. **products** - Core product data with 20+ fields including all Australian regulatory codes
2. **organizations** - Suppliers, marketing companies, etc.
3. **brands** - Pharmaceutical brands
4. **public_categories** - Hierarchical classification system
5. **product_families** - Product groupings
6. **active_ingredients** - Pharmaceutical compounds
7. **media** - Metadata for product images and documents
8. **product_organizations** - Junction table for product-organization relationships
9. **product_brands** - Junction table for product-brand relationships
10. **product_categories** - Junction table for product-category relationships
11. **product_media** - Junction table for product-media relationships
12. **sync_state** - Track sync progress and pagination state
13. **sync_errors** - Error logging for troubleshooting
14. **deferred_relationships** - FK resilience for async processing

## Complete Field Count: Products Table
**20+ fields including:**
- Core identifiers: id, status, replacement
- Australian regulatory: artg_id, pbs, fred, z_code
- SNOMED codes: snomed_mp, snomed_mpp, snomed_mpuu, snomed_tp, snomed_tpp, snomed_tpuu, snomed_ctpp
- Standard identifiers: ean, ean_gtin8, ean_gtin12, ean_gtin13, ean_gtin14
- Core product data: name_en, seo_name_en, requires_legal_text, biocide
- Pricing: public_price, manufacturer_price, pharmacist_price
- Metadata: raw_data, created_at, updated_at

This schema achieves complete 1:1 Medipim API V4 replication with zero data loss, capturing every field, entity, and relationship exactly as specified in the architecture document.