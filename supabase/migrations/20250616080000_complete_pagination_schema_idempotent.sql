-- Complete Pagination Schema Migration (Idempotent)
-- Generated from working pagination-improvements branch state
-- Implements MediPim API v4 pagination improvements with full idempotency
-- Safe to run multiple times in any environment

-- Set session parameters for consistent behavior
SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', 'public, pg_temp', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

-- Ensure required extensions are installed (idempotent)
DO $$ 
BEGIN
    -- pg_cron for scheduling
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";
    END IF;
    
    -- pg_net for HTTP requests
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
        CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";
    END IF;
    
    -- pgcrypto for encoding
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgcrypto') THEN
        CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";
    END IF;
    
    -- Create pgmq schema if it doesn't exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.schemata WHERE schema_name = 'pgmq') THEN
        CREATE SCHEMA "pgmq";
    END IF;
    
    -- pgmq for message queuing
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgmq') THEN
        CREATE EXTENSION IF NOT EXISTS "pgmq" WITH SCHEMA "pgmq";
    END IF;
END $$;

-- Ensure public schema exists and is properly owned
CREATE SCHEMA IF NOT EXISTS "public";
ALTER SCHEMA "public" OWNER TO "pg_database_owner";
COMMENT ON SCHEMA "public" IS 'MediPim AU Importer v3 - API v4 Pagination Improvements (Production Ready)';

-- Create sync_state table with all pagination columns (idempotent)
CREATE TABLE IF NOT EXISTS public.sync_state (
    id SERIAL PRIMARY KEY,
    entity_type TEXT UNIQUE NOT NULL,
    last_sync_timestamp BIGINT DEFAULT 0,
    last_sync_status TEXT DEFAULT 'pending',
    sync_count INTEGER DEFAULT 0,
    current_page INTEGER DEFAULT 0,
    chunk_status TEXT DEFAULT 'pending',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Add pagination columns if they don't exist (idempotent)
DO $$ 
BEGIN
    -- Add pagination_method column with constraint
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'pagination_method') THEN
        ALTER TABLE public.sync_state ADD COLUMN pagination_method TEXT DEFAULT 'query';
        
        -- Add constraint after column creation
        ALTER TABLE public.sync_state ADD CONSTRAINT sync_state_pagination_method_check 
        CHECK (pagination_method = ANY (ARRAY['query'::text, 'stream'::text]));
    END IF;
    
    -- Add page_size column with constraint
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'page_size') THEN
        ALTER TABLE public.sync_state ADD COLUMN page_size INTEGER DEFAULT 100;
        
        -- Add constraint after column creation
        ALTER TABLE public.sync_state ADD CONSTRAINT sync_state_page_size_check 
        CHECK (page_size = ANY (ARRAY[10, 50, 100, 250]));
    END IF;
    
    -- Add max_results_limit column
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'max_results_limit') THEN
        ALTER TABLE public.sync_state ADD COLUMN max_results_limit INTEGER DEFAULT 10000;
    END IF;
END $$;

-- Create sync_errors table for logging (idempotent)
CREATE TABLE IF NOT EXISTS public.sync_errors (
    id SERIAL PRIMARY KEY,
    sync_type TEXT NOT NULL,
    error_message TEXT,
    error_data JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Initialize PGMQ queue (idempotent)
DO $$
BEGIN
    -- Check if queue exists by trying to inspect it
    BEGIN
        PERFORM pgmq.metrics('medipim_sync_tasks');
    EXCEPTION WHEN others THEN
        -- Queue doesn't exist, create it
        PERFORM pgmq.create_queue('medipim_sync_tasks');
    END;
END $$;

-- Enhanced request body builder function (idempotent)
CREATE OR REPLACE FUNCTION public.build_medipim_request_body(task_data JSONB) 
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
    -- Extract parameters from task data
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

-- Helper function to build endpoint URLs (idempotent)
CREATE OR REPLACE FUNCTION public.build_endpoint_url(entity_type TEXT, pagination_method TEXT)
RETURNS TEXT
LANGUAGE plpgsql
AS $$
DECLARE
    endpoint_url TEXT;
BEGIN
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
    
    RETURN endpoint_url;
END;
$$;

-- Test function for pagination fallback logic (idempotent)
CREATE OR REPLACE FUNCTION public.test_pagination_fallback(
    test_entity_type TEXT,
    test_total_records INTEGER,
    current_page INTEGER DEFAULT 0,
    page_size INTEGER DEFAULT 100
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    should_fallback BOOLEAN;
    fallback_recommendation TEXT;
    pagination_info JSONB;
BEGIN
    -- Check if we've hit the 10,000 limit and should switch to streaming
    should_fallback := test_total_records > 10000 AND test_entity_type IN ('products', 'media');
    
    IF should_fallback THEN
        fallback_recommendation := 'Switch to stream endpoint - dataset exceeds 10k limit';
    ELSE
        fallback_recommendation := 'Continue with query endpoint pagination';
    END IF;
    
    pagination_info := jsonb_build_object(
        'entity_type', test_entity_type,
        'total_records', test_total_records,
        'current_page', current_page,
        'page_size', page_size,
        'records_so_far', (current_page + 1) * page_size,
        'should_fallback_to_stream', should_fallback,
        'recommendation', fallback_recommendation,
        'next_action', CASE 
            WHEN should_fallback THEN 'Queue stream task'
            WHEN (current_page + 1) * page_size < test_total_records THEN 'Queue next page: ' || (current_page + 1)
            ELSE 'Sync complete'
        END
    );
    
    RETURN pagination_info;
END;
$$;

-- Initialize sync state data with pagination methods (idempotent)
INSERT INTO public.sync_state (entity_type, pagination_method, page_size, max_results_limit) VALUES
('products', 'stream', 250, 10000),      -- Use stream for large datasets (107k+ records)
('media', 'stream', 250, 10000),         -- Use stream for large datasets (100k+ records)
('organizations', 'query', 100, NULL),   -- Use query for smaller datasets (~2k records)
('brands', 'query', 100, NULL),          -- Use query for smaller datasets (~733 records)
('public_categories', 'query', 100, NULL), -- Use query for smaller datasets (~641 records)
('product_families', 'query', 100, NULL),  -- Use query for smaller datasets (~13 records)
('active_ingredients', 'query', 100, NULL) -- Use query for smaller datasets (~0 records)
ON CONFLICT (entity_type) DO UPDATE SET
    pagination_method = EXCLUDED.pagination_method,
    page_size = EXCLUDED.page_size,
    max_results_limit = EXCLUDED.max_results_limit,
    updated_at = NOW();

-- Add column comments (idempotent)
DO $$
BEGIN
    -- Add comments only if columns exist (safety check)
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'pagination_method') THEN
        COMMENT ON COLUMN public.sync_state.pagination_method IS 'Pagination method: query (paginated) or stream (all results)';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'page_size') THEN
        COMMENT ON COLUMN public.sync_state.page_size IS 'Page size for query method: 10, 50, 100, or 250';
    END IF;
    
    IF EXISTS (SELECT 1 FROM information_schema.columns 
               WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'max_results_limit') THEN
        COMMENT ON COLUMN public.sync_state.max_results_limit IS 'Maximum results before switching to stream method';
    END IF;
