-- ── Telegram integration (channel posts + buyer/seller bots) ─────────────
-- Moves Telegram out of the web app's server functions and into the shared
-- backend, so the mobile app, admin actions and DB triggers all reach it.
--
--  * push_on_notification: FIXED — it pointed at a dead project ref.
--  * telegram_on_notification: new trigger, forwards every notifications row
--    to the `telegram-notify` edge function (the Telegram twin of send-push).
--  * profiles.telegram_link_token_expires_at / telegram_linked_at: make the
--    account-linking token single-use and time-boxed.
--  * mint_telegram_link_token / unlink_telegram: RPCs so BOTH apps can link
--    without a web-only server function.
--
-- Deploy the edge functions BEFORE relying on the triggers:
--   supabase functions deploy telegram-notify telegram-bot
-- Failures are swallowed so a Telegram outage can never block an insert.

-- ── FIX: push_on_notification pointed at the wrong project ───────────────
-- The URL below was `ssihdmhsptlbalidutqa.supabase.co`, which is not this
-- project (see supabase/config.toml). Because the body swallows every
-- exception, the misdirected POST failed silently and no push has ever been
-- delivered. Re-created here against the correct ref.
CREATE OR REPLACE FUNCTION public.push_on_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM supabase_functions.http_request(
      (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/send-push',
      'POST',
      jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
      ),
      jsonb_build_object(
        'notification_id', NEW.id,
        'user_id', NEW.user_id,
        'type', NEW.type,
        'payload', NEW.payload
      ),
      2000
    );
  EXCEPTION WHEN OTHERS THEN
    -- Push delivery must never break the notifications insert.
    NULL;
  END;
  RETURN NEW;
END;
$$;

-- ── Trigger: notifications insert → telegram-notify edge function ────────
-- Deliberately a SECOND trigger rather than an extra call inside
-- push_on_notification: either channel can fail or be redeployed on its own,
-- and one slow HTTP call must not delay the other.
CREATE OR REPLACE FUNCTION public.telegram_on_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  BEGIN
    PERFORM supabase_functions.http_request(
      (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/telegram-notify',
      'POST',
      jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
      ),
      jsonb_build_object(
        'notification_id', NEW.id,
        'user_id', NEW.user_id,
        'type', NEW.type,
        'payload', NEW.payload
      ),
      2000
    );
  EXCEPTION WHEN OTHERS THEN
    -- Telegram delivery must never break the notifications insert.
    NULL;
  END;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS telegram_on_notification_insert ON public.notifications;
CREATE TRIGGER telegram_on_notification_insert AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.telegram_on_notification();

-- ── Account-linking token hardening ──────────────────────────────────────
-- Previously telegram_link_token was minted once and never cleared, so the
-- deep link stayed valid forever — anyone who obtained it could bind their own
-- Telegram chat to that account. Now it expires and is consumed on use.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS telegram_link_token_expires_at timestamptz,
  ADD COLUMN IF NOT EXISTS telegram_linked_at timestamptz;

-- Looked up by the bot webhook on every /start.
CREATE INDEX IF NOT EXISTS profiles_telegram_link_token_idx
  ON public.profiles (telegram_link_token)
  WHERE telegram_link_token IS NOT NULL;

-- The buyer broadcast scans only opted-in rows.
CREATE INDEX IF NOT EXISTS buyer_preferences_telegram_idx
  ON public.buyer_preferences (user_id)
  WHERE telegram_alerts_enabled;

-- ── mint_telegram_link_token() ───────────────────────────────────────────
-- Returns a fresh single-use token for the calling user, valid 15 minutes.
-- The client builds t.me/<bot>?start=<token> from it. Replaces the web-only
-- getTelegramDeepLink server function so mobile can link too.
CREATE OR REPLACE FUNCTION public.mint_telegram_link_token()
RETURNS text LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  _token text;
BEGIN
  IF auth.uid() IS NULL THEN RETURN NULL; END IF;
  -- 32 hex chars from a random uuid — same shape the old TS helper produced.
  _token := replace(gen_random_uuid()::text, '-', '');
  UPDATE public.profiles
     SET telegram_link_token = _token,
         telegram_link_token_expires_at = now() + interval '15 minutes'
   WHERE id = auth.uid();
  RETURN _token;
END; $$;
REVOKE ALL ON FUNCTION public.mint_telegram_link_token() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.mint_telegram_link_token() TO authenticated;

-- ── unlink_telegram() ────────────────────────────────────────────────────
-- App-side disconnect (the bot's /stop command does the same thing from the
-- Telegram side, via the service role).
CREATE OR REPLACE FUNCTION public.unlink_telegram()
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN RETURN; END IF;
  UPDATE public.profiles
     SET telegram_chat_id = NULL,
         telegram_link_token = NULL,
         telegram_link_token_expires_at = NULL,
         telegram_linked_at = NULL
   WHERE id = auth.uid();
END; $$;
REVOKE ALL ON FUNCTION public.unlink_telegram() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.unlink_telegram() TO authenticated;
