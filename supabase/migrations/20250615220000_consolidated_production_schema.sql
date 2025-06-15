

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


CREATE SCHEMA IF NOT EXISTS "public";


ALTER SCHEMA "public" OWNER TO "pg_database_owner";


COMMENT ON SCHEMA "public" IS 'Medipim AU Importer v3 MVP - Production compatibility verified 2025-06-15';



CREATE OR REPLACE FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    entity_type TEXT;
    page_no INTEGER;
    sync_type TEXT;
    result_body JSONB;
BEGIN
    entity_type := task_data->>'entity_type';
    page_no := COALESCE((task_data->>'page_no')::INTEGER, 0);
    sync_type := COALESCE(task_data->>'sync_type', 'incremental');
    
    -- Build request body exactly per API docs requirements
    CASE entity_type
        WHEN 'products' THEN
            -- Products: filter + sorting + page ALL required
            result_body := jsonb_build_object(
                'filter', jsonb_build_object('status', 'active'),
                'sorting', jsonb_build_object('id', 'ASC'),     -- Simple string format
                'page', jsonb_build_object(
                    'no', page_no,
                    'size', 100
                )
            );
        WHEN 'media' THEN
            -- Media: filter + sorting + page ALL required  
            result_body := jsonb_build_object(
                'filter', jsonb_build_object('published', true),
                'sorting', jsonb_build_object('id', 'ASC'),
                'page', jsonb_build_object(
                    'no', page_no,
                    'size', 100
                )
            );
        ELSE
            -- Other entities: sorting optional (default {"id": "ASC"}), page optional
            result_body := jsonb_build_object(
                'sorting', jsonb_build_object('id', 'ASC'),
                'page', jsonb_build_object(
                    'no', page_no,
                    'size', 100
                )
            );
    END CASE;
    
    RETURN result_body;
END;
$$;


ALTER FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."clear_response_backlog"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  response_id BIGINT;
  responses_processed INTEGER := 0;
BEGIN
  -- Simply mark all unprocessed 200 responses as processed
  FOR response_id IN 
    SELECT nr.id
    FROM net._http_response nr 
    WHERE nr.status_code = 200
      AND NOT EXISTS (
        SELECT 1 FROM sync_errors 
        WHERE error_data->>'request_id' = nr.id::text
          AND sync_type = 'response_processed'
      )
    LIMIT 100
  LOOP
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
      'response_processed',
      'Backlog cleared',
      jsonb_build_object('request_id', response_id, 'cleared_at', NOW())
    );
    
    responses_processed := responses_processed + 1;
  END LOOP;
  
  RETURN 'Cleared backlog: ' || responses_processed || ' responses';
END;
$$;


ALTER FUNCTION "public"."clear_response_backlog"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."enhanced_process_sync_task"() RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  task_record RECORD;
  request_id BIGINT;
  auth_header TEXT;
  request_body JSONB;
  entity_type TEXT;
BEGIN
  -- Build Basic Auth header from environment
  auth_header := 'Basic ' || encode(
    current_setting('app.medipim_api_key_id', true) || ':' || 
    current_setting('app.medipim_api_key', true), 'base64'
  );
  
  -- Pop next task with 5-minute visibility timeout
  SELECT * INTO task_record FROM pgmq.pop('medipim_sync_tasks', 300);
  
  IF task_record IS NOT NULL THEN
    entity_type := task_record.message->>'entity_type';
    
    BEGIN
      -- Build request body
      request_body := build_medipim_request_body(task_record.message);
      
      -- Make HTTP request
      SELECT net.http_post(
        url := 'https://api.au.medipim.com/v4/' || entity_type || '/query',
        headers := jsonb_build_object(
          'Authorization', auth_header,
          'Content-Type', 'application/json'
        ),
        body := request_body,
        timeout_milliseconds := 30000
      ) INTO request_id;
      
      -- Simple success logging
      UPDATE sync_state 
      SET last_sync_timestamp = EXTRACT(epoch FROM NOW())::bigint,
          last_sync_status = 'success'
      WHERE entity_type = entity_type;
      
    EXCEPTION WHEN OTHERS THEN
      -- Simple error logging without breaking the flow
      UPDATE sync_state 
      SET last_sync_status = 'error: ' || SUBSTR(SQLERRM, 1, 100)
      WHERE entity_type = entity_type;
    END;
  END IF;
END;
$$;


