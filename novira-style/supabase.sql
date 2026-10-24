-- NOVIRA STYLE prototype backend. Run in a NEW Supabase project's SQL Editor.
-- Public order requests are disabled until store_settings.config.accept_orders = true.
-- IMPORTANT: Add abuse prevention (Turnstile and rate limiting) before opening to the public.
create extension if not exists pgcrypto;
create table if not exists public.admins (
 user_id uuid primary key references auth.users(id) on delete cascade
);
create table if not exists public.products (
 id uuid primary key default gen_random_uuid(),
 name text not null check(length(trim(name)) between 1 and 120),
 description text not null default '', category text not null default 'Bracelets',
 price numeric(10,2) not null check(price > 0 and price < 1000000),
 stock integer not null default 0 check(stock >= 0),
 image_url text not null default '', featured boolean not null default false,
 active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.store_settings (
 id integer primary key check(id=1), config jsonb not null
);
insert into public.store_settings(id,config) values (1,$$ {
 "brand_name":"NOVIRA STYLE","tagline":"Little treasures, lovely moments.",
 "announcement":"Handmade with heart · Delivery across selected Indian locations",
 "logo_url":"","hero_image_url":"","contact_whatsapp":"",
 "shipping_kerala":75,"shipping_nearby":95,"shipping_other":120,
 "free_ship_kerala_threshold":499,"free_ship_enabled":false,"accept_orders":false
} $$::jsonb) on conflict(id) do nothing;
create table if not exists public.orders (
 id uuid primary key default gen_random_uuid(),
 order_code text unique not null,
 customer jsonb not null,
 items jsonb not null,
 subtotal numeric(10,2) not null,
 shipping_amount numeric(10,2) not null,
 estimated_total numeric(10,2) not null,
 status text not null default 'pending' check(status in ('pending','confirmed','awaiting_payment','paid','packed','shipped','delivered','cancelled')),
 created_at timestamptz not null default now()
);
create index if not exists products_active_idx on public.products(active);
create index if not exists orders_created_at_idx on public.orders(created_at desc);

create or replace function public.is_shop_admin() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.admins where user_id=(select auth.uid()));
$$;
revoke all on function public.is_shop_admin() from public;
grant execute on function public.is_shop_admin() to authenticated;

alter table public.admins enable row level security;
alter table public.products enable row level security;
alter table public.store_settings enable row level security;
alter table public.orders enable row level security;

-- Owner can discover only their own admin registration.
create policy "admin can see own registration" on public.admins for select to authenticated using(user_id = (select auth.uid()));
create policy "public read active products" on public.products for select to anon,authenticated using(active=true or public.is_shop_admin());
create policy "admin insert products" on public.products for insert to authenticated with check(public.is_shop_admin());
create policy "admin update products" on public.products for update to authenticated using(public.is_shop_admin()) with check(public.is_shop_admin());
create policy "admin delete products" on public.products for delete to authenticated using(public.is_shop_admin());
create policy "read shop settings" on public.store_settings for select to anon,authenticated using(true);
create policy "admin update settings" on public.store_settings for update to authenticated using(public.is_shop_admin()) with check(public.is_shop_admin());
create policy "admin read orders" on public.orders for select to authenticated using(public.is_shop_admin());
create policy "admin update orders" on public.orders for update to authenticated using(public.is_shop_admin()) with check(public.is_shop_admin());
-- Deliberately NO direct public order inserts / reads.

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
 values('shop-images','shop-images',true,5242880,array['image/png','image/jpeg','image/webp'])
 on conflict(id) do nothing;
create policy "public read shop images" on storage.objects for select to anon,authenticated using(bucket_id='shop-images');
create policy "admin upload shop images" on storage.objects for insert to authenticated with check(bucket_id='shop-images' and public.is_shop_admin());
create policy "admin delete shop images" on storage.objects for delete to authenticated using(bucket_id='shop-images' and public.is_shop_admin());

-- Order request stored server-side using actual listed product prices.
-- State is selected by the customer: confirm postcode and final postage BEFORE asking for payment.
create or replace function public.place_order_request(p_customer jsonb,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
 cfg jsonb; cust_state text; shipping numeric; subtotal_val numeric:=0; total_val numeric;
 item jsonb; prod record; qty integer; items_out jsonb:='[]'::jsonb; code text; order_id uuid;
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
    length(coalesce(p_customer->>'note',''))>500 or
    length(coalesce(p_customer->>'email',''))>200
 then raise exception 'Invalid delivery details'; end if;
 cust_state:=coalesce(p_customer->>'state','');
 if length(cust_state) not between 2 and 60 then raise exception 'Invalid state'; end if;
 for item in select value from jsonb_array_elements(p_items) loop
   if coalesce(item->>'product_id','') !~* '^[0-9a-f-]{36}$' then raise exception 'Invalid product'; end if;
   if coalesce(item->>'quantity','') !~ '^[0-9]+$' then raise exception 'Invalid quantity'; end if;
   qty:=(item->>'quantity')::int;
   if qty<1 or qty>20 then raise exception 'Invalid quantity'; end if;
   select id,name,price,stock,active into prod from public.products where id=(item->>'product_id')::uuid;
   if not found or not prod.active or prod.stock < qty then raise exception 'One or more products are unavailable'; end if;
   subtotal_val:=subtotal_val+prod.price*qty;
   items_out:=items_out||jsonb_build_array(jsonb_build_object('product_id',prod.id,'name',prod.name,'price',prod.price,'quantity',qty));
 end loop;
 if cust_state='Kerala' then
  shipping:=coalesce((cfg->>'shipping_kerala')::numeric,75);
  if coalesce((cfg->>'free_ship_enabled')::boolean,false) and subtotal_val>=coalesce((cfg->>'free_ship_kerala_threshold')::numeric,499) then shipping:=0; end if;
 elsif cust_state in ('Tamil Nadu','Karnataka') then shipping:=coalesce((cfg->>'shipping_nearby')::numeric,95);
 else shipping:=coalesce((cfg->>'shipping_other')::numeric,120);
 end if;
 if shipping<0 or shipping>10000 then raise exception 'Shipping configuration error'; end if;
 total_val:=subtotal_val+shipping;
 code:='NV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,10));
 insert into public.orders(order_code,customer,items,subtotal,shipping_amount,estimated_total)
 values(code,p_customer,items_out,subtotal_val,shipping,total_val) returning id into order_id;
 return jsonb_build_object('order_code',code,'order_id',order_id,'estimated_total',total_val);
end;
$$;
revoke all on function public.place_order_request(jsonb,jsonb) from public;
grant execute on function public.place_order_request(jsonb,jsonb) to anon,authenticated;
