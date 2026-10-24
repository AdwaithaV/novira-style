-- NOVIRA STYLE payment migration. FIRST run on a disposable TEST project.
-- Requires original supabase.sql and upgrade_orders.sql. Existing orders are preserved.
-- Never put service role credentials in client-side code.
create table if not exists public.novira_checkouts (
 id uuid primary key default gen_random_uuid(),
 order_id uuid not null unique references public.orders(id) on delete restrict,
 user_id uuid not null references auth.users(id),
 razorpay_order_id text unique,
 razorpay_payment_id text unique,
 amount_paise integer not null check(amount_paise > 0),
 state text not null default 'reserved' check(state in ('reserved','awaiting_payment','paid','expired','payment_review')),
 expires_at timestamptz not null default (now()+interval '15 minutes'),
 created_at timestamptz not null default now(),
 paid_at timestamptz,
 released_at timestamptz
);
create index if not exists novira_checkouts_user_time on public.novira_checkouts(user_id,created_at desc);
create table if not exists public.novira_email_outbox (
 id bigint generated always as identity primary key,
 order_id uuid not null references public.orders(id) on delete restrict,
 kind text not null check(kind in ('customer_paid','owner_paid','shipped')),
 recipient text not null,
 attempts integer not null default 0,
 sent_at timestamptz,
 locked_until timestamptz,
 last_error text,
 unique(order_id,kind)
);
create table if not exists public.novira_webhook_receipts (
 event_id text primary key,
 created_at timestamptz not null default now()
);
alter table public.novira_checkouts enable row level security;
alter table public.novira_email_outbox enable row level security;
alter table public.novira_webhook_receipts enable row level security;
-- No public table policies. Only trusted server functions (service_role) can read/write.
-- CRITICAL: Disable old unaudited order-reservation RPC even for signed-in users.
revoke all on function public.place_order_request(jsonb,jsonb) from PUBLIC,anon,authenticated;
update public.store_settings set config=jsonb_set(config,'{accept_orders}','false'::jsonb) where id=1;

create or replace function public.novira_reserve_checkout(p_user uuid,p_customer jsonb,p_items jsonb)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
declare cfg jsonb; ship numeric; subtotal numeric:=0; total numeric; item jsonb; prod record; qty int;
 out_items jsonb:='[]'::jsonb; o_id uuid; c_id uuid; code text; tok text;
