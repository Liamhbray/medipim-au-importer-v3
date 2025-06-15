-- Row Level Security (RLS) Policies
-- Applied via previous security hardening migration

-- Enable RLS on all tables
ALTER TABLE products ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE public_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_families ENABLE ROW LEVEL SECURITY;
ALTER TABLE active_ingredients ENABLE ROW LEVEL SECURITY;
ALTER TABLE media ENABLE ROW LEVEL SECURITY;

-- Junction tables
ALTER TABLE product_organizations ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_brands ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE product_media ENABLE ROW LEVEL SECURITY;

-- Sync infrastructure tables
ALTER TABLE sync_state ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_errors ENABLE ROW LEVEL SECURITY;
ALTER TABLE deferred_relationships ENABLE ROW LEVEL SECURITY;

-- Create policies to allow service role access (required for cron jobs)
-- Products table policies
CREATE POLICY "Allow service role access" ON products FOR ALL TO service_role USING (true);

-- Organizations table policies  
CREATE POLICY "Allow service role access" ON organizations FOR ALL TO service_role USING (true);

-- Brands table policies
CREATE POLICY "Allow service role access" ON brands FOR ALL TO service_role USING (true);

-- Public categories table policies
CREATE POLICY "Allow service role access" ON public_categories FOR ALL TO service_role USING (true);

-- Product families table policies
CREATE POLICY "Allow service role access" ON product_families FOR ALL TO service_role USING (true);

-- Active ingredients table policies
CREATE POLICY "Allow service role access" ON active_ingredients FOR ALL TO service_role USING (true);

-- Media table policies
CREATE POLICY "Allow service role access" ON media FOR ALL TO service_role USING (true);

-- Junction table policies
CREATE POLICY "Allow service role access" ON product_organizations FOR ALL TO service_role USING (true);
CREATE POLICY "Allow service role access" ON product_brands FOR ALL TO service_role USING (true);
CREATE POLICY "Allow service role access" ON product_categories FOR ALL TO service_role USING (true);
CREATE POLICY "Allow service role access" ON product_media FOR ALL TO service_role USING (true);

-- Sync infrastructure policies
CREATE POLICY "Allow service role access" ON sync_state FOR ALL TO service_role USING (true);
CREATE POLICY "Allow service role access" ON sync_errors FOR ALL TO service_role USING (true);
CREATE POLICY "Allow service role access" ON deferred_relationships FOR ALL TO service_role USING (true);