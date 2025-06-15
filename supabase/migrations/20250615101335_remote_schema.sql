

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






COMMENT ON SCHEMA "public" IS 'Medipim AU Importer v3 MVP - Production compatibility verified 2025-06-15';



CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgmq" WITH SCHEMA "pgmq";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  entity_type_param TEXT;
  sync_type TEXT;
  page_no INTEGER;
  sync_state_record RECORD;
  request_body JSONB;
BEGIN
  entity_type_param := task_data->>'entity_type';
  sync_type := task_data->>'sync_type';
  page_no := COALESCE((task_data->>'page_no')::int, 0);
  
  -- Get current sync state for incremental filtering
  SELECT * INTO sync_state_record FROM sync_state WHERE sync_state.entity_type = entity_type_param;
  
  -- Base request structure with FIXED sorting format
  request_body := jsonb_build_object(
    'sorting', jsonb_build_object('id', jsonb_build_object('direction', 'ASC')),
    'page', jsonb_build_object(
      'no', page_no,
      'size', CASE 
        WHEN entity_type_param IN ('products', 'media') THEN 100
        ELSE 250  -- Reference data can use larger pages
      END
    )
  );
  
  -- Add entity-specific filters
  IF entity_type_param = 'products' THEN
    IF sync_type = 'incremental' AND sync_state_record.last_sync_timestamp IS NOT NULL THEN
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('and', jsonb_build_array(
          jsonb_build_object('status', 'active'),
          jsonb_build_object('updatedSince', sync_state_record.last_sync_timestamp)
        )));
    ELSE
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('status', 'active'));
    END IF;
  ELSIF entity_type_param = 'media' THEN
    IF sync_type = 'incremental' AND sync_state_record.last_sync_timestamp IS NOT NULL THEN
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('and', jsonb_build_array(
          jsonb_build_object('published', true),
          jsonb_build_object('updatedSince', sync_state_record.last_sync_timestamp)
        )));
    ELSE
      request_body := jsonb_set(request_body, '{filter}', 
        jsonb_build_object('published', true));
    END IF;
  END IF;
  
  RETURN request_body;
END;
$$;


ALTER FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."pgmq_send"("queue_name" "text", "message" "jsonb") RETURNS bigint
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  RETURN pgmq.send(queue_name, message);
END;
$$;


