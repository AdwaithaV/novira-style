-- NOVIRA STYLE: apply once AFTER supabase.sql. Test in a separate Supabase project first.
-- This reserves inventory on creation of an order REQUEST, not on successful payment.
-- Do not enable public orders until abuse protection, courier verification and payments are tested.
alter table public.orders add column if not exists tracking_token_hash text;
alter table public.orders add column if not exists courier_name text;
alter table public.orders add column if not exists tracking_number text;
alter table public.orders add column if not exists tracking_url text;
alter table public.orders add column if not exists shipped_at timestamptz;
alter table public.orders add column if not exists inventory_released_at timestamptz;
alter table public.orders add column if not exists archived_at timestamptz;
alter table public.orders add column if not exists updated_at timestamptz not null default now();
create table if not exists public.order_events (
  id bigint generated always as identity primary key,
  order_id uuid not null references public.orders(id) on delete cascade,
  status text not null,
  created_at timestamptz not null default now()
);
alter table public.order_events enable row level security;
drop policy if exists "admins read events" on public.order_events;
create policy "admins read events" on public.order_events for select to authenticated using(public.is_shop_admin());
create or replace function public.place_order_request(p_customer jsonb,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 cfg jsonb; cust_state text; shipping numeric; subtotal_val numeric:=0; total_val numeric;
 item record; prod record; qty integer; items_out jsonb:='[]'::jsonb; code text; order_id uuid; token text;
begin
 select config into cfg from public.store_settings where id=1;
 if cfg is null or coalesce((cfg->>'accept_orders')::boolean,false)=false then raise exception 'Orders are not open yet'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'Invalid basket'; end if;
 if jsonb_typeof(p_customer)<>'object' then raise exception 'Invalid customer'; end if;
 if length(trim(coalesce(p_customer->>'name',''))) not between 2 and 100 or
    length(regexp_replace(coalesce(p_customer->>'phone',''),'\D','','g'))<>10 or
    length(trim(coalesce(p_customer->>'address',''))) not between 5 and 300 or
    length(trim(coalesce(p_customer->>'city',''))) not between 2 and 100 or
    coalesce(p_customer->>'pincode','') !~ '^\d{6}$' or
    length(coalesce(p_customer->>'note',''))>500 or length(coalesce(p_customer->>'email',''))>200
 then raise exception 'Invalid delivery details'; end if;
 cust_state:=coalesce(p_customer->>'state','');
 if length(cust_state) not between 2 and 60 then raise exception 'Invalid state'; end if;
 -- Aggregate repeated product IDs; process in ID order to reduce deadlocks.
 for item in
   select (e.value->>'product_id')::uuid as product_id, sum((e.value->>'quantity')::integer)::integer as quantity
   from jsonb_array_elements(p_items) e(value)
   where e.value->>'product_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     and e.value->>'quantity' ~ '^[0-9]{1,2}$'
   group by 1 order by 1
 loop
   qty:=item.quantity;
   if qty<1 or qty>20 then raise exception 'Invalid quantity'; end if;
   select id,name,price,stock,active into prod from public.products where id=item.product_id for update;
   if not found or not prod.active or prod.stock<qty then raise exception 'One or more products are unavailable'; end if;
   update public.products set stock=stock-qty where id=item.product_id;
   subtotal_val:=subtotal_val+prod.price*qty;
   items_out:=items_out||jsonb_build_array(jsonb_build_object('product_id',prod.id,'name',prod.name,'price',prod.price,'quantity',qty));
 end loop;
 if (select count(*) from jsonb_array_elements(p_items))<>(select count(*) from jsonb_array_elements(items_out)) then
   -- Duplicate items are allowed; invalid items are not. Count valid inputs separately.
   if exists(select 1 from jsonb_array_elements(p_items) e where
     coalesce(e->>'product_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
     or coalesce(e->>'quantity','') !~ '^[0-9]{1,2}$') then raise exception 'Invalid basket item'; end if;
 end if;
 if jsonb_array_length(items_out)=0 then raise exception 'Invalid basket'; end if;
 if cust_state='Kerala' then
   shipping:=coalesce((cfg->>'shipping_kerala')::numeric,75);
   if coalesce((cfg->>'free_ship_enabled')::boolean,false) and subtotal_val>=coalesce((cfg->>'free_ship_kerala_threshold')::numeric,499) then shipping:=0; end if;
 elsif cust_state in ('Tamil Nadu','Karnataka') then shipping:=coalesce((cfg->>'shipping_nearby')::numeric,95);
 else shipping:=coalesce((cfg->>'shipping_other')::numeric,120);
 end if;
 if shipping<0 or shipping>10000 then raise exception 'Shipping configuration error'; end if;
 total_val:=subtotal_val+shipping;
 code:='NV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 token:=encode(gen_random_bytes(24),'hex');
 insert into public.orders(order_code,customer,items,subtotal,shipping_amount,estimated_total,tracking_token_hash)
 values(code,p_customer,items_out,subtotal_val,shipping,total_val,encode(digest(token,'sha256'),'hex')) returning id into order_id;
 insert into public.order_events(order_id,status) values(order_id,'pending');
 return jsonb_build_object('order_code',code,'order_id',order_id,'estimated_total',total_val,'tracking_token',token);
end;
$$;
revoke all on function public.place_order_request(jsonb,jsonb) from public;
grant execute on function public.place_order_request(jsonb,jsonb) to anon,authenticated;

-- Customer may read only their own order with a high-entropy tracking token.
create or replace function public.track_order(p_order_code text,p_token text)
returns jsonb language plpgsql stable security definer set search_path='' as $$
declare o record;
begin
 if length(coalesce(p_token,''))<>48 then return null; end if;
 select order_code,status,created_at,shipped_at,courier_name,tracking_number,tracking_url,
        estimated_total,items into o from public.orders
 where order_code=p_order_code and tracking_token_hash=encode(digest(p_token,'sha256'),'hex') and archived_at is null;
 if not found then return null; end if;
 return jsonb_build_object('order_code',o.order_code,'status',o.status,'created_at',o.created_at,
  'shipped_at',o.shipped_at,'courier',o.courier_name,'tracking_number',o.tracking_number,
  'tracking_url',o.tracking_url,'estimated_total',o.estimated_total,'items',o.items);
end;
$$;
revoke all on function public.track_order(text,text) from public;
grant execute on function public.track_order(text,text) to anon,authenticated;

-- Admin-controlled stock release ONLY, e.g. after cancellation review. Idempotent.
create or replace function public.release_cancelled_order_stock(p_order_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare o record; item jsonb;
begin
 if not public.is_shop_admin() then raise exception 'Not authorised'; end if;
 select id,status,items,inventory_released_at into o from public.orders where id=p_order_id for update;
 if not found then raise exception 'Order not found'; end if;
 if o.status<>'cancelled' then raise exception 'Cancel the order first'; end if;
 if o.inventory_released_at is not null then return false; end if;
 for item in select value from jsonb_array_elements(o.items) loop
   update public.products set stock=stock+(item->>'quantity')::int where id=(item->>'product_id')::uuid;
 end loop;
 update public.orders set inventory_released_at=now(),updated_at=now() where id=p_order_id;
 return true;
end;
$$;
revoke all on function public.release_cancelled_order_stock(uuid) from public;
grant execute on function public.release_cancelled_order_stock(uuid) to authenticated;

-- Prefer archiving to destructive deletion: retains financial/customer order trail.
create or replace function public.archive_order(p_order_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
begin
 if not public.is_shop_admin() then raise exception 'Not authorised'; end if;
 update public.orders set archived_at=now(), updated_at=now() where id=p_order_id;
 return found;
end;
$$;
revoke all on function public.archive_order(uuid) from public;
grant execute on function public.archive_order(uuid) to authenticated;

-- Record status changes and shipment dates for the admin/customer timeline.
create or replace function public.novira_order_status_audit()
returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.updated_at:=now();
 if new.status='shipped' and old.status is distinct from 'shipped' and new.shipped_at is null then new.shipped_at:=now(); end if;
 if new.status is distinct from old.status then
   insert into public.order_events(order_id,status) values(new.id,new.status);
 end if;
 return new;
end;
$$;
drop trigger if exists novira_order_status_audit_trg on public.orders;
create trigger novira_order_status_audit_trg before update on public.orders
for each row execute function public.novira_order_status_audit();

-- Admin can purge *unpaid, cancelled, manually released* test orders only.
-- Never auto-refund or auto-restock from a deletion.
create or replace function public.delete_cancelled_test_order(p_order_id uuid)
returns boolean language plpgsql security definer set search_path='' as $$
declare o record;
begin
 if not public.is_shop_admin() then raise exception 'Not authorised'; end if;
 select id,status,inventory_released_at into o from public.orders where id=p_order_id for update;
 if not found then return false; end if;
 if o.status<>'cancelled' or o.inventory_released_at is null then
   raise exception 'Only cancelled orders with manually released stock can be deleted. Preserve financial records.';
 end if;
 delete from public.orders where id=p_order_id;
 return true;
end;
$$;
revoke all on function public.delete_cancelled_test_order(uuid) from public;
grant execute on function public.delete_cancelled_test_order(uuid) to authenticated;
