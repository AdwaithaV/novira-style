# NOVIRA STYLE — Pastel jewellery storefront

A delivery-only, mobile-first catalogue with shopping bag, delivery estimates, order requests and a no-code-for-the-owner product dashboard.

## Start the preview

```bash
npm install
npm run dev
```

Open the printed localhost address. In **preview mode**, visit **Store owner login** in the footer. Add/edit/delete products, upload an image, change stock, change the logo and try shipping settings. Demo data persists **only in your own browser**. It is not a public store and is not a secure shared database. The sample items are placeholders, not actual NOVIRA STYLE inventory.

## Make product edits appear to all visitors

1. Create a free Supabase project.
2. Run `supabase.sql` using the Supabase SQL Editor (read the SQL comments first).
3. In Supabase Authentication, create your own admin user (email and strong password).
4. Get the user's UUID from Authentication -> Users. Insert it using the SQL Editor:
   `insert into public.admins(user_id) values ('YOUR_ADMIN_USER_UUID');`
5. Copy `.env.example` to `.env.local`, then add your Supabase URL and **publishable / anon** key. **Never put a service-role/secret key in frontend code.**
6. Run `npm run dev` or `npm run build`, and sign in via the footer -> Store owner login.
7. Upload your actual NOVIRA STYLE logo, images and products. Configure real delivery rates; publish contact details and shipping/return/privacy policies.
8. Orders are **disabled by default**. Only enable order requests after thorough testing. The backend computes product totals and shipping estimates. Order requests are not payments. Confirm delivery, total, stock and how to pay directly with the customer before treating an order as accepted.
9. Deploy using Cloudflare Pages or another Vite-compatible static host. Build command: `npm run build`; output: `dist`. Configure the same public environment variables in the host settings.

## Delivery settings

- Delivery only: no college pickup or COD.
- Kerala: adjustable estimate; optional ₹499 free-shipping offer **disabled by default** pending margin checks.
- Tamil Nadu/Karnataka: separate estimate.
- Other states: estimate only, confirmed manually before payment.
- State selection is customer-reported, **not PIN-verified**. Do not automate payment based solely on these estimates. The order API recalculates estimates; it does not verify shipping serviceability. Once you have a shipping partner and your pickup PIN, integrate their rate/serviceability API before payment automation.

## Security and payments

- Database Row Level Security allows public reads of active products, but only admin users can modify products/config and view/update orders.
- Public order requests go through `place_order_request`, which recomputes prices from the database and has server-side input and rate limits per database role only (not IP limits).
- A public order form can be abused by bots. Before enabling public orders, add CAPTCHA/Turnstile and edge/API-level throttling. Consider storing less customer information and implementing a privacy/retention policy.
- No payment processing is connected. Never request or validate payment screenshots as proof of funds; add a gateway with **server-side verification** later.
- Database free tiers can sleep / have limits; ensure backups and service monitoring for real commerce.
- Product deletion may be blocked by active order references if SQL schemas change; archiving is safer.
- If you deploy via Pages, do not put `.env.local` in Git. Keep credentials separate.

## Your brand links

- Instagram: https://www.instagram.com/stylenovira/
- Pinterest: https://in.pinterest.com/adwaithav063/
- Facebook: https://www.facebook.com/profile.php?id=61594137953771
- YouTube: https://www.youtube.com/@nov1ra_studio

The social platforms did not permit reliable extraction of your profile logo. The preview uses a typographic wordmark. Replace it from your admin dashboard with the original logo image.
