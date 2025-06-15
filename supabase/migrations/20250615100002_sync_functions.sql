-- Sync Processing Functions
-- Represents functions applied via previous apply_migration calls

-- Store product relationships (junction tables)
CREATE OR REPLACE FUNCTION store_product_relationships(product_id TEXT, product_data JSONB)
RETURNS void AS $$
DECLARE
  org_item JSONB;
  brand_item JSONB;
  category_item JSONB;
  media_item JSONB;
BEGIN
  -- Clear existing relationships for this product
  DELETE FROM product_organizations WHERE product_organizations.product_id = store_product_relationships.product_id;
  DELETE FROM product_brands WHERE product_brands.product_id = store_product_relationships.product_id;
  DELETE FROM product_categories WHERE product_categories.product_id = store_product_relationships.product_id;
  DELETE FROM product_media WHERE product_media.product_id = store_product_relationships.product_id;
  
  -- Insert organization relationships with FK resilience
  FOR org_item IN SELECT * FROM jsonb_array_elements(product_data->'organizations')
  LOOP
    IF EXISTS (SELECT 1 FROM organizations WHERE id = (org_item->>'id')::integer) THEN
      INSERT INTO product_organizations (product_id, organization_id)
      VALUES (store_product_relationships.product_id, (org_item->>'id')::integer)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Store for deferred processing when organization becomes available
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('product', store_product_relationships.product_id, 'organization', org_item);
    END IF;
  END LOOP;
  
  -- Insert brand relationships with FK resilience
  FOR brand_item IN SELECT * FROM jsonb_array_elements(product_data->'brands')
  LOOP
    IF EXISTS (SELECT 1 FROM brands WHERE id = (brand_item->>'id')::integer) THEN
      INSERT INTO product_brands (product_id, brand_id)
      VALUES (store_product_relationships.product_id, (brand_item->>'id')::integer)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Store for deferred processing when brand becomes available
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('product', store_product_relationships.product_id, 'brand', brand_item);
    END IF;
  END LOOP;
  
  -- Insert category relationships with FK resilience
  FOR category_item IN SELECT * FROM jsonb_array_elements(product_data->'publicCategories')
  LOOP
    IF EXISTS (SELECT 1 FROM public_categories WHERE id = (category_item->>'id')::integer) THEN
      INSERT INTO product_categories (product_id, category_id)
      VALUES (store_product_relationships.product_id, (category_item->>'id')::integer)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Store for deferred processing when category becomes available
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('product', store_product_relationships.product_id, 'category', category_item);
    END IF;
  END LOOP;
  
  -- Insert media relationships with FK resilience
  FOR media_item IN SELECT * FROM jsonb_array_elements(product_data->'photos')
  LOOP
    IF EXISTS (SELECT 1 FROM media WHERE id = (media_item->>'id')::integer) THEN
      INSERT INTO product_media (product_id, media_id)
      VALUES (store_product_relationships.product_id, (media_item->>'id')::integer)
      ON CONFLICT DO NOTHING;
    ELSE
      -- Store for deferred processing when media becomes available
      INSERT INTO deferred_relationships (entity_type, entity_id, relationship_type, relationship_data)
      VALUES ('product', store_product_relationships.product_id, 'media', media_item);
    END IF;
  END LOOP;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- Update sync progress and queue next chunks if needed
CREATE OR REPLACE FUNCTION update_sync_progress(
  entity_type TEXT, 
  completed_page INTEGER, 
  has_more_pages BOOLEAN
)
RETURNS void AS $$
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
  END IF;
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- Queue sync tasks (optimized version)
CREATE OR REPLACE FUNCTION queue_sync_tasks_aggressive()
RETURNS TEXT AS $$
DECLARE
  reference_entities TEXT[] := ARRAY['organizations', 'brands', 'public_categories', 'product_families', 'active_ingredients'];
  entity TEXT;
  state RECORD;
  pages_to_queue INTEGER;
  page_num INTEGER;
  tasks_queued INTEGER := 0;
BEGIN
  -- Queue reference data chunks aggressively (multiple pages ahead)
  FOREACH entity IN ARRAY reference_entities
  LOOP
    SELECT * INTO state FROM sync_state WHERE entity_type = entity;
    
    -- Determine how many pages to queue ahead based on entity type
    pages_to_queue := CASE 
      WHEN entity IN ('organizations', 'brands') THEN 3  -- More pages for large entities
      ELSE 2  -- Fewer pages for smaller entities
    END;
    
    -- Queue multiple pages ahead for continuous processing
    FOR page_num IN COALESCE(state.current_page, 0)..(COALESCE(state.current_page, 0) + pages_to_queue - 1)
    LOOP
      PERFORM pgmq.send(
        'medipim_sync_tasks',
        jsonb_build_object(
          'entity_type', entity,
          'page_no', page_num,
          'sync_type', 'reference_chunk'
        )
      );
      tasks_queued := tasks_queued + 1;
    END LOOP;
  END LOOP;
  
  -- Queue incremental updates for products and media
  PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object('entity_type', 'products', 'sync_type', 'incremental'));
  PERFORM pgmq.send('medipim_sync_tasks', jsonb_build_object('entity_type', 'media', 'sync_type', 'incremental'));
  tasks_queued := tasks_queued + 2;
  
  RETURN 'Aggressive sync tasks queued: ' || tasks_queued || ' tasks';
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;

-- Standard queue sync tasks function
CREATE OR REPLACE FUNCTION queue_sync_tasks()
RETURNS TEXT AS $$
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
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;