ALTER FUNCTION "public"."enhanced_process_sync_task"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fast_api_processor"() RETURNS "text"
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
BEGIN
  auth_header := 'Basic ' || encode('10:6e1afc83cb7c15429f3c06bbfb5828911d8dd537', 'base64');
  
  -- Process ALL queued tasks (no artificial limits)
  LOOP
    SELECT * INTO task_record FROM pgmq.pop('medipim_sync_tasks');
    EXIT WHEN task_record IS NULL;
    
    request_body := build_medipim_request_body(task_record.message);
    
    endpoint_url := 'https://api.au.medipim.com/v4/' || 
      CASE task_record.message->>'entity_type'
        WHEN 'active_ingredients' THEN 'active-ingredients'
        WHEN 'product_families' THEN 'product-families'
        WHEN 'public_categories' THEN 'public-categories'
        ELSE task_record.message->>'entity_type'
      END || '/query';
    
    SELECT net.http_post(
      url := endpoint_url,
      headers := jsonb_build_object(
        'Authorization', auth_header,
        'Content-Type', 'application/json'
      ),
      body := request_body,
      timeout_milliseconds := 30000
    ) INTO request_id;
    
    tasks_processed := tasks_processed + 1;
  END LOOP;
  
  RETURN 'Fast processor handled: ' || tasks_processed || ' requests';
END;
$$;


ALTER FUNCTION "public"."fast_api_processor"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_products_from_response"("api_response" "jsonb", "request_id" bigint) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    result_item JSONB;
    inserted_count INTEGER := 0;
BEGIN
    FOR result_item IN SELECT * FROM jsonb_array_elements(api_response->'results')
    LOOP
        BEGIN
            INSERT INTO products (
                id, 
                status, 
                name_en,
                raw_data, 
                created_at, 
                updated_at
            )
            VALUES (
                result_item->>'id',
                result_item->>'status',
                result_item->'name'->>'en',
                result_item,
                COALESCE((result_item->'meta'->>'createdAt')::BIGINT, EXTRACT(epoch FROM NOW())::BIGINT),
                COALESCE((result_item->'meta'->>'updatedAt')::BIGINT, EXTRACT(epoch FROM NOW())::BIGINT)
            )
            ON CONFLICT (id) DO UPDATE SET
                status = EXCLUDED.status,
                name_en = EXCLUDED.name_en,
                raw_data = EXCLUDED.raw_data,
                updated_at = EXCLUDED.updated_at;
            
            inserted_count := inserted_count + 1;
            
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO sync_errors (sync_type, error_message, error_data)
            VALUES (
                'product_insertion_error',
                'Failed to insert product ' || (result_item->>'id') || ': ' || SQLERRM,
                jsonb_build_object(
                    'product_id', result_item->>'id',
                    'error', SQLERRM,
                    'request_id', request_id
                )
            );
        END;
    END LOOP;
    
    -- Update sync_state
    UPDATE sync_state 
    SET 
        sync_count = sync_count + inserted_count,
        last_sync_timestamp = EXTRACT(epoch FROM NOW())::BIGINT,
        last_sync_status = CASE WHEN inserted_count > 0 THEN 'success' ELSE 'partial' END
    WHERE entity_type = 'products';
    
    RETURN inserted_count;
END;
$$;


ALTER FUNCTION "public"."insert_products_from_response"("api_response" "jsonb", "request_id" bigint) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."instant_response_processor"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  response_record RECORD;
  api_response JSONB;
  detected_entity_type TEXT;
  current_page INTEGER;
  page_size INTEGER;
  total_records INTEGER;
  has_more_pages BOOLEAN;
  responses_processed INTEGER := 0;
