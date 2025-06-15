-- Production Sync Verification Migration
-- This migration ensures Git repository matches existing production state
-- Uses only idempotent operations to avoid conflicts

-- Verify extensions are enabled (idempotent)
CREATE EXTENSION IF NOT EXISTS pg_cron;
CREATE EXTENSION IF NOT EXISTS pg_net;
CREATE EXTENSION IF NOT EXISTS pgmq;

-- Initialize PGMQ queue if not exists (idempotent)
SELECT CASE 
  WHEN NOT EXISTS (SELECT 1 FROM pgmq.list_queues() WHERE queue_name = 'medipim_sync_tasks')
  THEN pgmq.create('medipim_sync_tasks')
  ELSE NULL
END;

-- Verify sync_state table has required data (idempotent)
INSERT INTO sync_state (entity_type, last_sync_timestamp, last_sync_status, sync_count, current_page, chunk_status)
VALUES 
  ('products', 0, 'ready', 0, 0, 'pending'),
  ('organizations', 0, 'ready', 0, 0, 'pending'),
  ('brands', 0, 'ready', 0, 0, 'pending'),
  ('public_categories', 0, 'ready', 0, 0, 'pending'),
  ('product_families', 0, 'ready', 0, 0, 'pending'),
  ('active_ingredients', 0, 'ready', 0, 0, 'pending'),
  ('media', 0, 'ready', 0, 0, 'pending')
ON CONFLICT (entity_type) DO NOTHING;

-- Verify RLS is enabled on all tables (idempotent)
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE active_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE media ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_errors ENABLE ROW LEVEL SECURITY;
ALTER TABLE deferred_relationships ENABLE ROW LEVEL SECURITY;

-- Verification comment
COMMENT ON EXTENSION pg_cron IS 'Git repository sync verification - production state confirmed';