ALTER FUNCTION "public"."pgmq_send"("queue_name" "text", "message" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_deferred_relationships"() RETURNS integer
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  deferred_record RECORD;
  processed_count INTEGER := 0;
  relationship_id INTEGER;
BEGIN
  FOR deferred_record IN 
    SELECT * FROM deferred_relationships ORDER BY created_at
  LOOP
    CASE deferred_record.relationship_type
      WHEN 'organization' THEN
        relationship_id := (deferred_record.relationship_data->>'id')::integer;
        IF EXISTS (SELECT 1 FROM organizations WHERE id = relationship_id) THEN
          INSERT INTO product_organizations (product_id, organization_id)
          VALUES (deferred_record.entity_id, relationship_id)
          ON CONFLICT DO NOTHING;
          DELETE FROM deferred_relationships WHERE id = deferred_record.id;
          processed_count := processed_count + 1;
        END IF;
      WHEN 'brand' THEN
        relationship_id := (deferred_record.relationship_data->>'id')::integer;
        IF EXISTS (SELECT 1 FROM brands WHERE id = relationship_id) THEN
          INSERT INTO product_brands (product_id, brand_id)
          VALUES (deferred_record.entity_id, relationship_id)
          ON CONFLICT DO NOTHING;
          DELETE FROM deferred_relationships WHERE id = deferred_record.id;
          processed_count := processed_count + 1;
        END IF;
      WHEN 'category' THEN
        relationship_id := (deferred_record.relationship_data->>'id')::integer;
        IF EXISTS (SELECT 1 FROM public_categories WHERE id = relationship_id) THEN
          INSERT INTO product_categories (product_id, category_id)
          VALUES (deferred_record.entity_id, relationship_id)
          ON CONFLICT DO NOTHING;
          DELETE FROM deferred_relationships WHERE id = deferred_record.id;
          processed_count := processed_count + 1;
        END IF;
      WHEN 'media' THEN
        relationship_id := (deferred_record.relationship_data->>'id')::integer;
        IF EXISTS (SELECT 1 FROM media WHERE id = relationship_id) THEN
          INSERT INTO product_media (product_id, media_id)
          VALUES (deferred_record.entity_id, relationship_id)
          ON CONFLICT DO NOTHING;
          DELETE FROM deferred_relationships WHERE id = deferred_record.id;
          processed_count := processed_count + 1;
        END IF;
    END CASE;
  END LOOP;
  
  RETURN processed_count;
END;
$$;


ALTER FUNCTION "public"."process_deferred_relationships"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_sync_responses"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  response_record RECORD;
  api_response JSONB;
  result_item JSONB;
  total_processed INTEGER := 0;
  max_responses_per_batch INTEGER := 5;
BEGIN
  -- Process completed HTTP requests directly from pg_net
  FOR response_record IN 
    SELECT 
      nr.id as request_id,
      nr.content, 
      nr.status_code,
      nr.created
    FROM net._http_response nr 
    WHERE nr.status_code IS NOT NULL
      AND nr.created > NOW() - INTERVAL '5 minutes'  -- Only recent responses
      AND nr.status_code = 200  -- Only successful responses
      AND NOT EXISTS (
        SELECT 1 FROM sync_errors 
        WHERE error_data->>'request_id' = nr.id::text
          AND sync_type = 'response_processed'
      )
    ORDER BY nr.created DESC
    LIMIT max_responses_per_batch
  LOOP
    BEGIN
      api_response := response_record.content::jsonb;
      
      -- Process results if they exist
      IF api_response ? 'results' THEN
        FOR result_item IN SELECT * FROM jsonb_array_elements(api_response->'results')
        LOOP
          -- Determine entity type from the response structure
          DECLARE
            entity_type TEXT;
          BEGIN
            entity_type := CASE 
              WHEN result_item ? 'artgId' THEN 'products'
              WHEN result_item ? 'tradingName' THEN 'organizations'
              WHEN result_item ? 'brandName' THEN 'brands'
              WHEN result_item ? 'categoryName' AND result_item ? 'parentId' THEN 'public_categories'
              WHEN result_item ? 'familyName' THEN 'product_families'
              WHEN result_item ? 'ingredientName' THEN 'active_ingredients'
              WHEN result_item ? 'mediaUrl' THEN 'media'
              ELSE 'unknown'
            END;
            
            -- Store data with exact field mapping
            IF entity_type != 'unknown' THEN
              PERFORM store_entity_data(entity_type, result_item);
              total_processed := total_processed + 1;
            END IF;
          END;
        END LOOP;
      END IF;
      
      -- Mark response as processed
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processed',
        'Response processed successfully',
        jsonb_build_object(
          'request_id', response_record.request_id,
          'processed_at', NOW(),
          'items_processed', total_processed
        )
      );
      
    EXCEPTION WHEN OTHERS THEN
      -- Log processing errors
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processing_error',
        'Error processing response: ' || SQLERRM,
        jsonb_build_object(
          'request_id', response_record.request_id,
          'status_code', response_record.status_code,
          'error', SQLERRM
        )
      );
    END;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."process_sync_responses"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_sync_task"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  task_record RECORD;
  request_id BIGINT;
  auth_header TEXT;
  request_body JSONB;
