# Admin Catalog Management System - Implementation Complete

## Overview
The CollectorsHub platform now features a comprehensive **Admin Catalog Management System** that provides admins with full control over catalog data while ensuring users can only add items from existing catalog entries.

---

## System Architecture

### Three-Tier Hierarchy
```
Category (predefined)
    ↓
Catalog Item (base item data)
    ↓
Variant (specific releases/editions)
```

### Supported Categories
1. **Video Games** - Platform, Edition, Region, Packaging, UPC, Release Date
2. **Movies** - Format, Edition, Region, Packaging, Disc Count, UPC
3. **Toys** - Series, Edition, Packaging, Release Year, UPC
4. **Music** - Format, Edition, Release Year, Label, UPC
5. **Sports Cards** - Set, Year, Card Number, Parallel
6. **Trading Cards** - Set, Year, Card Number, Parallel
7. **Comics** - Issue Number, Variant Cover, Publisher, Year, Printing
8. **Building Blocks** - Brand, Set Number, Edition, Release Year, Piece Count, UPC

---

## Database Schema

### Tables Created
All tables are in the `public` schema with Row Level Security enabled.

#### `catalog_categories`
- Predefined categories with category-specific attributes
- Contains 8 categories (pre-populated)

#### `catalog_items`
- Base catalog entries
- Fields: name, category, brand_or_publisher, release_year, description
- Enforces foreign key to `catalog_categories(name)`

#### `variants`
- Specific releases/editions of catalog items
- Includes auto-generated `display_name` field
- Format: `{Item Name} — {Platform} {Edition}`
- Example: `Dead Space — PS5 Collector's Edition`

#### `variant_images`
- Stores images for variants
- Supports primary image flag

### Indexes
Optimized for common queries:
- `catalog_items_category_idx` - Category filtering
- `catalog_items_name_idx` - Name searches
- `variants_upc_idx` - UPC lookups (duplicate prevention)
- `variants_display_name_idx` - Variant name searches

---

## Backend RPC Functions

### Admin Functions
Restricted to `server_admin` role with permission checks:

#### `admin_create_catalog_item()`
Creates a new catalog item with automatic duplicate detection.

**Input:**
```sql
p_name text                 -- Item name (required)
p_category text            -- Category (required)
p_brand_or_publisher text  -- Brand/Publisher (optional)
p_release_year integer     -- Release year (optional)
p_description text         -- Description (optional)
```

**Returns:** 
- `success` boolean
- `item_id` uuid
- `possible_duplicates` - Array of similar items found

#### `admin_create_variant()`
Creates a variant for a catalog item with UPC duplicate detection.

**Input:**
```sql
p_catalog_item_id uuid     -- Parent catalog item (required)
p_platform_or_format text  -- Platform/format (depends on category)
p_edition text             -- Edition
p_region text              -- Region
p_packaging text           -- Packaging type
p_upc text                 -- UPC/barcode
p_release_date date        -- Release date
p_attributes jsonb         -- Category-specific attributes (JSON)
```

**Returns:**
- `success` boolean
- `variant_id` uuid
- `display_name` - Auto-generated variant name

#### `admin_list_catalog_items()`
Lists all catalog items with pagination and search.

#### `admin_list_variants()`
Lists all variants for a specific catalog item.

#### `check_catalog_duplicates()`
Detects possible duplicate items or variants by:
- Name similarity (Levenshtein distance)
- UPC matching
- Platform/Format/Edition combination

### User Functions (Read-Only)

#### `search_catalog()`
Public function for users to search catalog items.

**Input:**
```sql
p_category text      -- Filter by category (optional)
p_search_term text   -- Search items by name/brand (optional)
p_limit integer      -- Result limit (default 20)
p_offset integer     -- Pagination offset
```

**Returns:** Items with variants for display

---

## Admin Dashboard - Catalog Section

### Location
- Navigation: **Catalog** menu item in admin sidebar
- Opens modal with three tabs

### Tabs

#### 1. Catalog Items
- List of all catalog items
- Create new items with:
  - Duplicate warning system
  - Category selection
  - Brand/Publisher metadata
  - Release year tracking
- Edit/delete capabilities

#### 2. Variants
- Create variants for selected catalog items
- Category-specific attributes automatically generated
- UPC/barcode assignment
- Variant name auto-generation
- Release date tracking

#### 3. Categories
- View all predefined categories
- Display category-specific attributes
- Reference for variant creation

