-- Database Functions for Medipim Sync System
-- Applied via previous apply_migration calls

-- Build Medipim API request body based on task requirements
CREATE OR REPLACE FUNCTION build_medipim_request_body(task_data JSONB)
RETURNS JSONB AS $$
DECLARE
  entity_type TEXT;
  sync_type TEXT;
  page_no INTEGER;
  sync_state_record RECORD;
  request_body JSONB;
BEGIN
  entity_type := task_data->>'entity_type';
  sync_type := task_data->>'sync_type';
  page_no := COALESCE((task_data->>'page_no')::int, 0);
  
  -- Get current sync state for incremental filtering
  SELECT * INTO sync_state_record FROM sync_state WHERE sync_state.entity_type = entity_type;
  
  -- Base request structure
  request_body := jsonb_build_object(
    'sorting', jsonb_build_object('id', jsonb_build_object('direction', 'ASC')),
    'page', jsonb_build_object(
      'no', page_no,
      'size', CASE 
        WHEN entity_type IN ('products', 'media') THEN 100
        ELSE 250  -- Reference data can use larger pages
      END
    )
  );
  
  -- Add entity-specific filters with proper "and" operator for multiple filters
  IF entity_type = 'products' THEN
    IF sync_type = 'incremental' AND sync_state_record.last_sync_timestamp IS NOT NULL THEN
      -- Use "and" operator for combined status + updatedSince filters
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('and', jsonb_build_array(
          jsonb_build_object('status', 'active'),
          jsonb_build_object('updatedSince', sync_state_record.last_sync_timestamp)
        )));
    ELSE
      -- Single status filter only
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('status', 'active'));
    END IF;
  ELSIF entity_type = 'media' THEN
    IF sync_type = 'incremental' AND sync_state_record.last_sync_timestamp IS NOT NULL THEN
      -- Use "and" operator for combined published + updatedSince filters
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('and', jsonb_build_array(
          jsonb_build_object('published', true),
          jsonb_build_object('updatedSince', sync_state_record.last_sync_timestamp)
        )));
    ELSE
      -- Single published filter only
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('published', true));
    END IF;
  END IF;
  
  RETURN request_body;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- Store entity data with exact field mapping