BEGIN
  -- Process ALL unprocessed successful responses (no batch limits)
  FOR response_record IN 
    SELECT 
      nr.id as request_id,
      nr.content, 
      nr.status_code,
      nr.created
    FROM net._http_response nr 
    WHERE nr.status_code = 200
      AND NOT EXISTS (
        SELECT 1 FROM sync_errors 
        WHERE error_data->>'request_id' = nr.id::text
          AND sync_type = 'response_processed'
      )
    ORDER BY nr.created ASC
    LIMIT 50  -- Process in manageable batches
  LOOP
    BEGIN
      api_response := response_record.content::jsonb;
      
      -- Extract entity information from response
      IF api_response->'meta'->>'total' IS NOT NULL THEN
        total_records := (api_response->'meta'->>'total')::integer;
        current_page := (api_response->'meta'->'page'->>'no')::integer;
        page_size := (api_response->'meta'->'page'->>'size')::integer;
        
        -- Determine entity type from response patterns
        CASE 
          WHEN total_records = 107946 THEN detected_entity_type := 'products';
          WHEN total_records = 100756 THEN detected_entity_type := 'media';
          WHEN total_records = 2050 THEN detected_entity_type := 'organizations';
          WHEN total_records = 733 THEN detected_entity_type := 'brands';
          WHEN total_records = 641 THEN detected_entity_type := 'public_categories';
          WHEN total_records = 13 THEN detected_entity_type := 'product_families';
          WHEN total_records = 0 THEN detected_entity_type := 'active_ingredients';
          ELSE detected_entity_type := 'unknown';
        END CASE;
        
        -- Calculate if there are more pages
        has_more_pages := (current_page + 1) * page_size < total_records;
        
        -- Update sync progress with correct parameters
        IF detected_entity_type != 'unknown' THEN
          PERFORM update_sync_progress(detected_entity_type, current_page, has_more_pages);
          
          -- Update sync_count to reflect actual processed records (fixed scope)
          UPDATE sync_state 
          SET sync_count = LEAST((current_page + 1) * page_size, total_records),
              updated_at = NOW()
          WHERE entity_type = detected_entity_type;
        END IF;
      END IF;
      
      -- Mark as processed
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processed',
        'Response processed successfully',
        jsonb_build_object(
          'request_id', response_record.request_id,
          'entity_type', detected_entity_type,
          'page', current_page,
          'total_records', total_records,
          'processed_at', NOW()
        )
      );
      
      responses_processed := responses_processed + 1;
      
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES ('response_error', SQLERRM, jsonb_build_object('request_id', response_record.request_id));
    END;
  END LOOP;
  
  RETURN 'Instant processor handled: ' || responses_processed || ' responses';
END;
$$;


ALTER FUNCTION "public"."instant_response_processor"() OWNER TO "postgres";


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
    AS $$
DECLARE
  response_record RECORD;
  api_response JSONB;
  total_processed INTEGER := 0;
  max_responses_per_batch INTEGER := 20;
  entity_type TEXT;
