-- ── Push notifications (Expo Push Service) ───────────────────────────────
-- * push_tokens: Expo push tokens per device, registered from the mobile app.
-- * push_on_notification: after every notifications insert, forwards the row to
--   the `send-push` edge function which delivers it to expo.dev.
--   The edge function must be deployed BEFORE this trigger can deliver
--   (deploy is `supabase functions deploy send-push`); if it is not reachable
--   the exception is swallowed so notification inserts never fail.
-- * notifications is added to supabase_realtime so the in-app live banner
--   works in production (only `messages` was published before).

-- ── push_tokens table ────────────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS public.push_tokens (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  token text NOT NULL UNIQUE,
  platform text NOT NULL DEFAULT 'android',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS push_tokens_user_idx ON public.push_tokens (user_id);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.push_tokens TO authenticated;
GRANT ALL ON public.push_tokens TO service_role;
ALTER TABLE public.push_tokens ENABLE ROW LEVEL SECURITY;
-- A user may only manage their own device tokens. The edge function runs as
-- service_role (bypasses RLS) so it can read tokens for any recipient.
CREATE POLICY "own push tokens" ON public.push_tokens FOR ALL TO authenticated
  USING (user_id = auth.uid()) WITH CHECK (user_id = auth.uid());

-- ── Token claim RPC ──────────────────────────────────────────────────────
-- Device tokens are unique across users. On a reinstall / account switch a
-- stale row may still belong to the previous account and RLS would silently
-- block the app's delete-then-insert. This SECURITY DEFINER helper clears any
-- row for the device's token and attaches it to the current user in one step.
CREATE OR REPLACE FUNCTION public.claim_push_token(_token text, _platform text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF _token IS NULL OR _token = '' THEN RETURN; END IF;
  DELETE FROM public.push_tokens WHERE token = _token;
  INSERT INTO public.push_tokens (user_id, token, platform)
  VALUES (auth.uid(), _token, COALESCE(_platform, 'android'));
END; $$;
REVOKE ALL ON FUNCTION public.claim_push_token(text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.claim_push_token(text, text) TO authenticated;

-- ── Trigger: notifications insert → send-push edge function ──────────────
-- Uses the project's publishable key as the bearer JWT (the standard Supabase
-- trigger → edge-function pattern; publishable keys are public by design).
-- NOTE: the project URL and key are read from the Encrypted Vault
-- (SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY secrets), so this works on any
-- project — just make sure both Vault secrets exist.
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

DROP TRIGGER IF EXISTS push_on_notification_insert ON public.notifications;
CREATE TRIGGER push_on_notification_insert AFTER INSERT ON public.notifications
  FOR EACH ROW EXECUTE FUNCTION public.push_on_notification();

-- ── Realtime: publish notifications for the in-app live banner ───────────
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.notifications;
EXCEPTION WHEN duplicate_object THEN
  NULL; -- already a member
END $$;
