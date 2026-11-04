# AddisHome — Production Deployment Runbook

This guide takes the AddisHome marketplace from local development to a live product
for the public and testers. The repo is split into three parts:

| Folder | What it is | Deploys to |
|---|---|---|
| `web/` | Vite + React + TanStack Start (SSR) web app | Vercel / Cloudflare Pages / Netlify |
| `mobile/` | Expo SDK 57 (React Native) app | Google Play + Apple App Store (via EAS) |
| `supabase/` | Database migrations, RLS, storage buckets, edge functions | Supabase Cloud |

---

## Current state (verified)

| Area | Status |
|---|---|
| Database | ✅ Live — project ref `bchojnitamkmnxvwqtdn`; schema, RLS, buckets, demo data in place |
| Edge functions | ⚠️ Exist (`send-push`, `telegram-bot`, `telegram-notify`) but **not deployed** |
| Web app | ⚠️ Builds clean (Nitro); not deployed to your own domain yet |
| Mobile app | ⚠️ Builds clean; **no EAS project yet** (no `projectId` → no production push tokens) |
| GitHub | ✅ `github.com/Hayredin950/addisfurnish`; `.env` correctly untracked |
| SMS OTP | ⚠️ Dev mode (code shown in console) — needs a real SMS provider |
| Supabase CLI | ❌ Not installed on this machine yet |

---

## Phase 0 — Repo hygiene (do this first, ~15 min)

1. Commit whatever is pending and push:

```bash
cd /home/hayredin/Documents/pro/addisfurnish
git add -A && git commit -m "Deployment prep" && git push origin main
```

2. **Security — verify `.env` is not tracked** (already done, but confirm):

```bash
git check-ignore web/.env mobile/.env && echo "ignored ✓"
```

3. Rotate the Supabase publishable/anon key once before the repo is shared with
   anyone: **Supabase → Project Settings → API keys → Roll**. The new key goes
   into `web/.env` and `mobile/.env` (both gitignored). Old key leaks (screenshots,
   CI logs) are the only real risk — the anon key is public by design, but rotation
   is cheap insurance.

4. Add a `LICENSE` and a privacy policy (stores require one). You can write the
   privacy policy by hand or use a generator; the app collects: name, phone,
   location (listings), and device push tokens.

---

## Phase 1 — Backend live (Supabase)

### 1.1 Install & link the CLI

```bash
npm i -g supabase            # or: brew install supabase/tap/supabase
supabase login               # opens browser; use the account that owns the project
cd /home/hayredin/Documents/pro/addisfurnish
supabase link --project-ref bchojnitamkmnxvwqtdn
```

### 1.2 Apply all migrations

```bash
supabase db push             # applies every migration in supabase/migrations/
```

This creates/updates all tables (listings, messages, notifications, favorites,
`push_tokens`, seller verification, etc.), RLS policies, the realtime
publication, and the `push_on_notification` trigger that calls the edge function.

### 1.3 Deploy edge functions + secrets

```bash
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy send-push        # push notifications
supabase functions deploy telegram-bot     # bot webhook: account linking, /stop, /help
supabase functions deploy telegram-notify  # channel posts + all Telegram alerts
```

Secrets are read from `supabase/functions/.env` — copy the template at
`supabase/functions/.env.example` and fill in real values first. All three
functions need `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`; `send-push`
optionally takes `EXPO_ACCESS_TOKEN`. Telegram setup (creating the bot and the
channel, registering the webhook) is documented in
[`supabase/functions/README.md`](supabase/functions/README.md).

> Note: `send-push` currently sends to Expo's public push API without a token
> (fine for MVP). Add `EXPO_ACCESS_TOKEN` from https://expo.dev/settings/access-tokens
> when you want strict project scoping.

### 1.4 Authentication configuration (Supabase dashboard → Authentication)

These are **mandatory** for real users:

1. **SMS provider (OTP login):** Supabase ships Twilio integration. For Ethiopian
   gateways (Afromessage, GeezSMS, Ethio Telecom), use the **Custom SMS provider
   webhook / Auth Hook** — Supabase calls your webhook with the OTP, you forward
   it to the gateway. Until this is set, OTP codes print to the console (dev mode).
