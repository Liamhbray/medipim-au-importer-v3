-- Migration: Pagination Improvements for MediPim API v4
-- Implements proper pagination based on API v4 documentation
-- - Uses streaming endpoints for large datasets (products, media)
-- - Implements required page parameter for products/media queries  
-- - Adds support for configurable page sizes (10, 50, 100, 250)
-- - Handles 10,000 result limit with automatic stream fallback

-- Update sync_state table to track pagination method
ALTER TABLE sync_state 
ADD COLUMN IF NOT EXISTS pagination_method TEXT DEFAULT 'query',
ADD COLUMN IF NOT EXISTS page_size INTEGER DEFAULT 100,
ADD COLUMN IF NOT EXISTS max_results_limit INTEGER DEFAULT 10000;

-- Update sync_state records with appropriate pagination methods
UPDATE sync_state 
SET pagination_method = CASE 
  WHEN entity_type IN ('products', 'media') THEN 'stream'
  ELSE 'query'
END,
page_size = CASE 
  WHEN entity_type IN ('products', 'media') THEN 250  -- Larger pages for efficiency
  ELSE 100
END,
max_results_limit = CASE 
  WHEN entity_type IN ('products', 'media') THEN 10000
  ELSE NULL  -- No limit for other entities
END;

-- Enhanced request body builder with pagination method support
CREATE OR REPLACE FUNCTION build_medipim_request_body(task_data JSONB) 
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    entity_type TEXT;
    page_no INTEGER;
    page_size INTEGER;
    sync_type TEXT;
    pagination_method TEXT;
    result_body JSONB;
BEGIN
    entity_type := task_data->>'entity_type';
    page_no := COALESCE((task_data->>'page_no')::INTEGER, 0);
    page_size := COALESCE((task_data->>'page_size')::INTEGER, 100);
    sync_type := COALESCE(task_data->>'sync_type', 'incremental');
    pagination_method := COALESCE(task_data->>'pagination_method', 'query');
    
    -- Validate page_size is one of allowed values: 10, 50, 100, 250
    IF page_size NOT IN (10, 50, 100, 250) THEN
        page_size := 100;  -- Default fallback
    END IF;
    
    -- Build request body based on entity type and pagination method
    CASE entity_type
        WHEN 'products' THEN
            IF pagination_method = 'stream' THEN
                -- Stream endpoint: no pagination, filter + sorting only
                result_body := jsonb_build_object(
                    'filter', jsonb_build_object('status', 'active'),
                    'sorting', jsonb_build_object('id', 'ASC')
                );
            ELSE
                -- Query endpoint: filter + sorting + page ALL required for products
                result_body := jsonb_build_object(
                    'filter', jsonb_build_object('status', 'active'),
                    'sorting', jsonb_build_object('id', 'ASC'),
                    'page', jsonb_build_object(
                        'no', page_no,
                        'size', page_size
                    )
                );
            END IF;
            
        WHEN 'media' THEN
            IF pagination_method = 'stream' THEN
                -- Stream endpoint: no pagination, filter + sorting only
                result_body := jsonb_build_object(
                    'filter', jsonb_build_object('published', true),
                    'sorting', jsonb_build_object('id', 'ASC')
                );
            ELSE
                -- Query endpoint: filter + sorting + page ALL required for media
                result_body := jsonb_build_object(
                    'filter', jsonb_build_object('published', true),
                    'sorting', jsonb_build_object('id', 'ASC'),
                    'page', jsonb_build_object(
                        'no', page_no,
                        'size', page_size
                    )
                );
            END IF;
            
        ELSE
            -- Other entities: sorting optional, page optional (if omitted, all results returned)
            IF page_no > 0 OR page_size != 100 THEN
                -- Include pagination if explicitly requested
                result_body := jsonb_build_object(
                    'sorting', jsonb_build_object('id', 'ASC'),
                    'page', jsonb_build_object(
                        'no', page_no,
                        'size', page_size
                    )
                );
            ELSE
                -- No pagination - get all results
                result_body := jsonb_build_object(
                    'sorting', jsonb_build_object('id', 'ASC')
                );
            END IF;
    END CASE;
    
    RETURN result_body;
