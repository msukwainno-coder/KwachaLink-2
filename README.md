# KwachaLink — clean frontend rebuild

This is a clean React + TypeScript + Vite frontend intended to connect to the existing KwachaLink Supabase project. It replaces the mixed static HTML/JavaScript frontend; it does not create a new database.

## Important: no demo mode

- There are no mock users, sample listings, fake statistics, localStorage-backed accounts, or simulated payments.
- If Supabase environment variables are missing, the app displays a configuration warning and live data screens explain that they cannot load.
- Registration and login use Supabase Auth.
- Forex and Trade marketplace pages query the existing `offers` and `trade_listings` tables.
- Creating listings writes to those same tables using the signed-in user's actual Auth ID.
- Dashboard metrics query the signed-in user's live records.
- Admin visibility is based on the signed-in user's `user_roles` row. The admin route independently checks the role.

## 1. Configure the existing Supabase project

Copy `.env.example` to `.env` and set:

```env
VITE_SUPABASE_URL=https://YOUR_EXISTING_PROJECT_REF.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_EXISTING_PUBLISHABLE_OR_ANON_KEY
```

Use the existing KwachaLink project values from your Supabase dashboard. The publishable/anon key is intended for browser use; never place a service-role or secret key in this file.

## 2. Install and run

```bash
npm install
npm run dev
```

For a production build:

```bash
npm run build
npm run preview
```

## Current implementation scope

Implemented in this first clean rebuild:
- Responsive KwachaLink branding and homepage.
- Forex marketplace live read from `offers`.
- International Trade marketplace live read from `trade_listings`.
- Supabase Auth registration and login.
- Create Forex and Trade listings using the signed-in user's ID.
- Member dashboard live counts from existing tables.
- Existing `user_roles` lookup and guarded Admin Dashboard entry.
- USD-only price currency in the International Trade listing form.
- Initial five destination choices: Tanzania, South Africa, Dubai, UAE, China and Japan.

Not yet implemented; do not treat these as live:
- Connection request creation/acceptance UI.
- Private messaging and realtime notifications.
- Listing reactions/likes.
- Trade image upload to Supabase Storage.
- Profile editing and full privacy controls.
- Payment checkout (manual mobile money, bank transfer and PayChangu).
- Admin payment verification/settings and full administration modules.
- Chichewa translations and full language preference persistence.
- End-to-end and device testing.

These are the next development stages. Payment must not be simulated and membership must not activate until a verified admin approval or a properly verified PayChangu server event exists.

## Database files

`supabase/reference/kwachalink_consolidated_backend_migration.sql` is the SQL file supplied for this project. It is included for reference and review. **It has not been run by this build process.** Review it against the live schema and take a backup before applying any migration.

`supabase/reference/legacy_supabase_setup.sql` is from the uploaded ZIP. It contains policy changes that may conflict with the established RLS design. **Do not run it blindly.**

## Existing database field mapping used here

- Forex: `offers.user_id`, `offer_type`, `currency_from`, `currency_to`, `exchange_rate`, `amount`, `remaining_amount`, `country`, `description`, `status`.
- Trade: `trade_listings.user_id`, `listing_type`, `title`, `description`, `category`, `quantity`, `unit`, `estimated_price`, `currency`, `country`, `destination_country`, `status`.
- Authenticated member identity is obtained from `supabase.auth.getUser()`; the app does not accept a user ID supplied by the browser form.

If an existing RLS policy rejects a write, fix the actual auth/session or narrowly scoped policy issue after inspection. Do not weaken RLS as a workaround.
