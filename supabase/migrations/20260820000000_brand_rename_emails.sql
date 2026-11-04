-- ── Brand rename: AddisFurnish → AddisHome ────────────────────────────────
-- Re-creates the admin-promotion RPCs so their embedded email templates use
-- the new brand name. Applied migrations are left untouched; this forward
-- migration keeps the live database in sync with the rebranded app code.

-- Replace request function: 6-digit code + AddisHome-branded email
CREATE OR REPLACE FUNCTION public.admin_request_role_change(_target_user_id uuid, _action text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, extensions AS $$
DECLARE
  _requester uuid := auth.uid();
  _code text;
  _requester_email text;
  _target_name text;
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

  SELECT email INTO _requester_email FROM auth.users WHERE id = _requester;
  IF _requester_email IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'no_email');
  END IF;

  -- 6-digit numeric code
  _code := lpad(floor(random() * 1000000)::text, 6, '0');

  -- Invalidate any previous unused requests for this target+action
  UPDATE public.admin_role_requests
    SET used_at = now()
    WHERE target_user_id = _target_user_id
      AND action = _action
      AND used_at IS NULL;

  INSERT INTO public.admin_role_requests (requester_id, target_user_id, action, token, code, expires_at)
  VALUES (_requester, _target_user_id, _action, _code, _code, now() + interval '10 minutes');

  IF _action = 'promote' THEN
    _subject := 'AddisHome admin confirmation code';
    _html :=
      '<h2>Admin confirmation code</h2>' ||
      '<p>You requested to make <b>' || _target_name || '</b> an admin on AddisHome.</p>' ||
      '<p style="font-size:32px;letter-spacing:8px;font-weight:bold;margin:24px 0;">' || _code || '</p>' ||
      '<p>This code expires in 10 minutes.</p>' ||
      '<p>If you did not request this, ignore this email.</p>';
  ELSE
    _subject := 'AddisHome admin removal code';
    _html :=
      '<h2>Admin removal code</h2>' ||
      '<p>You requested to remove <b>' || _target_name || '</b>''s admin access on AddisHome.</p>' ||
      '<p style="font-size:32px;letter-spacing:8px;font-weight:bold;margin:24px 0;">' || _code || '</p>' ||
      '<p>This code expires in 10 minutes.</p>' ||
      '<p>If you did not request this, ignore this email.</p>';
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


-- Replace confirm function: accepts a 6-digit code, AddisHome-branded emails
CREATE OR REPLACE FUNCTION public.admin_confirm_role_change(_code text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, net, extensions AS $$
DECLARE
  _req public.admin_role_requests%ROWTYPE;
  _target_name text;
  _target_email text;
  _subject text;
  _html text;
BEGIN
  IF _code IS NULL OR length(_code) != 6 THEN
    RETURN jsonb_build_object('ok', false, 'error', 'code');
  END IF;

  SELECT * INTO _req FROM public.admin_role_requests
    WHERE code = _code AND used_at IS NULL
    ORDER BY created_at DESC LIMIT 1;

  IF _req.id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'error', 'invalid');
  END IF;
  IF _req.expires_at < now() THEN
    RETURN jsonb_build_object('ok', false, 'error', 'expired');
  END IF;

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
    _subject := 'You''re now an admin on AddisHome 🎉';
    _html :=
      '<h2>You''re now an admin 🎉</h2>' ||
      '<p>Hi <b>' || COALESCE(_target_name, 'there') || '</b>,</p>' ||
      '<p>You''ve been promoted to admin on AddisHome. You can now moderate reports, ' ||
      'verify sellers, manage categories and view platform stats.</p>' ||
      '<p><a href="https://addisfurnish.vercel.app/admin">Open the admin dashboard</a></p>';
  ELSE
    _subject := 'Your admin access on AddisHome was removed';
    _html :=
      '<h2>Admin access removed</h2>' ||
      '<p>Hi <b>' || COALESCE(_target_name, 'there') || '</b>,</p>' ||
      '<p>Your admin access on AddisHome has been removed. You can still use the marketplace as normal.</p>';
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