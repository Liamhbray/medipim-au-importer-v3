# CLAUDE.md

## Project Overview
MediPim Australia Importer v3 - A Supabase-based system for importing and synchronizing medical product data from MediPim's Australian database.

**Last Updated**: 2025-06-15 - Repository connected to Supabase for automated deployments

## Supabase Project Details
- **Project ID**: aggmcawyfbmzrdmojhab
- **Project Name**: medipim-au-sync
- **URL**: https://aggmcawyfbmzrdmojhab.supabase.co
- **Region**: ap-southeast-2
- **Database Version**: PostgreSQL 17.4.1.041
- **Status**: ACTIVE_HEALTHY

## Database Schema
The system manages medical product data with the following core tables:

### Core Product Data
- **products** (~1,200 records, 10MB): Main product catalog with pricing, identifiers (ARTG, EAN, SNOMED codes), and metadata
- **organizations** (~2,050 records): Manufacturers, distributors, and other entities
- **brands** (~733 records): Product brand information
- **public_categories** (~641 records): Hierarchical product categorization
- **media** (~500 records): Product images and documents

### Relationship Tables
- **product_organizations**: Links products to manufacturers/distributors
- **product_brands**: Product-brand associations
- **product_categories**: Product categorization mappings
- **product_media**: Product media associations

### Sync Management
- **sync_state**: Tracks synchronization status for each entity type
- **sync_errors**: Error logging for failed sync operations
- **deferred_relationships**: Temporary storage for relationships during import

## Local Project Structure

### Configuration
- **supabase/config.toml**: Local development configuration
  - Project ID: `medipim-au-importer-v3`
  - Local ports: API (54321), DB (54322), Studio (54323)
  - PostgreSQL 17, seeding enabled
  - Storage limit: 50MiB

### Database Migration
- **supabase/migrations/20250615101335_remote_schema.sql**: Complete schema migration from remote
  - Contains full production schema structure
  - Includes extensions: pg_cron, pg_net, pg_graphql, pg_stat_statements, pgcrypto
  - Production compatibility verified 2025-06-15

### Development Tools
- **supabase/types/database.types.ts**: TypeScript type definitions for database schema

### Commands
- `supabase start`: Start local development environment
- `supabase db reset`: Reset and reseed local database
- `supabase gen types typescript --local`: Generate TypeScript types

## Important Instructions
Do what has been asked; nothing more, nothing less.
NEVER create files unless they're absolutely necessary for achieving your goal.
ALWAYS prefer editing an existing file to creating a new one.
NEVER proactively create documentation files (*.md) or README files. Only create documentation files if explicitly requested by the User.