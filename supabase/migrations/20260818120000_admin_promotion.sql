-- ── Admin promotion with email verification ──────────────────────────────
-- Lets any admin promote another user to admin (or remove admin access)
-- from the admin Users tab. Two guardrails:
--   1. The change is NOT applied instantly — a confirmation email goes to
--      the ACTING admin with a one-time link. Someone who grabs a logged-in
--      machine can request a promotion but cannot complete it without
--      confirming from the admin's inbox.
--   2. The super admin (profiles.is_super_admin) can never be demoted.
-- After the acting admin confirms, the affected user gets an email telling
-- them about the change.
--
-- Emails go through the existing `send-mail` edge function (Brevo), invoked
-- via pg_net's net.http_post — the same path the notification triggers
-- use for push / telegram. The publishable key is required as the auth
-- bearer token that Supabase Edge Functions expect.

-- 1. Super admin flag + seed the owner account.
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS is_super_admin boolean NOT NULL DEFAULT false;

-- The owner (Hayredin Mohammed) is the super admin.
UPDATE public.profiles p
SET is_super_admin = true
WHERE p.id = (SELECT id FROM auth.users WHERE email = 'hayredin.950@gmail.com')
  AND NOT p.is_super_admin;

-- The super admin also holds the admin role, so the admin dashboard gate
-- (has_role 'admin') lets them in.
INSERT INTO public.user_roles (user_id, role)
SELECT id, 'admin' FROM auth.users WHERE email = 'hayredin.950@gmail.com'
ON CONFLICT DO NOTHING;

-- 2. user_roles: link to profiles so PostgREST can embed `user_roles(role)`
--    in the admin Users tab query, and let admins read everyone's roles
--    (the base policy only exposes your own).
-- Clean orphaned user_roles first (some may reference deleted profiles).
DELETE FROM public.user_roles WHERE user_id NOT IN (SELECT id FROM public.profiles);

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'user_roles_user_id_fkey'
  ) THEN
    ALTER TABLE public.user_roles
      ADD CONSTRAINT user_roles_user_id_fkey
      FOREIGN KEY (user_id) REFERENCES public.profiles(id) ON DELETE CASCADE;
  END IF;
END $$;

DROP POLICY IF EXISTS "admins read all roles" ON public.user_roles;
CREATE POLICY "admins read all roles" ON public.user_roles FOR SELECT TO authenticated
  USING (public.has_role(auth.uid(),'admin'));