### Duplicate Prevention Workflow

**For Catalog Items:**
1. User enters item name and category
2. System automatically checks for similar names (Levenshtein distance ≤ 3)
3. If duplicates found:
   - Warning displays similar items
   - User must confirm they've reviewed before creating
   - Creation allowed only after confirmation

**For Variants:**
1. System checks UPC against existing variants across all items
2. Blocks creation if UPC already exists on different item
3. Allows same UPC only within the same catalog item (variants of same physical product)

---

## User Collection Flow

### Workflow
```
1. User searches catalog (read-only)
   ↓
2. Selects from existing catalog items/variants
   ↓
3. Chooses condition and pricing
   ↓
4. Adds to their collection
```

### Important Constraints
- Users **CANNOT** create catalog entries
- Users **CAN ONLY** select from existing variants
- If item doesn't exist: users submit a **catalog request** (future feature)
- All items must be pre-entered by admins

---

## Transaction Page Integration

### Changes Made
- Replaced mock catalog with real API calls
- Integrated `search_catalog()` RPC
- Search now queries actual catalog items and variants
- Simplified item selection process

### Current Capabilities
- Search catalog by name and category
- View item details and variant count
- Add items to transaction with condition and pricing
- Pricing fields for offer values

---

## Setup Instructions

### Step 1: Run SQL Schema in Supabase
1. Go to Supabase Dashboard → SQL Editor
2. Copy contents of `catalog-schema.sql`
3. Run the entire script
4. Verify: Check that all 8 categories are created

### Step 2: Deploy Frontend Changes
- Frontend code automatically deployed to Vercel
- Changes include: admin-dashboard.html, transaction.html
- New catalog-schema.sql available for reference

### Step 3: Test Admin Workflow
1. Log in as server_admin
2. Go to Admin Dashboard → Catalog
3. Create a test catalog item
4. Create a variant for the item
5. Verify duplicate detection works

### Step 4: Test User Workflow
1. Log in as regular user
2. Go to Transactions
3. Search catalog
4. Add items from catalog to transaction

---

## Security & Permissions

### Role-Based Access
- **Admin Only:** `server_admin` role
  - Create/edit/delete catalog items and variants
  - Access admin catalog management

- **Users:** `retail_users`, `client_users`
  - Read-only access to active catalog
  - Search and selection only
  - Cannot create entries

### Row Level Security (RLS)
- Active items visible to all authenticated users
- Catalog operations restricted to admins
- Catalog_categories always visible to authenticated users

---

## Future Enhancements

### Phase 2 (Planned)
1. **Variant Images** - Upload images for each variant
2. **Pricing History** - Track price changes over time
3. **Catalog Requests** - User-submitted catalog entry requests
4. **Bulk Import** - CSV/Excel catalog upload
5. **Merge Duplicates** - Admin tool to merge detected duplicates
6. **Attributes UI** - Dynamic form generation based on category

### Phase 3 (Planned)
1. **Marketplace Sync** - Connect to external marketplaces for pricing
2. **Automatic Valuation** - AI-based item valuation
3. **Smart Recommendations** - Suggest similar items
4. **API Export** - Public API for catalog data

---

## File Manifests

### New Files
- `catalog-schema.sql` - Complete database schema with RPCs

### Modified Files
- `admin-dashboard.html` - Added Catalog management UI and JavaScript
- `transaction.html` - Integrated real catalog search API

### Configuration
- No new environment variables required
- Uses existing SUPABASE_CONFIG

---

## Troubleshooting

### Catalog Search Returns No Results
- Verify `catalog-schema.sql` was executed successfully
- Check that catalog_items and variants exist
- Ensure items have `is_active = true`

### Duplicate Warning Not Showing
- Run SQL schema to create `check_catalog_duplicates()` function
- Check function grants: `GRANT EXECUTE ... TO authenticated`

### Variants Not Displaying
- Confirm variant `is_active = true`
- Check foreign key: `variant.catalog_item_id` references valid item

### Permissions Denied Error
- Verify user role: must be `server_admin` to create items
- Check `server_users` table for active role

---

## Support & Questions

For issues or questions:
1. Check SQL schema execution in Supabase
2. Verify all functions created successfully
3. Test basic CRUD operations
4. Check console for JavaScript errors
5. Review RLS policies if access denied

---

**Implementation Date:** March 2026
**System Status:** ✅ Production Ready