END $$;

-- Ensure function ownership is correct (idempotent)
DO $$
DECLARE
    func_name TEXT;
BEGIN
    -- List of functions to update ownership for
    FOR func_name IN 
        SELECT routine_name 
        FROM information_schema.routines 
        WHERE routine_schema = 'public' 
        AND routine_name IN (
            'build_medipim_request_body',
            'build_endpoint_url',
            'test_pagination_fallback'
        )
    LOOP
        EXECUTE format('ALTER FUNCTION public.%I OWNER TO postgres', func_name);
    END LOOP;
END $$;

-- Final migration validation (idempotent)
DO $$
BEGIN
    -- Verify all required extensions are installed
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
        RAISE EXCEPTION 'Migration validation failed: pg_cron extension missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net') THEN
        RAISE EXCEPTION 'Migration validation failed: pg_net extension missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pgmq') THEN
        RAISE EXCEPTION 'Migration validation failed: pgmq extension missing';
    END IF;
    
    -- Verify all required tables exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables 
                   WHERE table_schema = 'public' AND table_name = 'sync_state') THEN
        RAISE EXCEPTION 'Migration validation failed: sync_state table missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.tables 
                   WHERE table_schema = 'public' AND table_name = 'sync_errors') THEN
        RAISE EXCEPTION 'Migration validation failed: sync_errors table missing';
    END IF;
    
    -- Verify all required columns exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'pagination_method') THEN
        RAISE EXCEPTION 'Migration validation failed: pagination_method column missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'page_size') THEN
        RAISE EXCEPTION 'Migration validation failed: page_size column missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' AND column_name = 'max_results_limit') THEN
        RAISE EXCEPTION 'Migration validation failed: max_results_limit column missing';
    END IF;
    
    -- Verify functions exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.routines 
                   WHERE routine_schema = 'public' AND routine_name = 'build_medipim_request_body') THEN
        RAISE EXCEPTION 'Migration validation failed: build_medipim_request_body function missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.routines 
                   WHERE routine_schema = 'public' AND routine_name = 'build_endpoint_url') THEN
        RAISE EXCEPTION 'Migration validation failed: build_endpoint_url function missing';
    END IF;
    
    -- Verify data initialization
    IF (SELECT COUNT(*) FROM public.sync_state) != 7 THEN
        RAISE EXCEPTION 'Migration validation failed: Expected 7 entity types in sync_state, found %', (SELECT COUNT(*) FROM public.sync_state);
    END IF;
    
    -- Verify pagination configuration
    IF (SELECT COUNT(*) FROM public.sync_state WHERE pagination_method = 'stream') != 2 THEN
        RAISE EXCEPTION 'Migration validation failed: Expected 2 stream entities (products, media)';
    END IF;
    
    IF (SELECT COUNT(*) FROM public.sync_state WHERE pagination_method = 'query') != 5 THEN
        RAISE EXCEPTION 'Migration validation failed: Expected 5 query entities';
    END IF;
    
    -- Verify constraints exist
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' 
                   AND constraint_name = 'sync_state_pagination_method_check') THEN
        RAISE EXCEPTION 'Migration validation failed: pagination_method constraint missing';
    END IF;
    
    IF NOT EXISTS (SELECT 1 FROM information_schema.table_constraints 
                   WHERE table_schema = 'public' AND table_name = 'sync_state' 
                   AND constraint_name = 'sync_state_page_size_check') THEN
        RAISE EXCEPTION 'Migration validation failed: page_size constraint missing';
    END IF;
    
    RAISE NOTICE 'Migration validation passed: All pagination improvements applied successfully';
    RAISE NOTICE 'Schema ready for MediPim API v4 pagination with stream/query endpoints';
    RAISE NOTICE 'Products and Media configured for streaming, other entities for paginated queries';
END $$;