-- 3. Pending role-change requests (single-use token, emailed to the admin).
CREATE TABLE IF NOT EXISTS public.admin_role_requests (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  requester_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  target_user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  action text NOT NULL CHECK (action IN ('promote','demote')),
  token text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS admin_role_requests_token_idx ON public.admin_role_requests (token);
GRANT SELECT, INSERT, UPDATE, DELETE ON public.admin_role_requests TO service_role;
ALTER TABLE public.admin_role_requests ENABLE ROW LEVEL SECURITY;
-- No client policies: rows are only touched through the SECURITY DEFINER RPCs.

-- 4. admin_request_role_change(_target_user_id, _action) ───────────────────
-- Validates the caller is an admin and the request is legal, records a
-- pending request with a one-time token, then emails the ACTING admin a
-- confirmation link. Returns { ok, error? }.
CREATE OR REPLACE FUNCTION public.admin_request_role_change(_target_user_id uuid, _action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, extensions AS $$
DECLARE
  _requester uuid := auth.uid();
  _token text;
  _requester_email text;
  _target_email text;
  _target_name text;
  _link text;
  _subject text;
  _html text;
BEGIN
  IF _requester IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'auth');
  END IF;
  IF NOT public.has_role(_requester, 'admin') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'admin');
  END IF;
  IF _action NOT IN ('promote','demote') THEN
    RETURN jsonb_build_object('ok', false, 'error', 'action');
  END IF;
  IF _target_user_id IS NULL OR _target_user_id = _requester THEN
    RETURN jsonb_build_object('ok', false, 'error', 'self');
  END IF;

  SELECT full_name INTO _target_name FROM public.profiles WHERE id = _target_user_id;
  IF _target_name IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'target');
  END IF;

  IF _action = 'promote' THEN
    IF public.has_role(_target_user_id, 'admin') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'already_admin');
    END IF;
  ELSE
    IF NOT public.has_role(_target_user_id, 'admin') THEN
      RETURN jsonb_build_object('ok', false, 'error', 'not_admin');
    END IF;
    IF EXISTS (SELECT 1 FROM public.profiles WHERE id = _target_user_id AND is_super_admin) THEN
      RETURN jsonb_build_object('ok', false, 'error', 'super_admin');
    END IF;
  END IF;

  -- The confirmation must land in the acting admin's inbox — without an
  -- email on their account there is nothing to verify against.
  SELECT email INTO _requester_email FROM auth.users WHERE id = _requester;
  IF _requester_email IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_email');
  END IF;
  SELECT email INTO _target_email FROM auth.users WHERE id = _target_user_id;

  -- Single-use token, valid 24 hours.
  _token := encode(gen_random_bytes(32), 'hex');
  INSERT INTO public.admin_role_requests (requester_id, target_user_id, action, token, expires_at)
  VALUES (_requester, _target_user_id, _action, _token, now() + interval '24 hours');

  _link := 'https://addisfurnish.vercel.app/admin/confirm-role?token=' || _token;

  IF _action = 'promote' THEN
    _subject := 'Confirm: make ' || _target_name || ' an admin on AddisFurnish';
    _html :=
      '<h2>Confirm admin change</h2>' ||
      '<p>You requested to make <b>' || _target_name || '</b> an admin on AddisFurnish.</p>' ||
      '<p><a href="' || _link || '">Click here to confirm</a></p>' ||
      '<p>If you did not request this, you can safely ignore this email — nothing will change until you confirm.</p>';
  ELSE
    _subject := 'Confirm: remove ' || _target_name || '''s admin access on AddisFurnish';
    _html :=
      '<h2>Confirm admin change</h2>' ||
      '<p>You requested to remove <b>' || _target_name || '</b>''s admin access on AddisFurnish.</p>' ||
      '<p><a href="' || _link || '">Click here to confirm</a></p>' ||
      '<p>If you did not request this, you can safely ignore this email — nothing will change until you confirm.</p>';
  END IF;

  BEGIN
    PERFORM http_post(
      url := (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/send-mail',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
      ),
      body := jsonb_build_object('email', jsonb_build_object(
        'to', _requester_email,
        'subject', _subject,
        'content', _html
      )),
      timeout_milliseconds := 10000
    );
  EXCEPTION WHEN OTHERS THEN
    RAISE WARNING 'admin_request_role_change email failed: % (%)', SQLERRM, SQLSTATE;
  END;

  RETURN jsonb_build_object('ok', true);
END; $$;

REVOKE ALL ON FUNCTION public.admin_request_role_change(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_request_role_change(uuid, text) TO authenticated;

-- 5. admin_confirm_role_change(_token) ─────────────────────────────────────
-- Token is the credential (it only ever exists inside the emailed link), so
-- this is callable by anon — the browser opening the confirm page does not
-- need a session. Applies the change, marks the token used, and emails the
-- affected user. Returns { ok, action, name, error? }.
CREATE OR REPLACE FUNCTION public.admin_confirm_role_change(_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, extensions AS $$
DECLARE
  _req public.admin_role_requests%ROWTYPE;
  _target_name text;
  _target_email text;
  _subject text;
  _html text;
BEGIN
  IF _token IS NULL OR _token = '' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'token');
  END IF;

  SELECT * INTO _req FROM public.admin_role_requests WHERE token = _token;
  IF _req.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid');
  END IF;
  IF _req.used_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'used');
  END IF;
  IF _req.expires_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'expired');
  END IF;

  -- Re-check the super-admin rule at apply time too (defense in depth).
  IF _req.action = 'demote' AND EXISTS (
    SELECT 1 FROM public.profiles WHERE id = _req.target_user_id AND is_super_admin
  ) THEN
    RETURN jsonb_build_object('ok', false, 'error', 'super_admin');
  END IF;

  IF _req.action = 'promote' THEN
    INSERT INTO public.user_roles (user_id, role) VALUES (_req.target_user_id, 'admin')
    ON CONFLICT DO NOTHING;
  ELSE
    DELETE FROM public.user_roles WHERE user_id = _req.target_user_id AND role = 'admin';
  END IF;

  UPDATE public.admin_role_requests SET used_at = now() WHERE id = _req.id;

  SELECT full_name INTO _target_name FROM public.profiles WHERE id = _req.target_user_id;
  SELECT email INTO _target_email FROM auth.users WHERE id = _req.target_user_id;

  IF _req.action = 'promote' THEN
    _subject := 'You''re now an admin on AddisFurnish 🎉';
    _html :=
      '<h2>You''re now an admin 🎉</h2>' ||
      '<p>Hi <b>' || COALESCE(_target_name, 'there') || '</b>,</p>' ||
      '<p>You''ve been promoted to admin on AddisFurnish. You can now moderate reports, ' ||
      'verify sellers, manage categories and view platform stats.</p>' ||
      '<p><a href="https://addisfurnish.vercel.app/admin">Open the admin dashboard</a></p>';
  ELSE
    _subject := 'Your admin access on AddisFurnish was removed';
    _html :=
      '<h2>Admin access removed</h2>' ||
      '<p>Hi <b>' || COALESCE(_target_name, 'there') || '</b>,</p>' ||
      '<p>Your admin access on AddisFurnish has been removed. You can still use the marketplace as normal.</p>';
  END IF;

  IF _target_email IS NOT NULL THEN
    BEGIN
      PERFORM http_post(
        url := (SELECT vault.decrypt_secret('SUPABASE_URL')) || '/functions/v1/send-mail',
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || (SELECT vault.decrypt_secret('SUPABASE_PUBLISHABLE_KEY'))
        ),
        body := jsonb_build_object('email', jsonb_build_object(
          'to', _target_email,
          'subject', _subject,
          'content', _html
        )),
        timeout_milliseconds := 10000
      );
    EXCEPTION WHEN OTHERS THEN
      RAISE WARNING 'admin_confirm_role_change email failed: % (%)', SQLERRM, SQLSTATE;
    END;
  END IF;

  RETURN jsonb_build_object('ok', true, 'action', _req.action, 'name', _target_name);
END; $$;

REVOKE ALL ON FUNCTION public.admin_confirm_role_change(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_confirm_role_change(text) TO anon, authenticated;
