# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 🎯 CRITICAL SUCCESS REQUIREMENT

**THIS PROJECT HAS ONE NON-NEGOTIABLE OUTCOME:**

> **"This MVP achieves complete 1:1 Medipim replication"**

Every field, every entity, every relationship from Medipim API V4 must be replicated exactly. **Zero data loss permitted.**

## 📋 PROJECT OVERVIEW

**What**: Specification repository for Australian pharmaceutical data replication system  
**Goal**: Complete 1:1 replication of Medipim API V4 data using exclusively native Supabase features  
**Domain**: Australian pharmaceutical industry with regulatory compliance requirements  

## 🚨 IMPLEMENTATION GUARDRAILS

### FORBIDDEN ACTIONS (Will Invalidate Implementation)
The architecture document (Lines 44-53) lists 10 specific actions that **immediately invalidate** any implementation:

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

### EXACT SCOPE - NO ADDITIONS PERMITTED
**Includes EXACTLY:**
- 1 database schema (14 tables total including sync infrastructure and FK resilience)
- 0 Edge Functions (optimized pure database architecture)
- 0 storage buckets (metadata-only media approach - no file storage)
- 4 coordinated cron jobs (continuous async processing pipeline)
- 1 task queue (pgmq: `medipim_sync_tasks` with native visibility timeout and retry)
- Database processing functions (pg_net based async API calls)

**Excludes Everything Else** (Lines 81-91)

## 📁 REPOSITORY STRUCTURE

**Primary Documents:**
- `medipim-replication-architecture.md` - **Complete implementation specification**
- `medipim-api-v4-documentation.jsonld` - Medipim API reference data
- `supabase-documentation.jsonld` - Supabase backend infrastructure docs

**Implementation Structure:**
```
supabase/
├── config.toml                                   # Supabase local development config
├── migrations/                                   # Database deployment scripts
│   ├── 20250615080000_complete_medipim_system.sql    # Core schema (14 tables)
│   ├── 20250615080001_database_functions.sql         # Entity storage functions
│   ├── 20250615080002_sync_functions.sql            # Relationship handling
│   ├── 20250615080003_processing_functions.sql      # Batch processing
│   ├── 20250615080004_security_policies.sql         # RLS configuration
│   └── 20250615080005_cron_jobs.sql                # Coordinated cron pipeline
└── types/
    └── database.types.ts                         # TypeScript database types
```

## 🔄 MANDATORY WORKFLOW

### Phase 1: Read Critical Constraints FIRST
**Before any work**, read Lines 30-108 in architecture document:
- ⚠️ Critical Implementation Constraints
- 🚫 DO NOT - Forbidden Actions  
- 🛑 Reward Hacking Prevention
- 📏 Scope Boundaries

### Phase 2: Follow Sequential Task Execution
**Migration-Based Implementation** contains 6 sequential deployments:
1. **Complete System Setup** - Core schema with 14 tables and extensions
2. **Database Functions** - Entity storage with exact field mapping
3. **Sync Functions** - Relationship handling and progress tracking
4. **Processing Functions** - Optimized batch processing and FK resilience
5. **Security Configuration** - RLS policies for automated processing
6. **Cron Scheduling** - 4 coordinated jobs for continuous async pipeline

### Phase 3: Migration-Based Validation
**Final Implementation Verification** ensures:
- **Migration Deployment**: All 6 migration files successfully applied
- **Database Schema**: All 14 tables with exact field mappings and FK resilience
- **Database Functions**: Pure database processing with no Edge Functions
- **TypeScript Types**: Generated types reflect complete schema accurately
- **Security**: RLS policies enable service role access for cron operations
- **Cron Pipeline**: 4 coordinated cron jobs with optimized scheduling

## 🧬 DATA COMPLETENESS REQUIREMENTS

### Australian Pharmaceutical Regulatory Codes
**ALL of these MUST be captured exactly:**
- `artgId` → `artg_id` (Australian Register of Therapeutic Goods)
- `pbs` (Pharmaceutical Benefits Scheme)
- `fred` (Fred POS Code)  
- `zCode` → `z_code` (Z Register POS Code)
- **ALL 7 SNOMED codes:**
  - `snomedMp` → `snomed_mp` (Medicinal Product)
  - `snomedMpp` → `snomed_mpp` (Medicinal Product Pack)
  - `snomedMpuu` → `snomed_mpuu` (Medicinal Product Units of Use)
  - `snomedTp` → `snomed_tp` (Trade Product)
  - `snomedTpp` → `snomed_tpp` (Trade Product Pack)
  - `snomedTpuu` → `snomed_tpuu` (Trade Product Unit of Use)
  - `snomedCtpp` → `snomed_ctpp` (Contained Trade Product Pack)

### Complete Entity Coverage Required
- **Products** (20+ fields including all Australian codes)
- **Organizations** (suppliers, marketing companies)
- **Brands** (pharmaceutical brands)
- **Public Categories** (hierarchical classification)
- **Product Families** (product groupings)
- **Active Ingredients** (pharmaceutical compounds)
- **Media** (metadata for product images and documents - URLs preserved, files not stored)
- **Junction Tables** (all many-to-many relationships)

## 🏗️ NATIVE SUPABASE ARCHITECTURE

**Technology Stack (Lines 18-27):**
- **PostgreSQL 17** - "Every project is a full Postgres database"
- **pg_cron** - Native scheduling extension
- **pg_net** - Native HTTP request extension
- **pgmq** - "Lightweight message queue built on Postgres" with native visibility timeout and retry