2. **Email provider:** Supabase's built-in mail only delivers to whitelisted
   addresses. Connect **Resend** or SMTP under **Authentication → SMTP** so
   password-reset/welcome emails actually arrive.
3. **Google OAuth:** add Client ID/Secret if you want "Continue with Google".
4. **Redirect URLs:** add your production domain(s) to the allowlist. The mobile
   app uses the `addisfurnish://` deep-link scheme — add `addisfurnish://` too.
5. **Rate limits:** keep the built-in OTP rate limits (default is fine).

### 1.5 Project settings

- **Backups:** Free tier has **no backups** and pauses after 1 week of inactivity.
  Upgrade to **Pro ($25/mo)** for PITR backups + no pause.
- **Custom domain:** Optional; the default `*.supabase.co` URL works fine.

---

## Phase 2 — Web app deploy (Vercel recommended)

The web app is TanStack Start + Nitro (SSR). Pick the deploy target at build
time with `NITRO_PRESET`:

| Target | Build command | Output |
|---|---|---|
| Vercel | `NITRO_PRESET=vercel npm run build` | `.vercel/output` (auto-detected) |
| Cloudflare Pages | `NITRO_PRESET=cloudflare-module npm run build` | `.output` |
| Node server | `npm run build` | `.output` (run `node .output/server/index.mjs`) |

**Option A — Vercel (recommended):**

The Nitro Vercel build already emits a proper SSR output (`.vercel/output/`
with a `functions/__server.func` serverless function), so Vercel detects
everything automatically. Do **not** add a `vercel.json` SPA rewrite — it would
bypass the SSR function and break routes/auth.

1. Push the repo to GitHub (already at `github.com/Hayredin950/addisfurnish`).
2. Vercel dashboard → **Add New… → Project** → import `Hayredin950/addisfurnish`.
3. **Root directory:** `web`
4. **Install command:** `npm ci` (a `package-lock.json` is committed)
5. **Build command:** `NITRO_PRESET=vercel npm run build`
6. **Output directory:** leave empty — Nitro writes `.vercel/output` and Vercel
   picks it up automatically.
7. **Environment variables** (Project → Settings → Environment Variables):
   `VITE_SUPABASE_URL`, `VITE_SUPABASE_PUBLISHABLE_KEY`, and optionally
   `VITE_SITE_URL` (your production domain, e.g. `https://addisfurnish.vercel.app` — used
   for the og:image URL in social shares).
8. Deploy, then attach your custom domain under **Settings → Domains**.

**Option B — Cloudflare Pages:** root `web/`, build
`NITRO_PRESET=cloudflare-module npm run build`, output directory `.output`,
same env vars.

**Option C — Node hosting (Railway / Render / Fly):** root `web/`, build
`npm run build`, start command `node .output/server/index.mjs`.

---

## Phase 3 — Mobile app (EAS builds → stores)

### 3.1 One-time Expo setup

```bash
cd mobile
npm install
npx eas-cli@latest login            # expo.dev account
npx eas-cli@latest init             # creates eas.json + adds extra.eas.projectId to app.json
npx eas-cli@latest build:configure
```

`eas init` is what makes production push tokens work — the `projectId` is
required by `getExpoPushTokenAsync()`.

### 3.2 Build the app

```bash
npx eas build --profile development --platform android   # dev client (Expo Go for quick tests)
npx eas build --profile preview --platform android       # APK for testers (internal distribution)
npx eas build --profile production --platform android    # AAB for Play Store
npx eas build --profile production --platform ios        # needs Apple Developer $99/yr
```

`mobile/eas.json` already contains `development` / `preview` / `production`
profiles — edit as needed.

### 3.3 Distribution to testers (before store approval)

- **Cheapest:** share the `preview` APK link EAS gives you (anyone with the link
  installs it; Expo Go also works for early tests).