BEGIN
  -- Build Basic Auth header from environment
  auth_header := 'Basic ' || encode(
    current_setting('app.medipim_api_key_id', true) || ':' || 
    current_setting('app.medipim_api_key', true), 'base64'
  );
  
  -- Pop next atomic task from queue with 5-minute visibility timeout
  SELECT * INTO task_record FROM pgmq.pop('medipim_sync_tasks', 300);
  
  IF task_record IS NOT NULL THEN
    -- Build request body based on task type
    request_body := build_medipim_request_body(task_record.message);
    
    -- Make async HTTP request via pg_net (no timeout constraint)
    SELECT net.http_post(
      url := 'https://api.au.medipim.com/v4/' || 
             (task_record.message->>'entity_type') || '/query',
      headers := jsonb_build_object(
        'Authorization', auth_header,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 30000  -- Single request timeout only
    ) INTO request_id;
    
    -- PGMQ handles all task tracking natively
    -- No additional tracking needed - pg_net responses processed directly
  END IF;
END;
$$;


ALTER FUNCTION "public"."process_sync_task"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."process_sync_tasks_batch"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  task_record RECORD;
  request_id BIGINT;
  auth_header TEXT;
  request_body JSONB;
  endpoint_url TEXT;
  tasks_processed INTEGER := 0;
  max_tasks_per_batch INTEGER := 3; -- Process 3 tasks per execution (optimized)
BEGIN
  -- Build Basic Auth header with hardcoded values (for async MVP)
  auth_header := 'Basic ' || encode('10:6e1afc83cb7c15429f3c06bbfb5828911d8dd537', 'base64');
  
  -- Process multiple tasks in batch with native PGMQ retry
  WHILE tasks_processed < max_tasks_per_batch LOOP
    -- Pop next atomic task from queue with native PGMQ handling
    SELECT * INTO task_record FROM pgmq.pop('medipim_sync_tasks');
    
    EXIT WHEN task_record IS NULL;
    
    -- Build request body based on task type
    request_body := build_medipim_request_body(task_record.message);
    
    -- Build correct endpoint URL
    endpoint_url := 'https://api.au.medipim.com/v4/' || 
      CASE task_record.message->>'entity_type'
        WHEN 'active_ingredients' THEN 'active-ingredients'
        WHEN 'product_families' THEN 'product-families'
        WHEN 'public_categories' THEN 'public-categories'
        ELSE task_record.message->>'entity_type'
      END || '/query';
    
    -- Make async HTTP request via pg_net
    SELECT net.http_post(
      url := endpoint_url,
      headers := jsonb_build_object(
        'Authorization', auth_header,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 30000
    ) INTO request_id;
    
    -- Log request for debugging (replace sync_requests tracking)
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
      'http_request_sent',
      'HTTP request sent successfully',
      jsonb_build_object(
        'request_id', request_id,
        'entity_type', task_record.message->>'entity_type',
        'page_no', COALESCE((task_record.message->>'page_no')::int, 0),
        'endpoint_url', endpoint_url,
        'sent_at', NOW()
      )
    );
    
    tasks_processed := tasks_processed + 1;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."process_sync_tasks_batch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_sync_tasks"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  sync_states RECORD;
  tasks_queued INTEGER := 0;
  reference_entities TEXT[] := ARRAY['organizations', 'brands', 'public_categories', 'product_families', 'active_ingredients'];
  entity TEXT;
  state RECORD;
  start_page INTEGER;
BEGIN
  -- Queue reference data chunks (full dumps required)
  FOREACH entity IN ARRAY reference_entities
  LOOP
    SELECT * INTO state FROM sync_state WHERE entity_type = entity;
    start_page := CASE 
      WHEN state.chunk_status = 'pending' THEN COALESCE(state.current_page, 0)
      ELSE 0
    END;
    
    -- Queue next chunk for this entity
    PERFORM pgmq.send(
      'medipim_sync_tasks',
      jsonb_build_object(
        'entity_type', entity,
        'page_no', start_page,
        'sync_type', 'reference_chunk'
      )
    );
    tasks_queued := tasks_queued + 1;
  END LOOP;
  
  -- Queue incremental updates for products and media
  PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object('entity_type', 'products', 'sync_type', 'incremental'));
  PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object('entity_type', 'media', 'sync_type', 'incremental'));
  tasks_queued := tasks_queued + 2;
  
  RETURN 'Sync tasks queued for async processing: ' || tasks_queued || ' tasks';
END;
$$;


ALTER FUNCTION "public"."queue_sync_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_sync_tasks_aggressive"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  sync_states RECORD;
  tasks_queued INTEGER := 0;
  reference_entities TEXT[] := ARRAY['organizations', 'brands', 'public_categories', 'product_families', 'active_ingredients'];
  entity TEXT;
  state RECORD;
  start_page INTEGER;
  pages_to_queue INTEGER;
  products_state RECORD;
  media_state RECORD;