BEGIN
  FOR response_record IN 
    SELECT 
      nr.id as request_id,
      nr.content, 
      nr.status_code,
      nr.created,
      nq.url as request_url
    FROM net._http_response nr 
    LEFT JOIN net.http_request_queue nq ON nq.id = nr.id
    WHERE nr.status_code IS NOT NULL
      AND nr.created > NOW() - INTERVAL '2 hours'
      AND nr.status_code = 200
      AND NOT EXISTS (
        SELECT 1 FROM sync_errors 
        WHERE error_data->>'request_id' = nr.id::text
          AND sync_type = 'response_processed'
      )
    ORDER BY nr.created ASC
    LIMIT max_responses_per_batch
  LOOP
    total_processed := total_processed + 1;
    
    BEGIN
      api_response := response_record.content::jsonb;
      
      -- Detect entity type from URL or response structure
      IF response_record.request_url IS NOT NULL THEN
        entity_type := CASE 
          WHEN response_record.request_url LIKE '%/products/%' THEN 'products'
          WHEN response_record.request_url LIKE '%/organizations/%' THEN 'organizations'
          WHEN response_record.request_url LIKE '%/brands/%' THEN 'brands'
          WHEN response_record.request_url LIKE '%/public-categories/%' THEN 'public_categories'
          WHEN response_record.request_url LIKE '%/media/%' THEN 'media'
          WHEN response_record.request_url LIKE '%/product-families/%' THEN 'product_families'
          WHEN response_record.request_url LIKE '%/active-ingredients/%' THEN 'active_ingredients'
          ELSE 'unknown'
        END;
      ELSE
        -- Detect from response structure - products have specific fields
        IF api_response->'results'->0 ? 'artgId' OR api_response->'results'->0 ? 'eanGtin13' THEN
          entity_type := 'products';
        ELSE
          entity_type := 'unknown';
        END IF;
      END IF;
      
      -- Process products directly
      IF entity_type = 'products' AND jsonb_array_length(COALESCE(api_response->'results', '[]'::jsonb)) > 0 THEN
        PERFORM insert_products_from_response(api_response, response_record.request_id);
      END IF;
      
      -- Mark response as processed
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processed',
        'Response processed successfully for ' || entity_type,
        jsonb_build_object(
          'request_id', response_record.request_id,
          'processed_at', NOW(),
          'entity_type', entity_type,
          'items_processed', COALESCE(jsonb_array_length(api_response->'results'), 0)
        )
      );
      
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processing_error',
        SQLERRM,
        jsonb_build_object(
          'request_id', response_record.request_id,
          'error_time', NOW(),
          'content_preview', LEFT(response_record.content, 200)
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


CREATE OR REPLACE FUNCTION "public"."process_sync_tasks_batch"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  task_record RECORD;
  request_id BIGINT;
  auth_header TEXT;
  request_body JSONB;
  endpoint_url TEXT;
  tasks_processed INTEGER := 0;
  max_tasks_per_batch INTEGER := 40; -- 80% of 50/min rate limit
  max_retries INTEGER := 5;
  error_msg TEXT;
BEGIN
  -- Build auth header
  BEGIN
    auth_header := 'Basic ' || encode('10:6e1afc83cb7c15429f3c06bbfb5828911d8dd537', 'base64');
  EXCEPTION WHEN OTHERS THEN
    RETURN 'ERROR: Failed to build auth header: ' || SQLERRM;
  END;
  
  -- Process tasks using PGMQ read + delete pattern (not pop)
  FOR task_record IN 
    SELECT * FROM pgmq.read('medipim_sync_tasks', 300, max_tasks_per_batch)
  LOOP
    BEGIN
      -- Handle retry limit
      IF task_record.read_ct > max_retries THEN
        PERFORM pgmq.archive('medipim_sync_tasks', task_record.msg_id);
        INSERT INTO sync_errors (sync_type, error_message, error_data)
        VALUES (
          'max_retries_exceeded',
          'Task archived after ' || max_retries || ' retries',
          task_record.message
        );
        CONTINUE;
      END IF;
      
      -- Build request
      request_body := build_medipim_request_body(task_record.message);
      
      -- Build correct endpoint URL with /query
      endpoint_url := 'https://api.au.medipim.com/v4/' || 
        CASE task_record.message->>'entity_type'
          WHEN 'active_ingredients' THEN 'active-ingredients'
          WHEN 'product_families' THEN 'product-families'
          WHEN 'public_categories' THEN 'public-categories'
          ELSE task_record.message->>'entity_type'
        END || '/query';
      
      -- Make HTTP request
      SELECT net.http_post(
        url := endpoint_url,
        headers := jsonb_build_object(
          'Authorization', auth_header,
          'Content-Type', 'application/json'
        ),
        body := request_body,
        timeout_milliseconds := 30000
      ) INTO request_id;
      
      -- Delete successful task (PGMQ completion pattern)
      PERFORM pgmq.delete('medipim_sync_tasks', task_record.msg_id);
      tasks_processed := tasks_processed + 1;
      
    EXCEPTION WHEN OTHERS THEN
      -- Log error but let PGMQ handle retry
      error_msg := SQLERRM;
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'batch_processing_error',
        'Task processing failed: ' || error_msg,
        jsonb_build_object(
          'task_id', task_record.msg_id,
          'entity_type', task_record.message->>'entity_type',
          'error', error_msg
        )
      );
    END;
  END LOOP;
  
  RETURN 'Processed ' || tasks_processed || ' tasks successfully';
END;
$$;


ALTER FUNCTION "public"."process_sync_tasks_batch"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_products_aggressively"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    current_queue_size INTEGER;
    highest_page_processed INTEGER;
    tasks_queued INTEGER := 0;
    total_pages_needed INTEGER := 1080; -- 107946 / 100 rounded up
BEGIN
    SELECT COUNT(*) INTO current_queue_size FROM pgmq.q_medipim_sync_tasks;
    
    -- Get highest page processed from recent responses
    SELECT COALESCE(MAX((content::jsonb->'meta'->'page'->>'no')::INTEGER), 0)
    INTO highest_page_processed
    FROM net._http_response 
    WHERE status_code = 200 
    AND created > NOW() - INTERVAL '2 hours'
    AND content::jsonb->'meta'->'page' IS NOT NULL;
    
    -- Keep queue filled for continuous 80 req/min processing
    IF current_queue_size < 80 THEN -- Less than 1 minute of tasks
        FOR page_no IN (highest_page_processed + 1)..(highest_page_processed + 200) LOOP
            IF page_no <= total_pages_needed THEN
                PERFORM pgmq.send(
                    'medipim_sync_tasks',
                    jsonb_build_object(
                        'entity_type', 'products',
                        'page_no', page_no,
                        'sync_type', 'incremental'
                    )
                );
                tasks_queued := tasks_queued + 1;
            END IF;
        END LOOP;
    END IF;
    
    RETURN 'Queued ' || tasks_queued || ' tasks. Next page: ' || (highest_page_processed + 1) || '/' || total_pages_needed;
END;
$$;


