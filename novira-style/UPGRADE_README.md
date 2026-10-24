# NOVIRA STYLE — Order & Inventory Upgrade (prototype, not live-payment-ready)

**Security first:** The Razorpay live key secret was shared in chat. Rotate it immediately via Razorpay Dashboard -> Account & Settings -> API Keys, deactivate the exposed key immediately, and never place keys in GitHub or client-side Vite variables. This package includes **NO** payment credentials and does **NOT** enable Razorpay payments.

## Included changes

- On successful **order request** creation, `place_order_request` locks relevant product records and immediately subtracts ordered quantities inside the transaction. When remaining quantity reaches zero, the listing shows Sold Out. Inventory remains deducted after shipping.
- Cancelling an order does **not** automatically return stock. As admin, explicitly select **Manually restore stock**, which is idempotent.
- Shipped/delivered status, courier name, AWB tracking number and official tracking URL in the admin order manager.
- Customer tracking portal accessible from navigation and footer using order code + unpredictable private tracking token issued on receipt. Token is stored as SHA-256 hash in DB. Only the order summary and shipment details are exposed, not customer address or contact info.
- Download order CSV and sales-only CSV (statuses: paid, packed, shipped, delivered), up to the 1,000 latest visible records. Protect exported CSVs because they contain personal customer data.
- Admin-only order archive (preferred). Permanent deletion is restricted to cancelled orders for which stock has been manually released. **Do not delete genuine payment/financial records**; this restricted deletion function is intended only for unpaid test records.

## Setup (read before applying)

1. **Keep `accept_orders` set to false** in Store Settings. Important: because stock is reserved on request, a bot can currently reserve all stock. Add CAPTCHA/Turnstile, throttling, an expiry/release policy requiring admin approval, and shipping verification before opening public orders. For paid checkout, instead create short-lived server-created reservations as part of a secure transaction and release expired unpaid reservations by an explicit audited rule.
2. Backup/export your current Supabase project first. Test against a **separate Supabase test project**, not live data.
3. Run the existing `supabase.sql` first (already done on your project). Then in Supabase SQL Editor run **`upgrade_orders.sql`** once. It changes the public `place_order_request` RPC and adds functions and fields.
4. Replace the website's `src/main.jsx` with the included updated file. CSS is unchanged.
5. Commit these modified files to GitHub and redeploy Cloudflare. Existing `VITE_SUPABASE_URL` and `VITE_SUPABASE_ANON_KEY` remain as before.
6. In a private browsing window, submit a **test** order only after you have temporarily enabled order requests in a throwaway test project. Check stock decrement, a zero-stock Sold Out label, the new order code and tracking token, public tracking lookup, admin courier edit, cancellation without restock, and admin manual restore. Turn order requests back off.
7. After verifying, test CSV download. Exported CSV is not proof of payment, and `paid` is an admin-set status until a verified Razorpay webhook is implemented.

## Still NOT implemented — do not accept live payments

- Razorpay order creation, secure checkout, signature verification, captured-payment/webhook reconciliation, refunds or payment settlement.
- Automated customer emails, owner emails, or SMS. These require configured providers and credentials. Use **Resend** for transactional email (sender-domain verification) and **MSG91** or similar for Indian transactional SMS (DLT sender/template approval). Supabase Edge Functions or a Cloudflare Worker with an authenticated webhook + durable retry queue should send notifications only after trusted server-side order creation and status changes.
- Courier API integration, PIN-code serviceability and live rates, actual shipment creation, automatic carrier-status updates.
- True production reservation lifecycle, fraud protection and comprehensive privacy/retention practices.

Never enable public order requests solely by applying this upgrade. It is a testable core for the next stage, not a production payment release.