BEGIN
  -- Queue multiple pages per entity for faster processing
  FOREACH entity IN ARRAY reference_entities
  LOOP
    SELECT * INTO state FROM sync_state WHERE entity_type = entity;
    start_page := CASE 
      WHEN state.chunk_status = 'pending' THEN COALESCE(state.current_page, 0)
      ELSE 0
    END;
    
    -- Queue next 3 pages for this entity (aggressive processing)
    pages_to_queue := CASE 
      WHEN entity IN ('organizations', 'brands') THEN 3  -- High-volume entities
      ELSE 2  -- Lower-volume entities
    END;
    
    FOR i IN 0..pages_to_queue-1 LOOP
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity,
          'page_no', start_page + i,
          'sync_type', 'reference_chunk'
        )
      );
      tasks_queued := tasks_queued + 1;
    END LOOP;
  END LOOP;
  
  -- Queue products pages based on current sync state (FIX: was hardcoded 0..2)
  SELECT * INTO products_state FROM sync_state WHERE entity_type = 'products';
  start_page := CASE 
    WHEN products_state.chunk_status = 'pending' THEN COALESCE(products_state.current_page, 0)
    ELSE 0
  END;
  
  -- Queue next 3 pages for products to continue pagination
  FOR i IN 0..2 LOOP
    PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object(
      'entity_type', 'products', 
      'sync_type', 'incremental', 
      'page_no', start_page + i
    ));
    tasks_queued := tasks_queued + 1;
  END LOOP;
  
  -- Queue media pages based on current sync state (FIX: was hardcoded 0..2)
  SELECT * INTO media_state FROM sync_state WHERE entity_type = 'media';
  start_page := CASE 
    WHEN media_state.chunk_status = 'pending' THEN COALESCE(media_state.current_page, 0)
    ELSE 0
  END;
  
  -- Queue next 3 pages for media
  FOR i IN 0..2 LOOP
    PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object(
      'entity_type', 'media', 
      'sync_type', 'incremental', 
      'page_no', start_page + i
    ));
    tasks_queued := tasks_queued + 1;
  END LOOP;
  
  RETURN 'Aggressive sync tasks queued: ' || tasks_queued || ' tasks';
END;
$$;


ALTER FUNCTION "public"."queue_sync_tasks_aggressive"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repair_category_parent_relationships"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  -- Update categories where parent is NULL but raw_data contains a valid parent
  UPDATE public_categories 
  SET parent = (raw_data->>'parent')::integer
  WHERE parent IS NULL 
    AND raw_data->>'parent' IS NOT NULL 
    AND (raw_data->>'parent')::integer != id
    AND EXISTS (
      SELECT 1 FROM public_categories pc2 
      WHERE pc2.id = (public_categories.raw_data->>'parent')::integer
    );
END;
$$;


ALTER FUNCTION "public"."repair_category_parent_relationships"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."repair_product_relationships"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  product_record RECORD;
BEGIN
  FOR product_record IN SELECT id, raw_data FROM products
  LOOP
    PERFORM store_product_relationships(product_record.id, product_record.raw_data);
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."repair_product_relationships"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  ean_array TEXT[];
  parent_category_id INTEGER;
BEGIN
  CASE entity_type
    WHEN 'products' THEN
      -- Extract EAN array properly from JSONB
      SELECT ARRAY(SELECT jsonb_array_elements_text(item_data->'ean')) INTO ean_array;
      
      -- VALIDATION: Map ALL 20+ product fields exactly as specified
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
        ean_array,                      -- Fixed EAN array handling
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
      
      -- Process product relationships with FK validation
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
      -- Handle parent category FK constraint gracefully
      parent_category_id := (item_data->>'parent')::integer;
      
      -- Only set parent if it exists, otherwise set to NULL for later processing
      IF parent_category_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public_categories WHERE id = parent_category_id) THEN
        parent_category_id := NULL;
      END IF;
      
      INSERT INTO public_categories (id, name_en, parent, order_index, raw_data)
      VALUES (
        (item_data->>'id')::integer,
        COALESCE(item_data->'name'->>'en', item_data->>'name'),
        parent_category_id,  -- Resilient parent handling
        (item_data->>'orderIndex')::integer,
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        name_en = EXCLUDED.name_en,
        parent = CASE 
          -- Only update parent if the referenced parent exists
          WHEN EXCLUDED.parent IS NULL THEN EXCLUDED.parent
          WHEN EXISTS (SELECT 1 FROM public_categories WHERE id = EXCLUDED.parent) THEN EXCLUDED.parent
          ELSE public_categories.parent  -- Keep current parent if new one doesn't exist
        END,
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
        NULL,  -- Will be set when media is downloaded
        item_data
      ) ON CONFLICT (id) DO UPDATE SET
        type = EXCLUDED.type,
        photo_type = EXCLUDED.photo_type,
        raw_data = EXCLUDED.raw_data;
  END CASE;
