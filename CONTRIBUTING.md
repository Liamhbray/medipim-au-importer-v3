# Contributing to Medipim AU Importer v3

Thank you for your interest in contributing to this project! This document provides guidelines for contributing to the Medipim AU Importer v3 MVP.

## 🎯 Project Constraints

**CRITICAL**: This project has strict architectural constraints that must be followed:

### Forbidden Actions (Will Invalidate Implementation)
1. ❌ External NPM packages beyond native database functions
2. ❌ Any Edge Functions (optimized to 0 Edge Functions architecture)
3. ❌ Caching, queuing, or optimization not specified (pgmq task queuing is required)
4. ❌ Monitoring beyond `sync_errors` table
5. ❌ UI, dashboards, or admin panels
6. ❌ Data transformations beyond direct field mapping
7. ❌ Authentication beyond Basic Auth for Medipim
8. ❌ Helper functions not shown in specification
9. ❌ Custom retry logic (use native PGMQ visibility timeout and read_ct)
10. ❌ Data validation beyond Postgres constraints

### Required Architecture
- **Pure Database Architecture**: All processing via PostgreSQL functions
- **Native Supabase Only**: No external dependencies
- **Migration-Based**: All changes via migration files
- **1:1 API Replication**: Zero data loss, exact field mapping

## 🔄 Development Workflow

### Setup Development Environment
```bash
# Clone repository
git clone <repository-url>
cd medipim-au-importer-v3

# Setup environment
cp .env.example .env
# Edit .env with your development credentials

# Install Supabase CLI
npm install -g @supabase/cli

# Start local development
supabase start
supabase db reset
```

### Making Changes

#### 1. Database Schema Changes
All database changes MUST be made via migration files:

```bash
# Create new migration
supabase migration new your_change_description

# Edit the generated migration file
# Test migration
supabase db reset

# Generate new types
supabase gen types typescript --local > supabase/types/database.types.ts
```

#### 2. Function Changes
Update existing migration files (20250615100001-20250615100003) or create new migration:

```sql
-- Always use CREATE OR REPLACE FUNCTION
CREATE OR REPLACE FUNCTION function_name()
RETURNS return_type AS $$
-- Function body
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;
```

#### 3. Documentation Updates
Keep documentation in sync:
- Update `medipim-replication-architecture.md` for architecture changes
- Update `CLAUDE.md` for development guidance changes
- Update `README.md` for user-facing changes

### Validation Requirements

Before submitting any changes:

#### 1. Migration Validation
```bash
# Test migration deployment
supabase db reset
# Verify all functions work
# Check data integrity
```

#### 2. Field Mapping Validation
```sql
-- Verify Australian regulatory codes
SELECT artg_id, pbs, snomed_mp, snomed_mpp, snomed_mpuu 
FROM products 
WHERE artg_id IS NOT NULL 
LIMIT 5;

-- Check complete field mapping
SELECT COUNT(*) as total_fields
FROM information_schema.columns 
WHERE table_name = 'products';
-- Should return 26 fields
```

#### 3. Performance Validation
```sql
-- Check cron job status
SELECT jobname, schedule, active 
FROM cron.job;

-- Verify sync progress
SELECT entity_type, last_sync_status, sync_count 
FROM sync_state;
```

## 📝 Commit Guidelines

### Commit Message Format
```
type(scope): description

Detailed explanation of changes and why they were made.

🤖 Generated with Claude Code (claude.ai/code)

Co-Authored-By: Claude <noreply@anthropic.com>
```

### Types
- `feat`: New feature or functionality
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code refactoring without feature changes
- `perf`: Performance improvements
- `migration`: Database migration changes
- `types`: TypeScript type updates

### Examples
```
feat(sync): add deferred relationship processing

Implements FK resilience for async processing pipeline.
Handles cases where related entities arrive out of order.

🤖 Generated with Claude Code (claude.ai/code)

migration(schema): add media table indexes

Improves query performance for media lookups.
Follows architecture specification requirements.
```

## 🧪 Testing

### Manual Testing Checklist
- [ ] All migrations deploy successfully
- [ ] TypeScript types generate correctly
- [ ] Cron jobs are active and running
- [ ] Data sync produces expected results
- [ ] Australian regulatory codes are captured
- [ ] FK resilience handles relationship dependencies

### Performance Testing
```sql
-- Check API usage
SELECT COUNT(*) as requests_last_hour
FROM sync_errors 
WHERE sync_type = 'http_request_sent' 
  AND created_at > NOW() - INTERVAL '1 hour';

-- Verify batch processing
SELECT COUNT(*) as responses_processed
FROM sync_errors 
WHERE sync_type = 'response_processed'
  AND created_at > NOW() - INTERVAL '1 hour';
```

## 🔐 Security Guidelines

### Environment Variables
- Never commit `.env` file
- Always update `.env.example` for new variables
- Use descriptive placeholder values in `.env.example`

### Database Security
- All new tables must have RLS enabled
- Service role policies required for cron access
- No public access to sensitive data

### API Keys
- Store API keys in environment variables only
- Never hardcode credentials in functions
- Use proper Basic Auth format for Medipim API

## 📊 Documentation Standards

### Code Comments
```sql
-- Function description explaining purpose
CREATE OR REPLACE FUNCTION function_name()
RETURNS return_type AS $$
DECLARE
  -- Variable declarations with comments
BEGIN
  -- Step-by-step explanation of logic
END;
$$ LANGUAGE plpgsql SET search_path = public, pg_temp;
```

### Field Mapping Comments
```sql
-- Map ALL product fields exactly as specified
artg_id TEXT,                         -- "ARTG ID (string)"
pbs TEXT,                             -- "PBS code (string)"
snomed_mp TEXT,                       -- "SNOMED-MP code (string)"
```

## 🚫 Common Mistakes to Avoid

1. **Adding External Dependencies**: Stick to native Supabase features only
2. **Creating Edge Functions**: All processing must be database functions
3. **Ignoring Field Mapping**: Every API field must be preserved exactly
4. **Manual SQL Execution**: All changes via migration files
5. **Breaking FK Resilience**: Maintain deferred relationship processing
6. **Skipping Type Generation**: Always update TypeScript types after schema changes

## 📞 Getting Help

1. **Read Documentation First**: Check `CLAUDE.md` and architecture document
2. **Check Existing Issues**: Search for similar problems
3. **Test Locally**: Verify your setup matches requirements
4. **Migration Validation**: Ensure migrations deploy cleanly

## 🎯 Success Criteria

Any contribution must maintain:
- ✅ Complete 1:1 Medipim API replication
- ✅ Pure database architecture (zero Edge Functions)
- ✅ All Australian regulatory codes preserved
- ✅ Migration-based deployment approach
- ✅ TypeScript type safety
- ✅ Performance optimization (440+ req/hour)

**Before submitting any changes, confirm:**
> "This change maintains complete 1:1 Medipim replication using only native Supabase features, deployed via structured migration files, with every field, every entity, and every relationship preserved exactly."

If you cannot make this statement truthfully, the changes need further work.

---

**Thank you for contributing to maintaining the integrity of this pharmaceutical data replication system!**