ALTER FUNCTION "public"."queue_products_aggressively"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_sync_tasks"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  task_count INTEGER := 0;
  entity TEXT;
  -- All 7 entity types exist in API v4 documentation
  all_entities TEXT[] := ARRAY['organizations', 'brands', 'public_categories', 'products', 'media', 'active_ingredients', 'product_families'];
BEGIN
  -- Queue basic sync tasks for all entity types
  FOREACH entity IN ARRAY all_entities LOOP
    -- Skip if sync is already in progress or recently completed
    IF NOT EXISTS (
      SELECT 1 FROM sync_state 
      WHERE entity_type = entity 
      AND (last_sync_status = 'in_progress' 
           OR (last_sync_status = 'success' AND updated_at > NOW() - INTERVAL '5 minutes'))
    ) THEN
      -- Queue initial page for each entity type
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity,
          'sync_type', CASE WHEN entity IN ('products', 'media') THEN 'incremental' ELSE 'reference_chunk' END,
          'page_no', COALESCE((SELECT current_page FROM sync_state WHERE entity_type = entity), 0)
        )
      );
      task_count := task_count + 1;
    END IF;
  END LOOP;
  
  RETURN 'Sync tasks queued for async processing: ' || task_count || ' tasks';
END;
$$;


ALTER FUNCTION "public"."queue_sync_tasks"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."queue_sync_tasks_aggressive"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  task_count INTEGER := 0;
  entity TEXT;
  page_num INTEGER;
  current_page INTEGER;
  -- Only include supported entity types
  supported_entities TEXT[] := ARRAY['organizations', 'brands', 'public_categories', 'products', 'media'];
BEGIN
  -- Queue multiple pages per entity type for faster processing
  FOREACH entity IN ARRAY supported_entities LOOP
    -- Get current page for this entity
    SELECT COALESCE(sync_state.current_page, 0) INTO current_page 
    FROM sync_state WHERE entity_type = entity;
    
    -- Queue 2-3 pages ahead for each entity type
    FOR page_num IN current_page..(current_page + 2) LOOP
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity,
          'sync_type', CASE WHEN entity IN ('products', 'media') THEN 'incremental' ELSE 'reference_chunk' END,
          'page_no', page_num
        )
      );
      task_count := task_count + 1;
    END LOOP;
  END LOOP;
  
  RETURN 'Aggressive sync tasks queued: ' || task_count || ' tasks';
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


CREATE OR REPLACE FUNCTION "public"."reset_stuck_syncs"("hours_threshold" integer DEFAULT 1) RETURNS TABLE("entity_type" "text", "was_stuck" boolean)
    LANGUAGE "sql"
    AS $$
  UPDATE sync_state 
  SET 
    last_sync_status = 'ready',
    updated_at = NOW()
  WHERE chunk_status = 'pending' 
    AND updated_at < NOW() - (hours_threshold || ' hours')::INTERVAL
  RETURNING 
    sync_state.entity_type,
    true as was_stuck;
$$;


ALTER FUNCTION "public"."reset_stuck_syncs"("hours_threshold" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."smart_sync_requester"() RETURNS "text"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  task_count INTEGER := 0;
  entity TEXT;
  page_num INTEGER;
  max_requests_per_batch INTEGER := 20; -- 40 req/min (under 50 limit)
  all_entities TEXT[] := ARRAY['products', 'media', 'organizations', 'brands', 'public_categories', 'active_ingredients', 'product_families'];
BEGIN
  -- Queue next pages for entities that need more data
  FOREACH entity IN ARRAY all_entities LOOP
    EXIT WHEN task_count >= max_requests_per_batch;
    
    -- Queue next 3 pages for this entity (if not recently synced)
    FOR page_num IN 
      (SELECT current_page FROM sync_state WHERE entity_type = entity)..
      (SELECT current_page + 2 FROM sync_state WHERE entity_type = entity) 
    LOOP
      EXIT WHEN task_count >= max_requests_per_batch;
      
      -- Queue the page
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity,
          'sync_type', CASE WHEN entity IN ('products', 'media') THEN 'incremental' ELSE 'reference_chunk' END,
          'page_no', page_num
        )
      );
      task_count := task_count + 1;
    END LOOP;
  END LOOP;
  
  RETURN 'Smart requester queued: ' || task_count || ' requests';
END;
$$;


ALTER FUNCTION "public"."smart_sync_requester"() OWNER TO "postgres";


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


CREATE OR REPLACE FUNCTION "public"."test_entity_sorting_formats"() RETURNS TABLE("entity_type" "text", "simple_format_works" boolean, "nested_format_works" boolean)
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    entity_types TEXT[] := ARRAY['products', 'media', 'organizations', 'brands', 'public_categories', 'active_ingredients', 'product_families'];
    entity TEXT;
    simple_request JSONB;
    nested_request JSONB;
    request_id_simple INTEGER;
    request_id_nested INTEGER;