END;
$$;


ALTER FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  org_item JSONB;
  brand_item JSONB;
  category_item JSONB;
  media_item JSONB;
  category_id INTEGER;
  brand_id INTEGER;
  org_id INTEGER;
  media_id INTEGER;
BEGIN
  -- Clear existing relationships for this product
  DELETE FROM product_organizations WHERE product_organizations.product_id = store_product_relationships.product_id;
  DELETE FROM product_brands WHERE product_brands.product_id = store_product_relationships.product_id;
  DELETE FROM product_categories WHERE product_categories.product_id = store_product_relationships.product_id;
  DELETE FROM product_media WHERE product_media.product_id = store_product_relationships.product_id;
  
  -- Clear any previous deferred relationships for this product
  DELETE FROM deferred_relationships WHERE entity_id = product_id;
  
  -- Insert organization relationships (check if org exists)
  FOR org_item IN SELECT * FROM jsonb_array_elements(product_data->'organizations')
  LOOP
    org_id := (org_item->>'id')::integer;
    IF EXISTS (SELECT 1 FROM organizations WHERE id = org_id) THEN
      INSERT INTO product_organizations (product_id, organization_id)
      VALUES (store_product_relationships.product_id, org_id)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Defer this relationship for later processing
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('products', product_id, 'organization', org_item);
    END IF;
  END LOOP;
  
  -- Insert brand relationships (check if brand exists)
  FOR brand_item IN SELECT * FROM jsonb_array_elements(product_data->'brands')
  LOOP
    brand_id := (brand_item->>'id')::integer;
    IF EXISTS (SELECT 1 FROM brands WHERE id = brand_id) THEN
      INSERT INTO product_brands (product_id, brand_id)
      VALUES (store_product_relationships.product_id, brand_id)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Defer this relationship for later processing
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('products', product_id, 'brand', brand_item);
    END IF;
  END LOOP;
  
  -- Insert category relationships (check if category exists)
  FOR category_item IN SELECT * FROM jsonb_array_elements(product_data->'publicCategories')
  LOOP
    category_id := (category_item->>'id')::integer;
    IF EXISTS (SELECT 1 FROM public_categories WHERE id = category_id) THEN
      INSERT INTO product_categories (product_id, category_id)
      VALUES (store_product_relationships.product_id, category_id)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Defer this relationship for later processing
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('products', product_id, 'category', category_item);
    END IF;
  END LOOP;
  
  -- Insert media relationships (check if media exists)
  FOR media_item IN SELECT * FROM jsonb_array_elements(product_data->'photos')
  LOOP
    media_id := (media_item->>'id')::integer;
    IF EXISTS (SELECT 1 FROM media WHERE id = media_id) THEN
      INSERT INTO product_media (product_id, media_id)
      VALUES (store_product_relationships.product_id, media_id)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Defer this relationship for later processing
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('products', product_id, 'media', media_item);
    END IF;
  END LOOP;
END;
$$;


ALTER FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_sync_progress"("entity_type" "text", "completed_page" integer, "has_more_pages" boolean) RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF has_more_pages THEN
    -- Update current page and queue next chunk
    UPDATE sync_state 
    SET current_page = completed_page + 1,
        chunk_status = 'pending',
        updated_at = NOW()
    WHERE sync_state.entity_type = update_sync_progress.entity_type;
    
    -- Queue next page for processing
    PERFORM pgmq.send(
      'medipim_sync_tasks',
      jsonb_build_object(
        'entity_type', entity_type,
        'page_no', completed_page + 1,
        'sync_type', CASE 
          WHEN entity_type IN ('products', 'media') THEN 'incremental'
          ELSE 'reference_chunk'
        END
      )
    );
  ELSE
    -- Mark entity sync as complete
    UPDATE sync_state 
    SET last_sync_timestamp = extract(epoch from now())::bigint,
        last_sync_status = 'success',
        current_page = 0,
        chunk_status = 'completed',
        sync_count = COALESCE(sync_count, 0) + 1,
        updated_at = NOW()
    WHERE sync_state.entity_type = update_sync_progress.entity_type;
    
    -- Repair relationships after specific entity types complete
    IF entity_type = 'public_categories' THEN
      -- Repair category parent relationships after categories are synced
      PERFORM repair_category_parent_relationships();
    ELSIF entity_type = 'products' THEN
      -- Repair product relationships after products are synced
      PERFORM repair_product_relationships();
    END IF;
  END IF;