**Authentication**: Service Role Key (built-in Supabase auth)  
**Data Storage**: JSONB for complete raw API responses  
**Media Storage**: Metadata-only approach preserving URLs in JSONB  

## 🎯 SUCCESS VALIDATION

**The implementation achieves complete 1:1 replication when:**

✅ **Database Completeness**: All 14 tables created with exact field mappings including sync infrastructure and FK resilience  
✅ **Field Completeness**: All 20+ product fields captured exactly  
✅ **Entity Completeness**: All 7 entity types synchronized  
✅ **Australian Completeness**: All regulatory codes captured  
✅ **Raw Data Preservation**: Complete API responses stored in JSONB  
✅ **Media Completeness**: All product image metadata captured (URLs preserved in API responses)  
✅ **Relationship Completeness**: All many-to-many relationships mapped  
✅ **Sync Completeness**: Continuous async pipeline with self-healing FK resilience captures all changes  

## 🔧 MIGRATION-BASED IMPLEMENTATION

### Migration-Based Deployment
```bash
# Deploy using Supabase migrations (executed in sequence):
supabase/migrations/
├── 20250615080000_complete_medipim_system.sql    # Core schema with all 14 tables
├── 20250615080001_database_functions.sql         # Entity storage functions
├── 20250615080002_sync_functions.sql            # Relationship & progress functions
├── 20250615080003_processing_functions.sql      # Batch processing & FK resilience
├── 20250615080004_security_policies.sql         # RLS policies for all tables
└── 20250615080005_cron_jobs.sql                # 4 coordinated cron jobs
```

### TypeScript Integration
```typescript
// Generated types reflect complete database schema
supabase/types/database.types.ts
- All 14 tables with exact field mappings
- Complete function signatures for all database functions
- Australian regulatory code fields preserved (artg_id, pbs, snomed_*, etc.)
- Junction table relationships properly typed
- JSONB raw_data fields for complete API response storage
```

**Key TypeScript Features:**
- **Tables Interface**: All 14 tables with Row/Insert/Update types
- **Functions Interface**: All processing functions with parameter types
- **Relationships**: Foreign key relationships properly defined
- **Australian Codes**: All regulatory fields typed as string | null
- **JSONB Support**: Complete API response preservation via Json type

### ⚡ Performance Status (Applied via Migrations)
```sql
-- MIGRATION-DEPLOYED: 6 sequential migration files
-- OPTIMIZED: 440 requests/hour (vs 30/hour previously)
-- OPTIMIZED: 30-second task processing (vs 2-minute)
-- OPTIMIZED: 15-minute queuing (vs hourly)
-- OPTIMIZED: 3 tasks per batch (vs 1 task)
-- ARCHITECTURE: 4 cron jobs with native PGMQ retry
-- API Usage: 12.2% (well under 100 req/min limit)
-- TYPES: Complete TypeScript integration with database.types.ts
```

### Validation Query
```sql
-- Verify Australian regulatory codes are populated
SELECT artg_id, pbs, snomed_mp, snomed_mpp, snomed_mpuu 
FROM products 
WHERE artg_id IS NOT NULL 
LIMIT 10;
```

## 📖 NAVIGATION GUIDE

**Key Architecture Sections:**
- **Migration Structure**: Complete 6-file deployment sequence
- **Database Schema**: Complete SQL for all 14 tables including sync infrastructure and FK resilience  
- **Database Functions**: Pure database processing with async API calls
- **TypeScript Types**: Generated database.types.ts with complete schema reflection
- **Coordinated Async Cron Scheduling**: 4 cron jobs for continuous processing
- **Implementation Task List**: Migration-based deployment guide (**START HERE**)
- **Final Verification Checklist**: Migration deployment validation

**Database Functions Available:**
- `build_medipim_request_body()` - API request construction
- `store_entity_data()` - Entity storage with exact field mapping
- `store_product_relationships()` - Junction table management
- `process_sync_tasks_batch()` - Optimized batch processing (3 tasks/execution)
- `process_sync_responses()` - API response handling
- `queue_sync_tasks_aggressive()` - Task orchestration with ahead-queuing
- FK resilience functions for deferred relationship processing

**Problem Resolution:**
- **Field mapping issues** → Reference architecture document field mappings
- **API authentication errors** → Check Basic Auth configuration
- **Rate limit issues** → Review API call batching and timing
- **FK resilience issues** → Reference deferred relationship processing functions

## ⚠️ CRITICAL REMINDERS

1. **Character-Level Precision**: Code must match specification exactly
2. **No Improvements**: Implementation contains ONLY what is specified
3. **Native Features Only**: Use EXCLUSIVELY native Supabase features
4. **Complete Validation**: Run ALL validation checkpoints before proceeding
5. **Final Statement**: You MUST verify "I implemented ONLY what was specified"

## 🎯 ULTIMATE VALIDATION

**Before marking this project complete, confirm:**

> "This MVP achieves complete 1:1 Medipim replication using only native Supabase features, deployed via structured migration files, with every field, every entity, and every relationship from Medipim API V4 replicated exactly as specified in medipim-replication-architecture.md. The implementation includes complete TypeScript type definitions and is production-ready."

**Migration-Based Implementation Verification:**
- ✅ All 6 migration files successfully deployed
- ✅ TypeScript types generated and accurate (database.types.ts)
- ✅ Zero Edge Functions - pure database architecture
- ✅ Complete 1:1 Medipim API replication achieved

**If you cannot honestly make this statement, the implementation is incomplete.**