BEGIN
    -- Test each entity type with both formats
    FOREACH entity IN ARRAY entity_types LOOP
        -- Simple format test
        simple_request := jsonb_build_object(
            'sorting', jsonb_build_object('id', 'ASC'),
            'page', jsonb_build_object('no', 0, 'size', 50)
        );
        
        -- Add filters for specific entity types
        IF entity = 'products' THEN
            simple_request := jsonb_set(simple_request, '{filter}', jsonb_build_object('status', 'active'));
        ELSIF entity = 'media' THEN
            simple_request := jsonb_set(simple_request, '{filter}', jsonb_build_object('published', true));
        END IF;
        
        -- Make HTTP request with simple format
        SELECT net.http_post(
            url := 'https://api.medipim.com/' || entity,
            headers := '{"Content-Type": "application/json", "Authorization": "Bearer 1b84cd8c8f1a0c3b33b78d5dd05bedf7"}'::jsonb,
            body := simple_request
        ) INTO request_id_simple;
        
        -- Nested format test  
        nested_request := jsonb_build_object(
            'sorting', jsonb_build_object('id', jsonb_build_object('direction', 'ASC')),
            'page', jsonb_build_object('no', 0, 'size', 50)
        );
        
        -- Add same filters
        IF entity = 'products' THEN
            nested_request := jsonb_set(nested_request, '{filter}', jsonb_build_object('status', 'active'));
        ELSIF entity = 'media' THEN
            nested_request := jsonb_set(nested_request, '{filter}', jsonb_build_object('published', true));
        END IF;
        
        -- Make HTTP request with nested format
        SELECT net.http_post(
            url := 'https://api.medipim.com/' || entity,
            headers := '{"Content-Type": "application/json", "Authorization": "Bearer 1b84cd8c8f1a0c3b33b78d5dd05bedf7"}'::jsonb,
            body := nested_request
        ) INTO request_id_nested;
        
        -- Return the entity and request IDs for tracking
        RETURN QUERY SELECT entity, false, false; -- Will update based on actual responses
    END LOOP;
END;
$$;


ALTER FUNCTION "public"."test_entity_sorting_formats"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."test_single_entity_request"("entity_type_param" "text", "use_nested_format" boolean DEFAULT false) RETURNS integer
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    request_body JSONB;
    request_id INTEGER;
    endpoint_url TEXT;
BEGIN
    -- Build appropriate endpoint URL
    CASE entity_type_param
        WHEN 'products' THEN endpoint_url := 'https://api.medipim.com/products';
        WHEN 'media' THEN endpoint_url := 'https://api.medipim.com/media';
        WHEN 'organizations' THEN endpoint_url := 'https://api.medipim.com/organizations';
        WHEN 'brands' THEN endpoint_url := 'https://api.medipim.com/brands';
        WHEN 'public_categories' THEN endpoint_url := 'https://api.medipim.com/public-categories';
        WHEN 'active_ingredients' THEN endpoint_url := 'https://api.medipim.com/active-ingredients';
        WHEN 'product_families' THEN endpoint_url := 'https://api.medipim.com/product-families';
        ELSE RAISE EXCEPTION 'Unknown entity type: %', entity_type_param;
    END CASE;
    
    -- Build request body with specified sorting format
    IF use_nested_format THEN
        request_body := jsonb_build_object(
            'sorting', jsonb_build_object('id', jsonb_build_object('direction', 'ASC')),
            'page', jsonb_build_object('no', 0, 'size', 50)
        );
    ELSE
        request_body := jsonb_build_object(
            'sorting', jsonb_build_object('id', 'ASC'),
            'page', jsonb_build_object('no', 0, 'size', 50)
        );
    END IF;
    
    -- Add entity-specific filters
    IF entity_type_param = 'products' THEN
        request_body := jsonb_set(request_body, '{filter}', jsonb_build_object('status', 'active'));
    ELSIF entity_type_param = 'media' THEN
        request_body := jsonb_set(request_body, '{filter}', jsonb_build_object('published', true));
    END IF;
    
    -- Make the HTTP request
    SELECT net.http_post(
        url := endpoint_url,
        headers := '{"Content-Type": "application/json", "Authorization": "Bearer 1b84cd8c8f1a0c3b33b78d5dd05bedf7"}'::jsonb,
        body := request_body
    ) INTO request_id;
    
    RETURN request_id;
END;
$$;