END;
$$;


ALTER FUNCTION "public"."update_sync_progress"("entity_type" "text", "completed_page" integer, "has_more_pages" boolean) OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."active_ingredients" (
    "id" integer NOT NULL,
    "name_en" "text",
    "raw_data" "jsonb"
);


ALTER TABLE "public"."active_ingredients" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."brands" (
    "id" integer NOT NULL,
    "name" "text",
    "raw_data" "jsonb"
);


ALTER TABLE "public"."brands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."deferred_relationships" (
    "id" integer NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "text" NOT NULL,
    "relationship_type" "text" NOT NULL,
    "relationship_data" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."deferred_relationships" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."deferred_relationships_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."deferred_relationships_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."deferred_relationships_id_seq" OWNED BY "public"."deferred_relationships"."id";



CREATE TABLE IF NOT EXISTS "public"."media" (
    "id" integer NOT NULL,
    "type" "text",
    "photo_type" "text",
    "storage_path" "text",
    "raw_data" "jsonb"
);


ALTER TABLE "public"."media" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizations" (
    "id" integer NOT NULL,
    "name" "text",
    "type" "text",
    "raw_data" "jsonb"
);


ALTER TABLE "public"."organizations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_brands" (
    "product_id" "text" NOT NULL,
    "brand_id" integer NOT NULL
);


ALTER TABLE "public"."product_brands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_categories" (
    "product_id" "text" NOT NULL,
    "category_id" integer NOT NULL
);


ALTER TABLE "public"."product_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_families" (
    "id" integer NOT NULL,
    "name_en" "text",
    "raw_data" "jsonb"
);


ALTER TABLE "public"."product_families" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_media" (
    "product_id" "text" NOT NULL,
    "media_id" integer NOT NULL
);


ALTER TABLE "public"."product_media" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."product_organizations" (
    "product_id" "text" NOT NULL,
    "organization_id" integer NOT NULL
);


ALTER TABLE "public"."product_organizations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."products" (
    "id" "text" NOT NULL,
    "status" "text",
    "replacement" "text",
    "artg_id" "text",
    "pbs" "text",
    "fred" "text",
    "z_code" "text",
    "snomed_mp" "text",
    "snomed_mpp" "text",
    "snomed_mpuu" "text",
    "snomed_tp" "text",
    "snomed_tpp" "text",
    "snomed_tpuu" "text",
    "snomed_ctpp" "text",
    "ean" "text"[],
    "ean_gtin8" "text",
    "ean_gtin12" "text",
    "ean_gtin13" "text",
    "ean_gtin14" "text",
    "name_en" "text",
    "seo_name_en" "text",
    "requires_legal_text" boolean,
    "biocide" boolean,
    "public_price" integer,
    "manufacturer_price" integer,
    "pharmacist_price" integer,
    "raw_data" "jsonb",
    "created_at" bigint,
    "updated_at" bigint
);


ALTER TABLE "public"."products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."public_categories" (
    "id" integer NOT NULL,
    "name_en" "text",
    "parent" integer,
    "order_index" integer,
    "raw_data" "jsonb"
);


ALTER TABLE "public"."public_categories" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sync_errors" (
    "id" bigint NOT NULL,
    "sync_type" "text",
    "error_message" "text",
    "error_data" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."sync_errors" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."sync_errors_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."sync_errors_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."sync_errors_id_seq" OWNED BY "public"."sync_errors"."id";



