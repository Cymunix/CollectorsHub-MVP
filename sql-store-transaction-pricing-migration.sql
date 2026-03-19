-- Run this in Supabase SQL editor to align existing environments with
-- condition-aware inventory and store transaction pricing lookups.

begin;

-- 1) Ensure condition is stored on inventory rows and uniqueness is condition-aware.
alter table if exists public.store_inventory
  add column if not exists item_condition text;

create index if not exists store_inventory_item_condition_idx
  on public.store_inventory(item_condition);

drop index if exists public.store_inventory_unique_item_variant_per_store_idx;
create unique index if not exists store_inventory_unique_item_variant_per_store_idx
  on public.store_inventory (
    store_code,
    catalog_item_id,
    coalesce(variant_id, '00000000-0000-0000-0000-000000000000'::uuid),
    coalesce(item_condition, '')
  );

-- Normalize existing values for more reliable matching.
update public.store_inventory
set item_condition = lower(btrim(item_condition))
where item_condition is not null
  and item_condition <> lower(btrim(item_condition));

-- 2) Ensure transaction headers can store condition summaries.
alter table if exists public.store_transactions
  add column if not exists condition_summary jsonb not null default '{}'::jsonb;

-- 3) Ensure transaction line table supports fast pricing lookups by item/condition.
create index if not exists store_transaction_items_item_condition_idx
  on public.store_transaction_items(item_condition);

create index if not exists store_transaction_items_line_type_idx
  on public.store_transaction_items(line_type);

create index if not exists store_transaction_items_lookup_idx
  on public.store_transaction_items (catalog_item_id, variant_id, item_condition, line_type, created_at desc);

-- Normalize existing line conditions for matching.
update public.store_transaction_items
set item_condition = lower(btrim(item_condition))
where item_condition is not null
  and item_condition <> lower(btrim(item_condition));

commit;
