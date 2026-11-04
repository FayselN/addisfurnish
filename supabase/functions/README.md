# Telegram integration

Telegram is the notification layer for launch — cheaper than building push for
the web, and the app most Ethiopian users already have open. It does three
things:

| Piece | What it does | Who sees it |
| --- | --- | --- |
| **Public channel** | Every new listing auto-posts (photo, price, category, link) | Anyone, no account needed |
| **Buyer bot** | DMs listings matching the user's saved preferences | Opted-in buyers |
| **Seller bot** | Real-time "new message / callback / views" alerts | Linked sellers |

Everything runs on the free Bot API — no approval, no fees.

## Architecture

```
notifications INSERT ──┬─→ send-push       ──→ expo.dev
                       └─→ telegram-notify ──→ Telegram DM
listing published ───────→ telegram-notify ──→ channel post + matched-buyer DMs
t.me/<bot>?start=TOKEN ──→ telegram-bot    ──→ links chat_id to the account
```

Delivery lives in the **`telegram-notify`** edge function, so the web app, the
mobile app, admin actions and DB triggers all share one code path. A single
`notify_user()` call fans out to the in-app centre, push *and* Telegram.

Two details worth knowing:

- **Listing announcements are a client invoke, not a DB trigger.** `listing_images`
  rows are written *after* the `listings` row, so an `AFTER INSERT` trigger
  would fire before the cover photo exists and post a photo-less listing. Both
  apps call the function once their uploads finish; `listings.telegram_posted_at`
  dedupes.
- **The buyer broadcast is independent of the channel post.** It used to run
  inside it, behind two early returns, so matched buyers silently got nothing
  whenever the channel was unconfigured.

Keep "message seller" and "request callback" inside the app — Telegram is
purely the notification layer. Every alert links back to the listing so the
conversation returns to the platform and stays measurable.

---

## Setup

### 1. Create the bot

In Telegram, open **@BotFather** → `/newbot`

- Display name: `AddisHome`
- Username: must end in `bot` — e.g. `addisfurnish_bot`

It replies with a token like `8123456789:AAH…`. **Treat it as a password** — it
belongs in `supabase/functions/.env` (gitignored), never in a migration or a
`VITE_`/`EXPO_PUBLIC_` variable.

Optionally set `/setdescription`, `/setabouttext`, `/setuserpic`, and
`/setcommands`:

```
start - Connect your AddisHome account
help - What this bot does
stop - Stop receiving alerts
```

### 2. Create the public channel

Telegram → New Channel → `AddisHome Listings` → **Public** → link
`addisfurnish_listings`. Then Channel → Administrators → add your bot and grant
**Post Messages**. The channel ID is `@addisfurnish_listings`.

### 3. Fill in the secrets

```bash
cp supabase/functions/.env.example supabase/functions/.env
# generate the webhook secret:
openssl rand -hex 32
```

| Variable | Purpose |
| --- | --- |
| `TELEGRAM_BOT_TOKEN` | BotFather token |
| `TELEGRAM_CHANNEL_ID` | `@addisfurnish_listings` — bot must be admin |
| `TELEGRAM_WEBHOOK_SECRET` | Authenticates Telegram's webhook calls |
| `SITE_URL` | Public app origin, used to link alerts back to a listing |
| `SUPABASE_SERVICE_ROLE_KEY` | Reads profiles/listings past RLS |

With `TELEGRAM_BOT_TOKEN` unset every Telegram path is a clean no-op, so the
apps run fine unconfigured.

### 4. Deploy

```bash
supabase secrets set --env-file supabase/functions/.env
supabase functions deploy telegram-notify telegram-bot
supabase db push

curl -X POST "https://api.telegram.org/bot<TOKEN>/setWebhook" \
  -d "url=https://bchojnitamkmnxvwqtdn.supabase.co/functions/v1/telegram-bot" \
  -d "secret_token=<TELEGRAM_WEBHOOK_SECRET>" \
  --data-urlencode 'allowed_updates=["message","callback_query"]'

> ⚠️ `allowed_updates` MUST include `callback_query` — otherwise inline-button
> taps (the "✅ I've joined — verify" button, category pickers in `/sell`) are
> silently dropped by Telegram and the buttons spin forever. This caused the
> verify button to appear dead in production once; don't drop it on redeploys.
```

### 5. Point the apps at the bot

The bot *username* is public (it's in the t.me link every user sees), so it
ships as a client variable. Without it the "Connect Telegram" button is hidden.

```bash
# web/.env
VITE_TELEGRAM_BOT_USERNAME=addisfurnish_bot
# mobile/.env
EXPO_PUBLIC_TELEGRAM_BOT_USERNAME=addisfurnish_bot
```

---

## Security notes

`telegram-bot` runs with `verify_jwt = false` (see `supabase/config.toml`)
because Telegram's webhook sends no `Authorization` header. That makes the
endpoint public, so it **rejects any request without a matching
`X-Telegram-Bot-Api-Secret-Token`**. Without that check a forged `/start` could
bind an attacker's `chat_id` to someone else's account and redirect all their
alerts. The function refuses to serve at all when the secret is unset.

`telegram-notify` is reachable with the public anon key (that's how the DB
trigger calls it), so it verifies a real notifications row exists before
sending — otherwise anyone could DM any linked user arbitrary text. The
listing/view shapes require a genuine user JWT and check listing ownership.

Account-linking tokens are **single-use and expire after 15 minutes**
(`mint_telegram_link_token()`); the webhook clears the token as it consumes it.

## Rate limits

~30 messages/second across different users, ~20/minute to one channel. The
buyer broadcast scans at most 500 preference rows and sends at most 50 DMs per
listing, logging when either cap truncates. Neither matters until well past MVP
scale, but the log line means a silent cap never reads as full coverage.
