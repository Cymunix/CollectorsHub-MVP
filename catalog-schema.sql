-- ============================================================
-- catalog-schema.sql
-- Complete catalog management system with category-specific attributes
-- Run in Supabase SQL Editor (as service_role or superuser)
-- ============================================================

-- Catalog Categories (predefined)
CREATE TABLE IF NOT EXISTS public.catalog_categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE,
  description text,
  attributes jsonb NOT NULL DEFAULT '[]'::jsonb,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Base catalog items
CREATE TABLE IF NOT EXISTS public.catalog_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL,
  category text NOT NULL REFERENCES public.catalog_categories(name) ON UPDATE CASCADE,
  brand_or_publisher text,
  release_year integer,
  description text,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Variants represent specific releases of catalog items
CREATE TABLE IF NOT EXISTS public.variants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  catalog_item_id uuid NOT NULL REFERENCES public.catalog_items(id) ON DELETE CASCADE,
  platform_or_format text,
  edition text,
  region text,
  packaging text,
  upc text,
  release_date date,
  attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
  display_name text GENERATED ALWAYS AS (
    CASE
      WHEN edition IS NOT NULL AND platform_or_format IS NOT NULL
        THEN (SELECT name FROM public.catalog_items WHERE id = variants.catalog_item_id) || ' — ' || COALESCE(platform_or_format, '') || ' ' || COALESCE(edition, '')
      WHEN edition IS NOT NULL
        THEN (SELECT name FROM public.catalog_items WHERE id = variants.catalog_item_id) || ' — ' || COALESCE(edition, '')
      WHEN platform_or_format IS NOT NULL
        THEN (SELECT name FROM public.catalog_items WHERE id = variants.catalog_item_id) || ' — ' || COALESCE(platform_or_format, '')
      ELSE (SELECT name FROM public.catalog_items WHERE id = variants.catalog_item_id)
    END
  ) STORED,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- Variant images
