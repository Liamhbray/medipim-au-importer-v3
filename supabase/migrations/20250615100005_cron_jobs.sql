-- Coordinated Async Cron Scheduling
-- 4 coordinated cron jobs for continuous processing pipeline

-- Phase 1: Queue new sync tasks (every 15 minutes) - OPTIMIZED
SELECT cron.schedule(
  'queue-sync-tasks',
  '*/15 * * * *',  -- Every 15 minutes (4x faster)
  $$
  SELECT queue_sync_tasks_aggressive();
  $$
);

-- Phase 2: Process queued tasks (every 30 seconds) - OPTIMIZED
SELECT cron.schedule(
  'process-sync-tasks',
  '*/30 * * * * *',  -- Every 30 seconds (4x faster)
  $$
  SELECT process_sync_tasks_batch();
  $$
);

-- Phase 3: Handle API responses (every minute)
SELECT cron.schedule(
  'process-responses',
  '* * * * *',  -- Every minute
  $$
  SELECT process_sync_responses();
  $$
);

-- Phase 4: FK resilience processing (every 10 minutes)
SELECT cron.schedule(
  'process-deferred-relationships',
  '*/10 * * * *',  -- Every 10 minutes
  $$
  SELECT repair_category_parent_relationships();
  SELECT process_deferred_relationships();
  $$
);

-- Insert initial sync_state records for each entity type
INSERT INTO sync_state (entity_type, last_sync_status, chunk_status) VALUES
  ('products', 'pending', 'pending'),
  ('organizations', 'pending', 'pending'),
  ('brands', 'pending', 'pending'),
  ('public_categories', 'pending', 'pending'),
  ('product_families', 'pending', 'pending'),
  ('active_ingredients', 'pending', 'pending'),
  ('media', 'pending', 'pending')
ON CONFLICT (entity_type) DO NOTHING;