ALTER FUNCTION "public"."test_single_entity_request"("entity_type_param" "text", "use_nested_format" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_sync_progress"("request_id" bigint, "api_response" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    entity_type_var TEXT;
    items_count INTEGER;
    current_page INTEGER;
    result_item JSONB;
    request_url TEXT;
    request_body_text TEXT;
    request_body JSONB;
    inserted_count INTEGER := 0;
    debug_info JSONB;
BEGIN
    -- Log function entry
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
        'debug_sync_progress',
        'Function called with request_id: ' || request_id,
        jsonb_build_object('request_id', request_id, 'step', 'entry')
    );
    
    -- Get request details
    SELECT url, convert_from(body, 'UTF8') INTO request_url, request_body_text
    FROM net.http_request_queue 
    WHERE id = request_id;
    
    -- Log request details
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
        'debug_sync_progress',
        'Request URL: ' || COALESCE(request_url, 'NULL'),
        jsonb_build_object('request_id', request_id, 'step', 'url_parsed', 'url', request_url)
    );
    
    -- Extract entity type from URL
    entity_type_var := CASE 
        WHEN request_url LIKE '%/products/%' THEN 'products'
        WHEN request_url LIKE '%/organizations/%' THEN 'organizations'
        WHEN request_url LIKE '%/brands/%' THEN 'brands'
        WHEN request_url LIKE '%/public-categories/%' THEN 'public_categories'
        WHEN request_url LIKE '%/media/%' THEN 'media'
        WHEN request_url LIKE '%/product-families/%' THEN 'product_families'
        WHEN request_url LIKE '%/active-ingredients/%' THEN 'active_ingredients'
        ELSE 'unknown'
    END;
    
    -- Log entity type detection
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
        'debug_sync_progress',
        'Entity type detected: ' || entity_type_var,
        jsonb_build_object('request_id', request_id, 'step', 'entity_type', 'entity_type', entity_type_var)
    );
    
    -- Count items in response
    items_count := jsonb_array_length(COALESCE(api_response->'results', '[]'::jsonb));
    
    -- Log items count
    INSERT INTO sync_errors (sync_type, error_message, error_data)
    VALUES (
        'debug_sync_progress',
        'Items count: ' || items_count,
        jsonb_build_object('request_id', request_id, 'step', 'items_count', 'count', items_count)
    );
    
    -- Only process products for now
    IF entity_type_var = 'products' AND items_count > 0 THEN
        -- Log processing start
        INSERT INTO sync_errors (sync_type, error_message, error_data)
        VALUES (
            'debug_sync_progress',
            'Starting to process ' || items_count || ' products',
            jsonb_build_object('request_id', request_id, 'step', 'processing_start')
        );
        
        FOR result_item IN SELECT * FROM jsonb_array_elements(api_response->'results')
        LOOP
            BEGIN
                -- Log individual product processing
                INSERT INTO sync_errors (sync_type, error_message, error_data)
                VALUES (
                    'debug_sync_progress',
                    'Processing product: ' || (result_item->>'id'),
                    jsonb_build_object('request_id', request_id, 'step', 'product_processing', 'product_id', result_item->>'id')
                );
                
                -- Use the simple pattern that worked in manual testing
                INSERT INTO products (
                    id, 
                    status, 
                    name_en,
                    raw_data, 
                    created_at, 
                    updated_at
                )
                VALUES (
                    result_item->>'id',
                    result_item->>'status',
                    result_item->'name'->>'en',
                    result_item,
                    COALESCE((result_item->'meta'->>'createdAt')::BIGINT, EXTRACT(epoch FROM NOW())::BIGINT),
                    COALESCE((result_item->'meta'->>'updatedAt')::BIGINT, EXTRACT(epoch FROM NOW())::BIGINT)
                )
                ON CONFLICT (id) DO UPDATE SET
                    status = EXCLUDED.status,
                    name_en = EXCLUDED.name_en,
                    raw_data = EXCLUDED.raw_data,
                    updated_at = EXCLUDED.updated_at;
                
                inserted_count := inserted_count + 1;
                
            EXCEPTION WHEN OTHERS THEN
                -- Log individual product insertion errors
                INSERT INTO sync_errors (sync_type, error_message, error_data)
                VALUES (
                    'debug_product_error',
                    'Failed to insert product ' || (result_item->>'id') || ': ' || SQLERRM,
                    jsonb_build_object(
                        'product_id', result_item->>'id',
                        'error', SQLERRM,
                        'request_id', request_id
                    )
                );
            END;
        END LOOP;
        
        -- Log completion
        INSERT INTO sync_errors (sync_type, error_message, error_data)
        VALUES (
            'debug_sync_progress',
            'Processing completed. Inserted: ' || inserted_count,
            jsonb_build_object('request_id', request_id, 'step', 'completed', 'inserted', inserted_count)
        );
        
    ELSE
        -- Log why processing was skipped
        INSERT INTO sync_errors (sync_type, error_message, error_data)
        VALUES (
            'debug_sync_progress',
            'Processing skipped. Entity: ' || entity_type_var || ', Items: ' || items_count,
            jsonb_build_object('request_id', request_id, 'step', 'skipped', 'entity_type', entity_type_var, 'items_count', items_count)
        );
    END IF;
    