CREATE TABLE IF NOT EXISTS public.variant_images (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  variant_id uuid NOT NULL REFERENCES public.variants(id) ON DELETE CASCADE,
  image_url text NOT NULL,
  alt_text text,
  is_primary boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Create beneficial indexes
CREATE INDEX IF NOT EXISTS catalog_items_category_idx ON public.catalog_items(category);
CREATE INDEX IF NOT EXISTS catalog_items_name_idx ON public.catalog_items(name);
CREATE INDEX IF NOT EXISTS variants_catalog_item_idx ON public.variants(catalog_item_id);
CREATE INDEX IF NOT EXISTS variants_upc_idx ON public.variants(upc);
CREATE INDEX IF NOT EXISTS variants_display_name_idx ON public.variants(display_name);

-- Enable RLS
ALTER TABLE public.catalog_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.variants ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.variant_images ENABLE ROW LEVEL SECURITY;

-- RLS Policies (allow authenticated users to read active catalog)
CREATE POLICY "Allow read active catalog_categories" ON public.catalog_categories
  FOR SELECT USING (is_active = true);

CREATE POLICY "Allow read active catalog_items" ON public.catalog_items
  FOR SELECT USING (is_active = true);

CREATE POLICY "Allow read active variants" ON public.variants
  FOR SELECT USING (is_active = true);

CREATE POLICY "Allow read variant_images" ON public.variant_images
  FOR SELECT USING (true);

-- Triggers for updated_at
CREATE OR REPLACE FUNCTION public.set_catalog_items_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_variants_updated_at()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS catalog_items_set_updated_at ON public.catalog_items;
CREATE TRIGGER catalog_items_set_updated_at
BEFORE UPDATE ON public.catalog_items
FOR EACH ROW
EXECUTE FUNCTION public.set_catalog_items_updated_at();

DROP TRIGGER IF EXISTS variants_set_updated_at ON public.variants;
CREATE TRIGGER variants_set_updated_at
BEFORE UPDATE ON public.variants
FOR EACH ROW
EXECUTE FUNCTION public.set_variants_updated_at();

-- Insert predefined catalog categories
INSERT INTO public.catalog_categories (name, description, attributes)
VALUES
  ('Video Games', 'Video games for various platforms', '["Platform", "Edition", "Region", "Packaging", "UPC", "Release Date"]'::jsonb),
  ('Movies', 'Films and motion pictures', '["Format", "Edition", "Region", "Packaging", "Disc Count", "UPC"]'::jsonb),
  ('Toys', 'Collectible toys and figures', '["Series", "Edition", "Packaging", "Release Year", "UPC"]'::jsonb),
  ('Music', 'Music albums and recordings', '["Format", "Edition", "Release Year", "Label", "UPC"]'::jsonb),
  ('Sports Cards', 'Sports trading cards', '["Set", "Year", "Card Number", "Parallel"]'::jsonb),
  ('Trading Cards', 'Collectible trading cards', '["Set", "Year", "Card Number", "Parallel"]'::jsonb),
  ('Comics', 'Comic books and graphic novels', '["Issue Number", "Variant Cover", "Publisher", "Year", "Printing"]'::jsonb),
  ('Building Blocks', 'Building block sets like LEGO', '["Brand", "Set Number", "Edition", "Release Year", "Piece Count", "UPC"]'::jsonb)
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  attributes = EXCLUDED.attributes;

-- RPC: Check for duplicate catalog items or variants
CREATE OR REPLACE FUNCTION public.check_catalog_duplicates(
  p_name text,
  p_category text,
  p_platform_or_format text DEFAULT NULL,
  p_edition text DEFAULT NULL,
  p_upc text DEFAULT NULL
)
RETURNS TABLE (
  match_type text,
  item_id uuid,
  item_name text,
  variant_display_name text,
  similarity_score float8
)
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  -- Check for similar catalog item names
  SELECT 
    'catalog_item'::text,
    ci.id,
    ci.name,
    NULL::text,
    1.0 - (levenshtein(ci.name, p_name)::float8 / GREATEST(length(ci.name), length(p_name))::float8)
  FROM public.catalog_items ci
  WHERE ci.category = p_category
    AND (
      ci.name ILIKE p_name
      OR levenshtein(ci.name, p_name) <= 3
    )
  
  UNION ALL
  
  -- Check for similar variants by UPC
  SELECT
    'variant_upc'::text,
    ci.id,
    ci.name,
    v.display_name,
    1.0
  FROM public.variants v
  JOIN public.catalog_items ci ON v.catalog_item_id = ci.id
  WHERE p_upc IS NOT NULL
    AND v.upc = p_upc
  
  UNION ALL
  
  -- Check for similar variants by attributes
  SELECT
    'variant_similar'::text,
    ci.id,
    ci.name,
    v.display_name,
    0.8
  FROM public.variants v
  JOIN public.catalog_items ci ON v.catalog_item_id = ci.id
  WHERE ci.category = p_category
    AND v.platform_or_format = p_platform_or_format
    AND v.edition = p_edition
  LIMIT 10;
$$;

-- RPC: Create catalog item with duplicate check
CREATE OR REPLACE FUNCTION public.admin_create_catalog_item(
  p_name text,
  p_category text,
  p_brand_or_publisher text DEFAULT NULL,
  p_release_year integer DEFAULT NULL,
  p_description text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid;
  v_caller_role text;
  v_item_id uuid;
  v_duplicates jsonb;
BEGIN
  -- Verify caller is admin/moderator/catalog manager
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.server_users
  WHERE auth_user_id = v_caller_id AND is_active = true
  LIMIT 1;

  IF v_caller_role IS DISTINCT FROM 'server_admin' THEN
    RAISE EXCEPTION 'Permission denied: server_admin role required';
  END IF;

  -- Validate inputs
  IF trim(p_name) = '' OR trim(p_category) = '' THEN
    RAISE EXCEPTION 'Item name and category are required';
  END IF;

  -- Check category exists
  IF NOT EXISTS (SELECT 1 FROM public.catalog_categories WHERE name = p_category AND is_active = true) THEN
    RAISE EXCEPTION 'Category does not exist';
  END IF;

  -- Check for duplicates
  SELECT jsonb_agg(row_to_json(t)) INTO v_duplicates
  FROM (
    SELECT * FROM public.check_catalog_duplicates(p_name, p_category)
    ORDER BY similarity_score DESC
    LIMIT 5
  ) t;

  -- Insert catalog item
  INSERT INTO public.catalog_items (name, category, brand_or_publisher, release_year, description)
  VALUES (trim(p_name), p_category, p_brand_or_publisher, p_release_year, p_description)
  RETURNING id INTO v_item_id;

  RETURN jsonb_build_object(
    'success', true,
    'item_id', v_item_id,
    'possible_duplicates', COALESCE(v_duplicates, '[]'::jsonb)
  );
END;
$$;

-- RPC: Create variant
CREATE OR REPLACE FUNCTION public.admin_create_variant(
  p_catalog_item_id uuid,
  p_platform_or_format text DEFAULT NULL,
  p_edition text DEFAULT NULL,
  p_region text DEFAULT NULL,
  p_packaging text DEFAULT NULL,
  p_upc text DEFAULT NULL,
  p_release_date date DEFAULT NULL,
  p_attributes jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id uuid;
  v_caller_role text;
  v_variant_id uuid;
  v_display_name text;
BEGIN
  -- Verify caller is admin/moderator/catalog manager
  v_caller_id := auth.uid();
  IF v_caller_id IS NULL THEN
    RAISE EXCEPTION 'Not authenticated';
  END IF;

  SELECT role INTO v_caller_role
  FROM public.server_users
  WHERE auth_user_id = v_caller_id AND is_active = true
  LIMIT 1;

  IF v_caller_role IS DISTINCT FROM 'server_admin' THEN
    RAISE EXCEPTION 'Permission denied: server_admin role required';
  END IF;

  -- Verify catalog item exists
  IF NOT EXISTS (SELECT 1 FROM public.catalog_items WHERE id = p_catalog_item_id) THEN
    RAISE EXCEPTION 'Catalog item not found';
  END IF;

  -- Check for duplicate variant by UPC if provided
  IF p_upc IS NOT NULL AND p_upc != '' THEN
    IF EXISTS (SELECT 1 FROM public.variants WHERE upc = p_upc AND catalog_item_id != p_catalog_item_id) THEN
      RAISE EXCEPTION 'A variant with this UPC already exists for a different catalog item';
    END IF;
  END IF;

  -- Build display name from item name and params
  SELECT ci.name INTO v_display_name
  FROM public.catalog_items ci
  WHERE ci.id = p_catalog_item_id
  LIMIT 1;
  v_display_name := COALESCE(v_display_name, '')
    || COALESCE(' — ' || NULLIF(trim(p_platform_or_format), ''), '')
    || COALESCE(' ' || NULLIF(trim(p_edition), ''), '');

  -- Insert variant
  INSERT INTO public.variants (
    catalog_item_id,
    platform_or_format,
    edition,
    region,
    packaging,
    upc,
    release_date,
    attributes
  )
  VALUES (
    p_catalog_item_id,
    NULLIF(trim(p_platform_or_format), ''),
    NULLIF(trim(p_edition), ''),
    NULLIF(trim(p_region), ''),
    NULLIF(trim(p_packaging), ''),
    NULLIF(trim(p_upc), ''),
    p_release_date,
    COALESCE(p_attributes, '{}'::jsonb)
  )
  RETURNING id INTO v_variant_id;

  RETURN jsonb_build_object(
    'success', true,
    'variant_id', v_variant_id,
    'display_name', v_display_name
  );
END;
$$;

-- RPC: List all catalog items
CREATE OR REPLACE FUNCTION public.admin_list_catalog_items(
  p_category text DEFAULT NULL,
  p_search text DEFAULT NULL,
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'items', COALESCE(jsonb_agg(jsonb_build_object(
      'id', ci.id,
      'name', ci.name,
      'category', ci.category,
      'brand_or_publisher', ci.brand_or_publisher,
      'release_year', ci.release_year,
      'description', ci.description,
      'variant_count', (SELECT COUNT(*) FROM public.variants WHERE catalog_item_id = ci.id AND is_active = true),
      'is_active', ci.is_active,
      'created_at', ci.created_at
    )) FILTER (WHERE ci.id IS NOT NULL), '[]'::jsonb),
    'total', COUNT(*)::integer
  )
  FROM public.catalog_items ci
  WHERE (p_category IS NULL OR ci.category = p_category)
    AND (p_search IS NULL OR ci.name ILIKE '%' || p_search || '%' OR ci.brand_or_publisher ILIKE '%' || p_search || '%')
    AND ci.is_active = true
  LIMIT p_limit
  OFFSET p_offset;
$$;

-- RPC: List variants for a catalog item
CREATE OR REPLACE FUNCTION public.admin_list_variants(
  p_catalog_item_id uuid
)
RETURNS jsonb
LANGUAGE SQL
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'id', v.id,
    'display_name', v.display_name,
    'platform_or_format', v.platform_or_format,
    'edition', v.edition,
    'region', v.region,
    'packaging', v.packaging,
    'upc', v.upc,
    'release_date', v.release_date,
    'attributes', v.attributes,
    'image_count', (SELECT COUNT(*) FROM public.variant_images WHERE variant_id = v.id),
    'is_active', v.is_active,
    'created_at', v.created_at
  )) FILTER (WHERE v.id IS NOT NULL), '[]'::jsonb)
  FROM public.variants v
  WHERE v.catalog_item_id = p_catalog_item_id
  AND v.is_active = true;