CREATE OR REPLACE FUNCTION store_entity_data(entity_type TEXT, item_data JSONB)
RETURNS void AS $$
BEGIN
  CASE entity_type
    WHEN 'products' THEN
      -- Map ALL 20+ product fields exactly as specified
      INSERT INTO products (
        id, status, replacement,
        artg_id, pbs, fred, z_code,
        snomed_mp, snomed_mpp, snomed_mpuu, snomed_tp, snomed_tpp, snomed_tpuu, snomed_ctpp,
        ean, ean_gtin8, ean_gtin12, ean_gtin13, ean_gtin14,
        name_en, seo_name_en, requires_legal_text, biocide,
        public_price, manufacturer_price, pharmacist_price,
        raw_data, created_at, updated_at
      ) VALUES (
        item_data->>'id',
        item_data->>'status',
        item_data->>'replacement',
        item_data->>'artgId',           -- Australian identifiers
        item_data->>'pbs',
        item_data->>'fred',
        item_data->>'zCode',
        item_data->>'snomedMp',         -- All 7 SNOMED codes
        item_data->>'snomedMpp',
        item_data->>'snomedMpuu',
        item_data->>'snomedTp',
        item_data->>'snomedTpp',
        item_data->>'snomedTpuu',
        item_data->>'snomedCtpp',
        ARRAY(SELECT jsonb_array_elements_text(item_data->'ean')),    -- EAN array handling
        item_data->>'eanGtin8',
        item_data->>'eanGtin12', 
        item_data->>'eanGtin13',
        item_data->>'eanGtin14',
        item_data->'name'->>'en',       -- Localized fields
        item_data->'seoName'->>'en',
        (item_data->>'requiresLegalText')::boolean,
        (item_data->>'biocide')::boolean,
        (item_data->>'publicPrice')::integer,      -- Prices in cents
        (item_data->>'manufacturerPrice')::integer,
        (item_data->>'pharmacistPrice')::integer,
        item_data,                      -- Complete raw response
        (item_data->'meta'->>'createdAt')::bigint,
        (item_data->'meta'->>'updatedAt')::bigint
      ) ON CONFLICT (id) DO UPDATE SET
        status = EXCLUDED.status,
        replacement = EXCLUDED.replacement,
        artg_id = EXCLUDED.artg_id,
        pbs = EXCLUDED.pbs,
        fred = EXCLUDED.fred,
        z_code = EXCLUDED.z_code,
        snomed_mp = EXCLUDED.snomed_mp,
        snomed_mpp = EXCLUDED.snomed_mpp,
        snomed_mpuu = EXCLUDED.snomed_mpuu,
        snomed_tp = EXCLUDED.snomed_tp,
        snomed_tpp = EXCLUDED.snomed_tpp,
        snomed_tpuu = EXCLUDED.snomed_tpuu,
        snomed_ctpp = EXCLUDED.snomed_ctpp,
        ean = EXCLUDED.ean,
        ean_gtin8 = EXCLUDED.ean_gtin8,
        ean_gtin12 = EXCLUDED.ean_gtin12,
        ean_gtin13 = EXCLUDED.ean_gtin13,
        ean_gtin14 = EXCLUDED.ean_gtin14,
        name_en = EXCLUDED.name_en,
        seo_name_en = EXCLUDED.seo_name_en,
        requires_legal_text = EXCLUDED.requires_legal_text,
        biocide = EXCLUDED.biocide,
        public_price = EXCLUDED.public_price,
        manufacturer_price = EXCLUDED.manufacturer_price,
        pharmacist_price = EXCLUDED.pharmacist_price,
        raw_data = EXCLUDED.raw_data,
        created_at = EXCLUDED.created_at,
        updated_at = EXCLUDED.updated_at;
      
      -- Process product relationships
      PERFORM store_product_relationships(item_data->>'id', item_data);
      
    WHEN 'organizations' THEN
      INSERT INTO organizations (id, name, type, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        item_data->>'type',
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        type = EXCLUDED.type,
        raw_data = EXCLUDED.raw_data;
        
    WHEN 'brands' THEN
      INSERT INTO brands (id, name, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name = EXCLUDED.name,
        raw_data = EXCLUDED.raw_data;
        
    WHEN 'public_categories' THEN
      -- Insert category with FK resilience for parent relationship
      INSERT INTO public_categories (id, name_en, parent, order_index, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        CASE 
          WHEN item_data->>'parent' IS NOT NULL 
               AND (item_data->>'parent')::integer != (item_data->>'id')::integer
               AND EXISTS (SELECT 1 FROM public_categories WHERE id = (item_data->>'parent')::integer)
          THEN (item_data->>'parent')::integer
          ELSE NULL -- Will be updated later by repair function
        END,
        (item_data->>'orderIndex')::integer,
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name_en = EXCLUDED.name_en,
        parent = EXCLUDED.parent,
        order_index = EXCLUDED.order_index,
        raw_data = EXCLUDED.raw_data;
        
    WHEN 'product_families' THEN
      INSERT INTO product_families (id, name_en, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name_en = EXCLUDED.name_en,
        raw_data = EXCLUDED.raw_data;
        
    WHEN 'active_ingredients' THEN
      INSERT INTO active_ingredients (id, name_en, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name_en = EXCLUDED.name_en,
        raw_data = EXCLUDED.raw_data;
        
    WHEN 'media' THEN
      INSERT INTO media (id, type, photo_type, storage_path, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        item_data->>'type',
        item_data->>'photoType',
        NULL,  -- Metadata-only approach
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        type = EXCLUDED.type,
        photo_type = EXCLUDED.photo_type,
        raw_data = EXCLUDED.raw_data;
  END CASE;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;