END;
$$;

-- Enhanced sync task processor with stream endpoint support
CREATE OR REPLACE FUNCTION process_sync_tasks_batch() 
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  task_record RECORD;
  request_id BIGINT;
  auth_header TEXT;
  request_body JSONB;
  endpoint_url TEXT;
  pagination_method TEXT;
  entity_type TEXT;
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
  
  -- Process tasks using PGMQ read + delete pattern
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
      
      -- Extract task details
      entity_type := task_record.message->>'entity_type';
      pagination_method := COALESCE(task_record.message->>'pagination_method', 'query');
      
      -- Build request
      request_body := build_medipim_request_body(task_record.message);
      
      -- Build endpoint URL based on pagination method
      IF pagination_method = 'stream' THEN
        -- Use stream endpoint for large datasets
        endpoint_url := 'https://api.au.medipim.com/v4/' || 
          CASE entity_type
            WHEN 'active_ingredients' THEN 'active-ingredients'
            WHEN 'product_families' THEN 'product-families'
            WHEN 'public_categories' THEN 'public-categories'
            ELSE entity_type
          END || '/stream';
      ELSE
        -- Use query endpoint with pagination
        endpoint_url := 'https://api.au.medipim.com/v4/' || 
          CASE entity_type
            WHEN 'active_ingredients' THEN 'active-ingredients'
            WHEN 'product_families' THEN 'product-families'
            WHEN 'public_categories' THEN 'public-categories'
            ELSE entity_type
          END || '/query';
      END IF;
      
      -- Make HTTP request with appropriate timeout
      -- Stream endpoints may take longer due to larger payloads
      SELECT net.http_post(
        url := endpoint_url,
        headers := jsonb_build_object(
          'Authorization', auth_header,
          'Content-Type', 'application/json'
        ),
        body := request_body,
        timeout_milliseconds := CASE 
          WHEN pagination_method = 'stream' THEN 120000  -- 2 minutes for streaming
          ELSE 30000  -- 30 seconds for paginated queries
        END
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
          'entity_type', entity_type,
          'pagination_method', pagination_method,
          'error', error_msg
        )
      );
    END;
  END LOOP;
  
  RETURN 'Processed ' || tasks_processed || ' tasks successfully';
END;
$$;

-- Enhanced response processor with stream response handling
CREATE OR REPLACE FUNCTION instant_response_processor() 
RETURNS TEXT
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  response_record RECORD;
  api_response JSONB;
  detected_entity_type TEXT;
  current_page INTEGER;
  page_size INTEGER;
  total_records INTEGER;
  has_more_pages BOOLEAN;
  is_stream_response BOOLEAN := FALSE;
  stream_lines TEXT[];
  stream_line TEXT;
  stream_index INTEGER;
  stream_total INTEGER;
  responses_processed INTEGER := 0;