begin
 if auth.role()<>'service_role' then raise exception 'Server only'; end if;
 select config into cfg from public.store_settings where id=1;
 if not coalesce((cfg->>'accept_orders')::boolean,false) then raise exception 'Shop checkout is closed'; end if;
 if not exists(select 1 from auth.users where id=p_user and email_confirmed_at is not null) then raise exception 'Verified customer account required'; end if;
 -- Limit held inventory to two pending orders per customer within 30 min.
 if (select count(*) from public.novira_checkouts where user_id=p_user and state in ('reserved','awaiting_payment') and expires_at>now())>=2 then raise exception 'Too many active checkouts'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items) not between 1 and 20 then raise exception 'Invalid basket'; end if;
 if jsonb_typeof(p_customer)<>'object' or length(trim(coalesce(p_customer->>'name',''))) not between 2 and 100
 or length(regexp_replace(coalesce(p_customer->>'phone',''),'[^0-9]','','g'))<>10
 or length(trim(coalesce(p_customer->>'address',''))) not between 5 and 300
 or length(trim(coalesce(p_customer->>'city',''))) not between 2 and 100
 or coalesce(p_customer->>'pincode','') !~ '^[0-9]{6}$'
 or length(coalesce(p_customer->>'note',''))>500 then raise exception 'Invalid delivery details'; end if;
 if coalesce(p_customer->>'state','') not in ('Kerala','Tamil Nadu','Karnataka') then raise exception 'Delivery location requires manual approval'; end if;
 -- Aggregate and lock in deterministic product order.
 for prod in select id,name,price,stock,active from public.products
   where id in (select distinct (x->>'product_id')::uuid from jsonb_array_elements(p_items) x
       where x->>'product_id' ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
   order by id for update
 loop
   qty := (select sum((x->>'quantity')::int) from jsonb_array_elements(p_items) x where x->>'product_id'=prod.id::text);
   if qty is null or qty<1 or qty>20 or not prod.active or prod.stock<qty then raise exception 'Product unavailable'; end if;
   update public.products set stock=stock-qty where id=prod.id;
   subtotal:=subtotal+prod.price*qty;
   out_items:=out_items||jsonb_build_array(jsonb_build_object('product_id',prod.id,'name',prod.name,'price',prod.price,'quantity',qty));
 end loop;
 if jsonb_array_length(out_items)=0 then raise exception 'Invalid basket'; end if;
 -- Validate every input before accepting: exactly one distinct valid product reference per entry.
 if exists(select 1 from jsonb_array_elements(p_items) x where x->>'product_id' !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' or coalesce(x->>'quantity','') !~ '^[0-9]{1,2}$')
 or (select count(distinct x->>'product_id') from jsonb_array_elements(p_items) x)<>jsonb_array_length(out_items) then raise exception 'Invalid basket item'; end if;
 if p_customer->>'state'='Kerala' then
   ship:=coalesce((cfg->>'shipping_kerala')::numeric,75);
   if coalesce((cfg->>'free_ship_enabled')::boolean,false) and subtotal>=coalesce((cfg->>'free_ship_kerala_threshold')::numeric,499) then ship:=0; end if;
 else ship:=coalesce((cfg->>'shipping_nearby')::numeric,95); end if;
 if ship<0 or ship>10000 then raise exception 'Invalid shipping rate'; end if;
 total:=subtotal+ship;
 if total<=0 or total>200000 then raise exception 'Invalid order amount'; end if;
 code:='NV-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
 tok:=substr(replace(gen_random_uuid()::text,'-','')||replace(gen_random_uuid()::text,'-',''),1,48);
 insert into public.orders(order_code,customer,items,subtotal,shipping_amount,estimated_total,status,tracking_token_hash)
 values(code,p_customer,out_items,subtotal,ship,total,'awaiting_payment',encode(sha256(convert_to(tok,'UTF8')),'hex')) returning id into o_id;
 insert into public.novira_checkouts(order_id,user_id,amount_paise) values(o_id,p_user,round(total*100)::int) returning id into c_id;
 return jsonb_build_object('checkout_id',c_id,'order_id',o_id,'order_code',code,'tracking_token',tok,'amount_paise',round(total*100)::int,'expires_in_seconds',900);
end $$;
revoke all on function public.novira_reserve_checkout(uuid,jsonb,jsonb) from PUBLIC,anon,authenticated;
grant execute on function public.novira_reserve_checkout(uuid,jsonb,jsonb) to service_role;

create or replace function public.novira_attach_razorpay(p_checkout uuid,p_razorpay_order text)
returns boolean language plpgsql security definer set search_path=pg_catalog as $$
begin
 if auth.role()<>'service_role' then raise exception 'Server only'; end if;
 update public.novira_checkouts set razorpay_order_id=p_razorpay_order,state='awaiting_payment'
 where id=p_checkout and state='reserved' and expires_at>now();
 if not found then raise exception 'Reservation expired'; end if;
 return true;
end $$;
revoke all on function public.novira_attach_razorpay(uuid,text) from PUBLIC,anon,authenticated;
grant execute on function public.novira_attach_razorpay(uuid,text) to service_role;

create or replace function public.novira_expire_checkouts()
returns integer language plpgsql security definer set search_path=pg_catalog as $$
declare c record; it jsonb; n integer:=0;
begin
 if auth.role()<>'service_role' then raise exception 'Server only'; end if;
 for c in select c0.*,o.items from public.novira_checkouts c0 join public.orders o on o.id=c0.order_id
   where c0.state in ('reserved','awaiting_payment') and c0.expires_at<now() order by c0.id for update of c0 skip locked
 loop
   update public.novira_checkouts set state='expired',released_at=now() where id=c.id;
   update public.orders set status='cancelled',inventory_released_at=now() where id=c.order_id;
   for it in select value from jsonb_array_elements(c.items) loop
     update public.products set stock=stock+(it->>'quantity')::int where id=(it->>'product_id')::uuid;
   end loop;
   n:=n+1;
 end loop;
 return n;
end $$;
revoke all on function public.novira_expire_checkouts() from PUBLIC,anon,authenticated;
grant execute on function public.novira_expire_checkouts() to service_role;

create or replace function public.novira_mark_paid(p_razorpay_order text,p_payment text,p_amount_paise int)
returns jsonb language plpgsql security definer set search_path=pg_catalog as $$
declare c record; o record; recipient text; result text;
begin
 if auth.role()<>'service_role' then raise exception 'Server only'; end if;
 select * into c from public.novira_checkouts where razorpay_order_id=p_razorpay_order for update;
 if not found then raise exception 'Unrecognized Razorpay order'; end if;
 if c.amount_paise<>p_amount_paise then raise exception 'Payment amount mismatch'; end if;
 if c.state='paid' then
   if c.razorpay_payment_id<>p_payment then raise exception 'Different payment on paid checkout'; end if;
   return jsonb_build_object('state','paid','order_id',c.order_id);
 end if;
 if c.state='expired' or c.expires_at<now() or c.state='payment_review' then
   update public.novira_checkouts set state='payment_review',razorpay_payment_id=p_payment where id=c.id;
   -- IMPORTANT: never silently mark a late payment as paid or double-restock.
   return jsonb_build_object('state','payment_review','order_id',c.order_id);
 end if;
 update public.novira_checkouts set state='paid',razorpay_payment_id=p_payment,paid_at=now() where id=c.id;
 update public.orders set status='paid' where id=c.order_id returning * into o;
 recipient:=o.customer->>'email';
 if recipient is not null and recipient ~* '^[^@ ]+@[^@ ]+\.[^@ ]+$' then
   insert into public.novira_email_outbox(order_id,kind,recipient) values(c.order_id,'customer_paid',recipient) on conflict do nothing;
 end if;
 return jsonb_build_object('state','paid','order_id',c.order_id);
end $$;
revoke all on function public.novira_mark_paid(text,text,int) from PUBLIC,anon,authenticated;
grant execute on function public.novira_mark_paid(text,text,int) to service_role;

-- Queue shipping updates when the administrator changes the order to shipped.
create or replace function public.novira_ship_email_queue()
returns trigger language plpgsql security definer set search_path=pg_catalog as $$
begin
 if new.status='shipped' and old.status is distinct from 'shipped' and new.customer->>'email' is not null then
   insert into public.novira_email_outbox(order_id,kind,recipient)
   values(new.id,'shipped',new.customer->>'email') on conflict do nothing;
 end if;
 return new;
end $$;
drop trigger if exists novira_ship_email_queue_trg on public.orders;
create trigger novira_ship_email_queue_trg after update on public.orders for each row execute function public.novira_ship_email_queue();
-- Do not enable accept_orders until a complete sandbox test, worker scheduler, and courier validation.