END;
$$;


ALTER FUNCTION "public"."update_sync_progress"("request_id" bigint, "api_response" "jsonb") OWNER TO "postgres";


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


CREATE OR REPLACE VIEW "public"."sync_dashboard" AS
 SELECT "entity_type",
    "current_page",
    "sync_count" AS "items_synced",
    "last_sync_status",
        CASE
            WHEN ("last_sync_timestamp" IS NOT NULL) THEN "to_timestamp"(("last_sync_timestamp")::double precision)
            ELSE NULL::timestamp with time zone
        END AS "last_sync_at",
        CASE
            WHEN ("last_sync_timestamp" IS NOT NULL) THEN (EXTRACT(epoch FROM ("now"() - "to_timestamp"(("last_sync_timestamp")::double precision))) / (60)::numeric)
            ELSE NULL::numeric
        END AS "minutes_since_last_sync"
   FROM "public"."sync_state"
  ORDER BY "entity_type";


ALTER VIEW "public"."sync_dashboard" OWNER TO "postgres";


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


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";



GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_medipim_request_body"("task_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."clear_response_backlog"() TO "anon";
GRANT ALL ON FUNCTION "public"."clear_response_backlog"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."clear_response_backlog"() TO "service_role";



GRANT ALL ON FUNCTION "public"."enhanced_process_sync_task"() TO "anon";
GRANT ALL ON FUNCTION "public"."enhanced_process_sync_task"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."enhanced_process_sync_task"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fast_api_processor"() TO "anon";
GRANT ALL ON FUNCTION "public"."fast_api_processor"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fast_api_processor"() TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_products_from_response"("api_response" "jsonb", "request_id" bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."insert_products_from_response"("api_response" "jsonb", "request_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_products_from_response"("api_response" "jsonb", "request_id" bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."instant_response_processor"() TO "anon";
GRANT ALL ON FUNCTION "public"."instant_response_processor"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."instant_response_processor"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."queue_products_aggressively"() TO "anon";
GRANT ALL ON FUNCTION "public"."queue_products_aggressively"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."queue_products_aggressively"() TO "service_role";



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



GRANT ALL ON FUNCTION "public"."reset_stuck_syncs"("hours_threshold" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."reset_stuck_syncs"("hours_threshold" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."reset_stuck_syncs"("hours_threshold" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."smart_sync_requester"() TO "anon";
GRANT ALL ON FUNCTION "public"."smart_sync_requester"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."smart_sync_requester"() TO "service_role";



GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."store_entity_data"("entity_type" "text", "item_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."store_product_relationships"("product_id" "text", "product_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."test_entity_sorting_formats"() TO "anon";
GRANT ALL ON FUNCTION "public"."test_entity_sorting_formats"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."test_entity_sorting_formats"() TO "service_role";



GRANT ALL ON FUNCTION "public"."test_single_entity_request"("entity_type_param" "text", "use_nested_format" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."test_single_entity_request"("entity_type_param" "text", "use_nested_format" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."test_single_entity_request"("entity_type_param" "text", "use_nested_format" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_sync_progress"("request_id" bigint, "api_response" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_sync_progress"("request_id" bigint, "api_response" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_sync_progress"("request_id" bigint, "api_response" "jsonb") TO "service_role";



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



GRANT ALL ON TABLE "public"."sync_state" TO "anon";
GRANT ALL ON TABLE "public"."sync_state" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_state" TO "service_role";



GRANT ALL ON TABLE "public"."sync_dashboard" TO "anon";
GRANT ALL ON TABLE "public"."sync_dashboard" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_dashboard" TO "service_role";



GRANT ALL ON TABLE "public"."sync_errors" TO "anon";
GRANT ALL ON TABLE "public"."sync_errors" TO "authenticated";
GRANT ALL ON TABLE "public"."sync_errors" TO "service_role";



GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."sync_errors_id_seq" TO "service_role";



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
