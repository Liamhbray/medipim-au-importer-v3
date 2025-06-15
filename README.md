# MediPim Australia Importer v3

A production-ready Supabase application for importing and synchronizing medical product data from MediPim's Australian database.

## Overview

This system provides a robust, scalable solution for managing Australian medical product catalogs with real-time synchronization capabilities. Built on Supabase with PostgreSQL 17, it handles complex product relationships, pricing data, and regulatory identifiers.

## Features

- **Product Catalog Management**: Comprehensive medical product database with pricing, identifiers (ARTG, EAN, SNOMED codes), and metadata
- **Relationship Management**: Complex many-to-many relationships between products, brands, organizations, and categories
- **Sync Infrastructure**: Automated synchronization with error handling and deferred relationship processing
- **Media Management**: Product images and document storage with 50MB limits
- **Real-time Updates**: Live data synchronization using Supabase Realtime
- **Type Safety**: Full TypeScript type definitions for database schema

## Database Schema

### Core Tables
- **products** (~1,200 records): Main product catalog
- **organizations** (~2,050 records): Manufacturers and distributors
- **brands** (~733 records): Product brands
- **public_categories** (~641 records): Hierarchical categorization
- **media** (~500 records): Product images and documents

### Sync Management
- **sync_state**: Tracks synchronization status
- **sync_errors**: Error logging and monitoring
- **deferred_relationships**: Handles complex relationship imports

## Production Deployment

### Environment Variables
```bash
# Required for production
SUPABASE_URL=https://your-project-id.supabase.co
SUPABASE_ANON_KEY=your-anon-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key

# Optional
OPENAI_API_KEY=your-openai-key  # For AI features
```

### Database Setup
1. Create new Supabase project
2. Apply migration: `supabase db push`
3. Enable required extensions (automatically handled)
4. Configure RLS policies (included in migration)

### Required Extensions
- `pg_cron`: Scheduled tasks
- `pg_net`: HTTP requests
- `pg_graphql`: GraphQL API
- `pg_stat_statements`: Performance monitoring
- `pgcrypto`: Cryptographic functions

## Local Development

### Prerequisites
- Node.js 18+
- Supabase CLI
- Docker (for local Supabase)

### Setup
```bash
# Clone repository
git clone <repository-url>
cd medipim-au-importer-v3

# Install Supabase CLI
npm install -g supabase

# Start local development environment
supabase start

# Reset database with latest schema
supabase db reset

# Generate TypeScript types
supabase gen types typescript --local > supabase/types/database.types.ts
```

### Local URLs
- **API**: http://localhost:54321
- **Database**: postgresql://postgres:postgres@localhost:54322/postgres
- **Studio**: http://localhost:54323
- **Inbucket** (Email testing): http://localhost:54324

## API Usage

### Authentication
All API requests require authentication via Supabase Auth or service role key.

### Example Queries
```javascript
// Fetch products with relationships
const { data: products } = await supabase
  .from('products')
  .select(`
    *,
    product_brands(brands(*)),
    product_categories(public_categories(*)),
    product_organizations(organizations(*))
  `)
  .limit(10);

// Monitor sync status
const { data: syncStatus } = await supabase
  .from('sync_state')
  .select('*');
```

## Monitoring & Maintenance

### Health Checks
- Monitor `sync_state` table for sync failures
- Check `sync_errors` for detailed error logs
- Review `deferred_relationships` for processing backlogs

### Performance
- Database size: ~17MB with current dataset
- Estimated capacity: 10,000+ products
- Response times: <100ms for standard queries

### Backup Strategy
- Automatic daily backups via Supabase
- Point-in-time recovery available
- Export capabilities via pg_dump

## Security

### Row Level Security (RLS)
All tables have RLS enabled with appropriate policies for:
- Public read access for product data
- Authenticated access for sync operations
- Service role access for administrative functions

### Data Protection
- Encrypted at rest (Supabase default)
- SSL/TLS in transit
- API key rotation supported
- Audit logs available

## Support

### Troubleshooting
1. Check sync_errors table for detailed error messages
2. Verify API connectivity and authentication
3. Monitor resource usage in Supabase dashboard
4. Review application logs for client-side issues

### Contact
For technical support or feature requests, please contact the development team.

## License

[Your License Here]

---

**Production Status**: ✅ Verified compatible with Supabase production environment (2025-06-15)