CREATE TABLE IF NOT EXISTS "public"."sync_state" (
    "entity_type" "text" NOT NULL,
    "last_sync_timestamp" bigint,
    "last_sync_status" "text",
    "sync_count" integer DEFAULT 0,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "current_page" integer DEFAULT 0,
    "chunk_status" "text" DEFAULT 'pending'::"text"
);


ALTER TABLE "public"."sync_state" OWNER TO "postgres";


ALTER TABLE ONLY "public"."deferred_relationships" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."deferred_relationships_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."sync_errors" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."sync_errors_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."active_ingredients"
    ADD CONSTRAINT "active_ingredients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."brands"
    ADD CONSTRAINT "brands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."deferred_relationships"
    ADD CONSTRAINT "deferred_relationships_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."media"
    ADD CONSTRAINT "media_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizations"
    ADD CONSTRAINT "organizations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_brands"
    ADD CONSTRAINT "product_brands_pkey" PRIMARY KEY ("product_id", "brand_id");



ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_pkey" PRIMARY KEY ("product_id", "category_id");



ALTER TABLE ONLY "public"."product_families"
    ADD CONSTRAINT "product_families_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."product_media"
    ADD CONSTRAINT "product_media_pkey" PRIMARY KEY ("product_id", "media_id");



ALTER TABLE ONLY "public"."product_organizations"
    ADD CONSTRAINT "product_organizations_pkey" PRIMARY KEY ("product_id", "organization_id");



ALTER TABLE ONLY "public"."products"
    ADD CONSTRAINT "products_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."public_categories"
    ADD CONSTRAINT "public_categories_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_errors"
    ADD CONSTRAINT "sync_errors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sync_state"
    ADD CONSTRAINT "sync_state_pkey" PRIMARY KEY ("entity_type");



CREATE INDEX "idx_products_artg_id" ON "public"."products" USING "btree" ("artg_id") WHERE ("artg_id" IS NOT NULL);



CREATE INDEX "idx_products_pbs" ON "public"."products" USING "btree" ("pbs") WHERE ("pbs" IS NOT NULL);



CREATE INDEX "idx_products_updated_at" ON "public"."products" USING "btree" ("updated_at");



ALTER TABLE ONLY "public"."product_brands"
    ADD CONSTRAINT "product_brands_brand_id_fkey" FOREIGN KEY ("brand_id") REFERENCES "public"."brands"("id");



ALTER TABLE ONLY "public"."product_brands"
    ADD CONSTRAINT "product_brands_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_category_id_fkey" FOREIGN KEY ("category_id") REFERENCES "public"."public_categories"("id");



ALTER TABLE ONLY "public"."product_categories"
    ADD CONSTRAINT "product_categories_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."product_media"
    ADD CONSTRAINT "product_media_media_id_fkey" FOREIGN KEY ("media_id") REFERENCES "public"."media"("id");



ALTER TABLE ONLY "public"."product_media"
    ADD CONSTRAINT "product_media_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



ALTER TABLE ONLY "public"."product_organizations"
    ADD CONSTRAINT "product_organizations_organization_id_fkey" FOREIGN KEY ("organization_id") REFERENCES "public"."organizations"("id");



ALTER TABLE ONLY "public"."product_organizations"
    ADD CONSTRAINT "product_organizations_product_id_fkey" FOREIGN KEY ("product_id") REFERENCES "public"."products"("id");



CREATE POLICY "Allow service role access" ON "public"."active_ingredients" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."brands" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."deferred_relationships" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."media" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."organizations" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."product_brands" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."product_categories" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."product_families" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."product_media" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."product_organizations" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."products" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."public_categories" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."sync_errors" TO "service_role" USING (true);



CREATE POLICY "Allow service role access" ON "public"."sync_state" TO "service_role" USING (true);



ALTER TABLE "public"."active_ingredients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."brands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."deferred_relationships" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."media" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_brands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_families" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_media" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."product_organizations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."public_categories" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_errors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sync_state" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";





GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";

















































































































































































GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."pgmq_send"("queue_name" "text", "message" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."pgmq_send"("queue_name" "text", "message" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."pgmq_send"("queue_name" "text", "message" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."process_deferred_relationships"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_deferred_relationships"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_deferred_relationships"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_sync_responses"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_sync_responses"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_sync_responses"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_sync_task"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_sync_task"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_sync_task"() TO "service_role";



GRANT ALL ON FUNCTION "public"."process_sync_tasks_batch"() TO "anon";
GRANT ALL ON FUNCTION "public"."process_sync_tasks_batch"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."process_sync_tasks_batch"() TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_sync_tasks"() TO "anon";
GRANT ALL ON FUNCTION "public"."queue_sync_tasks"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_sync_tasks"() TO "service_role";



GRANT ALL ON FUNCTION "public"."queue_sync_tasks_aggressive"() TO "anon";
GRANT ALL ON FUNCTION "public"."queue_sync_tasks_aggressive"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_sync_tasks_aggressive"() TO "service_role";



GRANT ALL ON FUNCTION "public"."repair_category_parent_relationships"() TO "anon";
GRANT ALL ON FUNCTION "public"."repair_category_parent_relationships"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."repair_category_parent_relationships"() TO "service_role";



GRANT ALL ON FUNCTION "public"."repair_product_relationships"() TO "anon";
GRANT ALL ON FUNCTION "public"."repair_product_relationships"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."repair_product_relationships"() TO "service_role";



GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_sync_progress"("entity_type" "text", "completed_page" integer, "has_more_pages" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_sync_progress"("entity_type" "text", "completed_page" integer, "has_more_pages" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_sync_progress"("entity_type" "text", "completed_page" integer, "has_more_pages" boolean) TO "service_role";
























GRANT ALL ON TABLE "public"."active_ingredients" TO "anon";
GRANT ALL ON TABLE "public"."active_ingredients" TO "authenticated";
GRANT ALL ON TABLE "public"."active_ingredients" TO "service_role";



GRANT ALL ON TABLE "public"."brands" TO "anon";
GRANT ALL ON TABLE "public"."brands" TO "authenticated";
GRANT ALL ON TABLE "public"."brands" TO "service_role";



GRANT ALL ON TABLE "public"."deferred_relationships" TO "anon";
GRANT ALL ON TABLE "public"."deferred_relationships" TO "authenticated";
GRANT ALL ON TABLE "public"."deferred_relationships" TO "service_role";



GRANT ALL ON SEQUENCE "public"."deferred_relationships_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."deferred_relationships_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."deferred_relationships_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."media" TO "anon";
GRANT ALL ON TABLE "public"."media" TO "authenticated";
GRANT ALL ON TABLE "public"."media" TO "service_role";



GRANT ALL ON TABLE "public"."organizations" TO "anon";
GRANT ALL ON TABLE "public"."organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."organizations" TO "service_role";



GRANT ALL ON TABLE "public"."product_brands" TO "anon";
GRANT ALL ON TABLE "public"."product_brands" TO "authenticated";
GRANT ALL ON TABLE "public"."product_brands" TO "service_role";



GRANT ALL ON TABLE "public"."product_categories" TO "anon";
GRANT ALL ON TABLE "public"."product_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."product_categories" TO "service_role";



GRANT ALL ON TABLE "public"."product_families" TO "anon";
GRANT ALL ON TABLE "public"."product_families" TO "authenticated";
GRANT ALL ON TABLE "public"."product_families" TO "service_role";



GRANT ALL ON TABLE "public"."product_media" TO "anon";
GRANT ALL ON TABLE "public"."product_media" TO "authenticated";
GRANT ALL ON TABLE "public"."product_media" TO "service_role";



GRANT ALL ON TABLE "public"."product_organizations" TO "anon";
GRANT ALL ON TABLE "public"."product_organizations" TO "authenticated";
GRANT ALL ON TABLE "public"."product_organizations" TO "service_role";



GRANT ALL ON TABLE "public"."products" TO "anon";
GRANT ALL ON TABLE "public"."products" TO "authenticated";
GRANT ALL ON TABLE "public"."products" TO "service_role";



GRANT ALL ON TABLE "public"."public_categories" TO "anon";
GRANT ALL ON TABLE "public"."public_categories" TO "authenticated";
GRANT ALL ON TABLE "public"."public_categories" TO "service_role";



GRANT ALL ON TABLE "public"."sync_errors" TO "anon";
GRANT ALL ON TABLE "public"."sync_errors" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_errors" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."sync_state" TO "anon";
GRANT ALL ON TABLE "public"."sync_state" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_state" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























RESET ALL;