BEGIN
  -- Process ALL unprocessed successful responses
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
      -- Detect response type: stream vs paginated query
      IF response_record.content::text LIKE '%{"meta": {"total":%' 
         AND response_record.content::text LIKE '%"index":%' THEN
        -- Stream response: line-by-line JSON
        is_stream_response := TRUE;
        
        -- Parse stream response (each line is a separate JSON object)
        stream_lines := string_to_array(trim(response_record.content::text), E'\n');
        
        -- Get total from first line
        IF array_length(stream_lines, 1) > 0 THEN
          api_response := stream_lines[1]::jsonb;
          stream_total := (api_response->'meta'->>'total')::integer;
          
          -- Determine entity type from total count
          CASE 
            WHEN stream_total > 100000 THEN detected_entity_type := 'products';
            WHEN stream_total BETWEEN 50000 AND 100000 THEN detected_entity_type := 'media';
            WHEN stream_total BETWEEN 1000 AND 5000 THEN detected_entity_type := 'organizations';
            WHEN stream_total BETWEEN 500 AND 1000 THEN detected_entity_type := 'brands';
            WHEN stream_total BETWEEN 100 AND 800 THEN detected_entity_type := 'public_categories';
            WHEN stream_total < 100 THEN detected_entity_type := 'product_families';
            ELSE detected_entity_type := 'unknown';
          END CASE;
          
          -- Mark stream sync as complete (no pagination needed)
          IF detected_entity_type != 'unknown' THEN
            UPDATE sync_state 
            SET last_sync_timestamp = extract(epoch from now())::bigint,
                last_sync_status = 'success',
                current_page = 0,
                chunk_status = 'completed',
                sync_count = stream_total,
                updated_at = NOW()
            WHERE entity_type = detected_entity_type;
          END IF;
        END IF;
        
      ELSE
        -- Standard paginated query response
        is_stream_response := FALSE;
        api_response := response_record.content::jsonb;
        
        -- Extract pagination metadata
        IF api_response->'meta'->>'total' IS NOT NULL THEN
          total_records := (api_response->'meta'->>'total')::integer;
          current_page := (api_response->'meta'->'page'->>'no')::integer;
          page_size := (api_response->'meta'->'page'->>'size')::integer;
          
          -- Determine entity type from response patterns
          CASE 
            WHEN total_records BETWEEN 100000 AND 150000 THEN detected_entity_type := 'products';
            WHEN total_records BETWEEN 80000 AND 120000 THEN detected_entity_type := 'media';
            WHEN total_records BETWEEN 1500 AND 3000 THEN detected_entity_type := 'organizations';
            WHEN total_records BETWEEN 500 AND 1000 THEN detected_entity_type := 'brands';
            WHEN total_records BETWEEN 400 AND 800 THEN detected_entity_type := 'public_categories';
            WHEN total_records BETWEEN 10 AND 50 THEN detected_entity_type := 'product_families';
            WHEN total_records = 0 THEN detected_entity_type := 'active_ingredients';
            ELSE detected_entity_type := 'unknown';
          END CASE;
          
          -- Check if we've hit the 10,000 limit and should switch to streaming
          IF total_records > 10000 AND detected_entity_type IN ('products', 'media') THEN
            -- Queue a stream task instead of continuing pagination
            PERFORM pgmq.send(
              'medipim_sync_tasks',
              jsonb_build_object(
                'entity_type', detected_entity_type,
                'pagination_method', 'stream',
                'sync_type', 'stream_fallback'
              )
            );
            
            -- Log the fallback
            INSERT INTO sync_errors (sync_type, error_message, error_data)
            VALUES (
              'pagination_limit_fallback',
              'Switched to stream endpoint due to 10,000 result limit',
              jsonb_build_object(
                'entity_type', detected_entity_type,
                'total_records', total_records,
                'current_page', current_page
              )
            );
            
          ELSE
            -- Normal pagination flow
            has_more_pages := (current_page + 1) * page_size < total_records;
            
            -- Update sync progress
            IF detected_entity_type != 'unknown' THEN
              PERFORM update_sync_progress(detected_entity_type, current_page, has_more_pages);
              
              -- Update sync_count to reflect actual processed records
              UPDATE sync_state 
              SET sync_count = LEAST((current_page + 1) * page_size, total_records),
                  updated_at = NOW()
              WHERE entity_type = detected_entity_type;
            END IF;
          END IF;
        END IF;
      END IF;
      
      -- Mark as processed
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_processed',
        CASE 
          WHEN is_stream_response THEN 'Stream response processed successfully'
          ELSE 'Paginated response processed successfully'
        END,
        jsonb_build_object(
          'request_id', response_record.request_id,
          'entity_type', detected_entity_type,
          'is_stream', is_stream_response,
          'page', COALESCE(current_page, 0),
          'total_records', COALESCE(total_records, stream_total),
          'processed_at', NOW()
        )
      );
      
      responses_processed := responses_processed + 1;
      
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO sync_errors (sync_type, error_message, error_data)
      VALUES (
        'response_error', 
        SQLERRM, 
        jsonb_build_object(
          'request_id', response_record.request_id,
          'error_context', 'Enhanced response processor with stream support'
        )
      );
    END;
  END LOOP;
  
  RETURN 'Enhanced processor handled: ' || responses_processed || ' responses';
