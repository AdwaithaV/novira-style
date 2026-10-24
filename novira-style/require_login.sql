-- NOVIRA STYLE: require authenticated Supabase users for order requests.
-- Run once in your Supabase SQL Editor after backing up the database.
-- NOTE: this is NOT a payment-gateway integration.
-- Public ordering should stay disabled until verified payment and anti-abuse protections exist.
REVOKE EXECUTE ON FUNCTION public.place_order_request(jsonb,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.place_order_request(jsonb,jsonb) TO authenticated;
-- Keep checkout closed at DB level while payment integration is unfinished.
UPDATE public.store_settings
SET config = jsonb_set(config, '{accept_orders}', 'false'::jsonb)
WHERE id = 1;