$$;

-- RPC: Search catalog for users (read-only)
CREATE OR REPLACE FUNCTION public.search_catalog(
  p_category text DEFAULT NULL,
  p_search_term text DEFAULT NULL,
  p_limit integer DEFAULT 20,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE SQL
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'items', COALESCE(jsonb_agg(jsonb_build_object(
      'id', ci.id,
      'name', ci.name,
      'category', ci.category,
      'brand_or_publisher', ci.brand_or_publisher,
      'release_year', ci.release_year,
      'variants', (
        SELECT COALESCE(jsonb_agg(jsonb_build_object(
          'id', v.id,
          'display_name', v.display_name,
          'platform_or_format', v.platform_or_format,
          'edition', v.edition,
          'region', v.region,
          'preview_image', (SELECT image_url FROM public.variant_images WHERE variant_id = v.id AND is_primary = true LIMIT 1)
        )), '[]'::jsonb)
        FROM public.variants v
        WHERE v.catalog_item_id = ci.id AND v.is_active = true
      )
    )) FILTER (WHERE ci.id IS NOT NULL), '[]'::jsonb),
    'total', COUNT(*)::integer
  )
  FROM public.catalog_items ci
  WHERE ci.is_active = true
    AND (p_category IS NULL OR ci.category = p_category)
    AND (p_search_term IS NULL OR ci.name ILIKE '%' || p_search_term || '%' OR ci.brand_or_publisher ILIKE '%' || p_search_term || '%')
  LIMIT p_limit
  OFFSET p_offset;
$$;

GRANT EXECUTE ON FUNCTION public.check_catalog_duplicates(text, text, text, text, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_catalog_item(text, text, text, integer, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_create_variant(uuid, text, text, text, text, text, date, jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_catalog_items(text, text, integer, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_variants(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.search_catalog(text, text, integer, integer) TO authenticated;

SELECT 'Catalog schema and RPCs ready.' AS status;
