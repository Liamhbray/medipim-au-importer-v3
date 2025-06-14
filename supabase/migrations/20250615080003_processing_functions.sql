-- Core Processing Functions (Updated for pgmq-only approach)
-- Represents the current optimized functions without sync_requests dependencies

-- Process sync tasks in batches (optimized version)
CREATE OR REPLACE FUNCTION process_sync_tasks_batch()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$ SET search_path = public, pg_temp;

-- Process sync responses (updated for pure pgmq approach)
CREATE OR REPLACE FUNCTION process_sync_responses()
 RETURNS void
 LANGUAGE plpgsql
AS $function$
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
$function$ SET search_path = public, pg_temp;

-- FK Resilience Functions for Async Processing
CREATE OR REPLACE FUNCTION repair_category_parent_relationships()
RETURNS void AS $$
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
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION repair_product_relationships()
RETURNS void AS $$
DECLARE
  product_record RECORD;
BEGIN
  FOR product_record IN SELECT id, raw_data FROM products
  LOOP
    PERFORM store_product_relationships(product_record.id, product_record.raw_data);
  END LOOP;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION process_deferred_relationships()
RETURNS INTEGER AS $$
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
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;