- **Google:** Play Console → **Internal testing** track (upload the AAB) → add
  tester emails. No review needed for internal track.
- **Apple:** TestFlight → External testing needs a beta review (fast).

### 3.4 Store requirements checklist

- **Google Play Console:** one-time **$25** registration. AAB signed by EAS
  (auto-generated keystore). Fill store listing + privacy policy URL.
- **Apple Developer Program:** **$99/year**. App icon, screenshots, privacy
  policy; `NSCameraUsageDescription`, `NSPhotoLibraryUsageDescription`,
  `NSLocationWhenInUseUsageDescription` are already in `app.json`.
- **Phone OTP flow:** app must offer a fallback (email) in case SMS is flaky —
  already implemented in `mobile/src/app/auth.tsx`.
- **Push notifications:** `app.json` already configures
  `expo-notifications` with a default channel. Production push requires the
  EAS `projectId` from step 3.1.

---

## Phase 4 — Go live checklist

- [ ] `supabase db push` applied cleanly
- [ ] `send-push` + `telegram-bot` + `telegram-notify` deployed, secrets set
- [ ] Telegram webhook registered with `secret_token` (`supabase/functions/README.md`)
- [ ] SMS provider configured (OTP actually delivered to phones)
- [ ] Email provider (Resend/SMTP) configured
- [ ] Redirect URLs include production domain + `addisfurnish://`
- [ ] Web app deployed and reachable on your domain over HTTPS
- [ ] Mobile builds exist for Android + iOS; testers have a build
- [ ] `.env` confirmed untracked; anon key rotated before going public
- [ ] Privacy policy + terms live and linked in stores
- [ ] Supabase upgraded to Pro if you expect traffic (backups + no pause)

---

## Env var reference

| Where | Variable | Required | Notes |
|---|---|---|---|
| `web/.env` | `VITE_SUPABASE_URL` | ✅ | Public project URL |
| `web/.env` | `VITE_SUPABASE_PUBLISHABLE_KEY` | ✅ | Public anon/publishable key |
| `web/.env` | `VITE_SITE_URL` | optional | Production domain, e.g. `https://addisfurnish.vercel.app` (social share image) |
| `web/.env` | `SUPABASE_SERVICE_ROLE_KEY` | server-only | Secret — never in client bundles |
| `web/.env` | `VITE_TELEGRAM_BOT_USERNAME` | telegram only | Bot username, no `@`. Public; hides the Connect button when unset |
| `mobile/.env` | `EXPO_PUBLIC_SUPABASE_URL` | ✅ | Public project URL |
| `mobile/.env` | `EXPO_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | ✅ | Public anon/publishable key |
| `mobile/.env` | `EXPO_PUBLIC_TELEGRAM_BOT_USERNAME` | telegram only | Same value as the web one |
| edge fn | `SUPABASE_URL` | ✅ | Set via `supabase secrets set` |
| edge fn | `SUPABASE_SERVICE_ROLE_KEY` | ✅ | Secret |
| edge fn | `TELEGRAM_BOT_TOKEN` | telegram only | BotFather token — secret |
| edge fn | `TELEGRAM_CHANNEL_ID` | telegram only | e.g. `@addisfurnish_listings`; bot must be admin |
| edge fn | `TELEGRAM_WEBHOOK_SECRET` | telegram only | Authenticates Telegram's webhook calls — secret |
| edge fn | `SITE_URL` | telegram only | Public origin used to link alerts back to a listing |
| edge fn | `EXPO_ACCESS_TOKEN` | optional | Expo push API scoping |

---

## Estimated costs (MVP, monthly)

| Item | Cost |
|---|---|
| Supabase Free tier | $0 (upgrade to Pro ~$25/mo for backups) |
| Vercel Hobby / Cloudflare Pages + domain | ~$0–$10/mo |
| SMS (Ethiopian gateway) | pay-per-message (~$0.05–$0.10) |
| Resend email | free tier (3,000/mo) |
| Google Play | $25 one-time |
| Apple Developer | $99/yr |
| EAS builds / Expo push | free tier generous |
