-- ── Fix: notification triggers never actually made an HTTP call ──────────
--
-- Both `push_on_notification` and `telegram_on_notification` called
-- `supabase_functions.http_request(...)`, the helper installed by Supabase's
-- legacy "Database Webhooks" integration. That integration was never enabled
-- on this project, so the schema does not exist and every call raised
--
--   3F000 — schema "supabase_functions" does not exist
--
-- Both functions wrapped the call in `EXCEPTION WHEN OTHERS THEN NULL`, so the
-- error was swallowed silently on every notifications insert. Net effect: no
-- push notification has ever been delivered, and neither had any Telegram
-- alert. Verified by probe: the edge function delivers correctly when called
-- directly, but never fires via the trigger.
--
-- This migration switches both to pg_net's `net.http_post`, which is the
-- mechanism Supabase's own webhooks are built on. pg_net is asynchronous — it
-- queues the request and a background worker performs it — so the HTTP call
-- can no longer add latency to (or block) a notifications insert.
--
-- Verify after applying, from the SQL editor:
--   insert into public.notifications (user_id, type, payload)
--   values ('<some-user-id>', 'new_message', '{"title":"probe"}'::jsonb);
--   select id, status_code, error_msg, created
--     from net._http_response order by id desc limit 5;

CREATE EXTENSION IF NOT EXISTS pg_net;

-- Both trigger functions pin an explicit search_path (they are SECURITY
-- DEFINER). pg_net's objects land in `net` on most projects and in
-- `extensions` on some, so both are listed and http_post is called unqualified
-- — the pinned path keeps that unambiguous and injection-safe.

CREATE OR REPLACE FUNCTION public.push_on_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
BEGIN
  BEGIN
    PERFORM http_post(
      url := (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/send-push',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
      ),
      body := jsonb_build_object(
        'notification_id', NEW.id,
        'user_id', NEW.user_id,
        'type', NEW.type,
        'payload', NEW.payload
      ),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    -- Delivery must never break the insert, but it must not vanish either:
    -- a swallowed error here is what hid the broken push for months.
    RAISE WARNING 'push_on_notification failed: % (%)', SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.telegram_on_notification()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, net, extensions
AS $$
BEGIN
  BEGIN
    PERFORM http_post(
      url := (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/telegram-notify',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
      ),
      body := jsonb_build_object(
        'notification_id', NEW.id,
        'user_id', NEW.user_id,
        'type', NEW.type,
        'payload', NEW.payload
      ),
      timeout_milliseconds := 5000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'telegram_on_notification failed: % (%)', SQLERRM, SQLSTATE;
  END;
  RETURN NEW;
END;
$$;

-- Triggers themselves are already installed and enabled; recreated here only
-- so this migration is self-contained if replayed on a fresh database.
DROP TRIGGER IF EXISTS push_on_notification_insert ON public.notifications;
CREATE TRIGGER push_on_notification_insert AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.push_on_notification();

DROP TRIGGER IF EXISTS telegram_on_notification_insert ON public.notifications;
CREATE TRIGGER telegram_on_notification_insert AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.telegram_on_notification();