END;
$$;

-- Enhanced sync progress updater with pagination method awareness
CREATE OR REPLACE FUNCTION update_sync_progress(entity_type TEXT, completed_page INTEGER, has_more_pages BOOLEAN) 
RETURNS VOID
LANGUAGE plpgsql
SET search_path TO 'public', 'pg_temp'
AS $$
DECLARE
  current_pagination_method TEXT;
  current_page_size INTEGER;
BEGIN
  -- Get current pagination settings
  SELECT pagination_method, page_size 
  INTO current_pagination_method, current_page_size
  FROM sync_state 
  WHERE sync_state.entity_type = update_sync_progress.entity_type;
  
  IF has_more_pages THEN
    -- Update current page and queue next chunk
    UPDATE sync_state 
    SET current_page = completed_page + 1,
        chunk_status = 'pending',
        updated_at = NOW()
    WHERE sync_state.entity_type = update_sync_progress.entity_type;
    
    -- Queue next page for processing (only for query method, not stream)
    IF current_pagination_method = 'query' THEN
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity_type,
          'page_no', completed_page + 1,
          'page_size', current_page_size,
          'pagination_method', current_pagination_method,
          'sync_type', CASE 
            WHEN entity_type IN ('products', 'media') THEN 'incremental'
            ELSE 'reference_chunk'
          END
        )
      );
    END IF;
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
  END IF;
END;
$$;

-- Initialize sync tasks with appropriate pagination methods
CREATE OR REPLACE FUNCTION initialize_sync_bootstrap()
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
  entity_record RECORD;
  task_count INTEGER := 0;
BEGIN
  -- Clear existing tasks
  PERFORM pgmq.purge_queue('medipim_sync_tasks');
  
  -- Initialize each entity type with appropriate method
  FOR entity_record IN 
    SELECT entity_type, pagination_method, page_size
    FROM sync_state 
    WHERE entity_type IN ('products', 'media', 'organizations', 'brands', 'public_categories', 'product_families', 'active_ingredients')
  LOOP
    -- Queue initial sync task
    PERFORM pgmq.send(
      'medipim_sync_tasks',
      jsonb_build_object(
        'entity_type', entity_record.entity_type,
        'page_no', 0,
        'page_size', entity_record.page_size,
        'pagination_method', entity_record.pagination_method,
        'sync_type', CASE 
          WHEN entity_record.entity_type IN ('products', 'media') THEN 'bootstrap'
          ELSE 'reference_data'
        END
      )
    );
    
    task_count := task_count + 1;
  END LOOP;
  
  -- Reset sync state
  UPDATE sync_state 
  SET current_page = 0,
      chunk_status = 'pending',
      last_sync_status = 'initializing',
      updated_at = NOW();
  
  RETURN 'Initialized ' || task_count || ' sync tasks with pagination methods';
END;
$$;

-- Comment on migration
COMMENT ON COLUMN sync_state.pagination_method IS 'Pagination method: query (paginated) or stream (all results)';
COMMENT ON COLUMN sync_state.page_size IS 'Page size for query method: 10, 50, 100, or 250';
COMMENT ON COLUMN sync_state.max_results_limit IS 'Maximum results before switching to stream method';