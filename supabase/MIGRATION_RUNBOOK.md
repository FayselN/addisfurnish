# AddisHome — Switching to the new Supabase project

The project moved from the old instance (`ctgulhtaefzsdfemggty`, managed by
another collaborator) to the new one owned by us: `bchojnitamkmnxvwqtdn`.

All config/env/Flutter files in this repo already point at the new project.
Migrations read their runtime URL/keys from the Encrypted Vault, so the SQL is
identical on both projects. What remains is bringing the new project up and
repointing the deployed apps.

Never commit real keys — the values below marked `<secret>` go into gitignored
env files or directly into the Supabase dashboard, never into git.

---

## Step 1 — Link the CLI

```bash
npm i -g supabase            # skip if installed
supabase login               # browser auth; use the account that OWNS the new project
supabase link --project-ref bchojnitamkmnxvwqtdn
```

## Step 2 — Apply all migrations

```bash
supabase db push
```

Creates every table, RLS policy, realtime publication, trigger and the storage
buckets (`profile-images`, `verification-docs`, etc.).

## Step 3 — Set the Vault secrets (required!)

The DB triggers (push + telegram) and admin email RPCs read the project URL and
keys from the Encrypted Vault. Without these the triggers silently fail.
Run in the **SQL Editor** of the new project (fill in the real values):

```sql
select vault.create_secret('https://bchojnitamkmnxvwqtdn.supabase.co', 'SUPABASE_URL');
select vault.create_secret('<publishable key>',   'SUPABASE_PUBLISHABLE_KEY');
select vault.create_secret('<secret key>',        'SUPABASE_SERVICE_ROLE_KEY');
```

Verify: `select name from vault.decrypted_secrets order by name;`

## Step 4 — Edge functions: secrets + deploy

Fill the remaining blanks in `supabase/functions/.env` (gitignored) — Telegram
bot token / webhook secret / Cloudinary — then:

```bash
supabase secrets set --env-file supabase/functions/.env

supabase functions deploy send-push
supabase functions deploy send-mail
supabase functions deploy telegram-bot
supabase functions deploy telegram-notify
supabase functions deploy cloudinary-sign
supabase functions deploy cloudinary-delete
```

(`config.toml` keeps `verify_jwt = false` only for the two telegram functions.)

## Step 5 — Email delivery (`supabase/scripts/setup-email.sh`)

Same Brevo credentials as before (get them from the friend or re-use the
account). This script deploys `send-mail`, writes token-only email templates,
sets OTP length, and enables the send-email **auth hook**:

```bash
SUPABASE_ACCESS_TOKEN=sbp_xxx \
SUPABASE_PROJECT_REF=bchojnitamkmnxvwqtdn \
BREVO_SMTP_USER=xxxxx@smtp-brevo.com \
BREVO_SMTP_KEY=xsmtpsib-... \
./supabase/scripts/setup-email.sh
```

## Step 6 — Re-register the Telegram webhook to the NEW project

```bash
curl -X POST "https://api.telegram.org/bot<bot-token>/setWebhook" \
  -d "url=https://bchojnitamkmnxvwqtdn.supabase.co/functions/v1/telegram-bot" \
  -d "secret_token=<TELEGRAM_WEBHOOK_SECRET>" \
  --data-urlencode 'allowed_updates=["message","callback_query"]'
```

⚠️ Keep `callback_query` in `allowed_updates` (see `supabase/functions/README.md`).
Also add the bot as **admin** of the `@addisfurnish_listings` channel (once).

## Step 7 — Auth settings (Dashboard → Authentication)

1. **Email**: after Step 5 this goes through the send-mail hook automatically.
2. **Google OAuth**: add the same Client ID/Secret as before
   (Flows → Google). The Flutter app's `GOOGLE_WEB_CLIENT_ID` stays unchanged.
3. **Redirect URLs**: add
   - `https://<production-web-domain>/**`
   - `http://localhost:8080/**`
   - `http://localhost:8081/**`
   - Flutter deep link: see `mobile1`'s link scheme (add it too)

## Step 8 — Data / storage continuity

Migrations recreate the buckets but **not the old files**. Existing Cloudinary
photos keep working (URLs are absolute). Old Supabase-storage photos point to
the old URL — if needed, re-upload demo images:

```bash
cd web && SUPABASE_URL=https://bchojnitamkmnxvwqtdn.supabase.co \
  SUPABASE_SERVICE_ROLE_KEY=<secret key> ./scripts/upload-demo-images.sh
```

Demo/seed data lives in migrations; user-generated content from the old
project would need `pg_dump`/CSV export — decide whether the old marketplace
data must survive before turning the old project off.

## Step 9 — Redeployments

**Web (Vercel)** — Project → Settings → Environment Variables, update:
- `VITE_SUPABASE_URL` → `https://bchojnitamkmnxvwqtdn.supabase.co`
- `VITE_SUPABASE_PUBLISHABLE_KEY` → new publishable key
- `SUPABASE_URL` → new URL (server side)
- `SUPABASE_SERVICE_ROLE_KEY` → new secret key
- (+ any `SUPABASE_PUBLISHABLE_KEY` server var if present)

Then **Redeploy** (redeploy from latest commit so variables take effect).

**Flutter (`mobile1/`)** — `.dart_defines.json` already updated in-repo; rebuild:

```bash
cd mobile1
flutter run --dart-define-from-file=.dart_defines.json   # dev check
flutter build apk --release --dart-define-from-file=.dart_defines.json
```

(Store builds: run the usual release pipeline with the same dart-define file.)

## Step 10 — Verify smoke tests

- [ ] Sign up with email → 6-digit code arrives
- [ ] OTP phone login (dev mode prints code to logs until SMS provider set)
- [ ] Create listing → photo upload works → file lands in storage bucket
- [ ] Insert a row in `notifications` → push/telegram trigger logs no error
- [ ] Telegram bot `/start` links an account, chime posts appear
- [ ] Admin promote flow emails arrive

## Step 11 — Retire the old project

Only after everything above passes: ask the friend to **pause** (then later
delete) `ctgulhtaefzsdfemggty`. Every client now points to the new ref, so the
old one can be turned off safely.
