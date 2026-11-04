#!/usr/bin/env bash
#
# setup-email.sh — one-shot configuration of AddisHome auth email delivery.
#
# This wires up everything that was previously done by hand (and which took a
# long time to get right): Brevo SMTP credentials as project secrets, token-only
# email templates, 6-digit OTP length, the send-mail edge function, and the
# Supabase "send email" hook that routes GoTrue's mail through nodemailer.
#
# Why this exists: GoTrue's own SMTP client (gomail.v2 → Brevo) completes the
# SMTP conversation but its messages never reach Gmail inboxes, while the same
# content sent through other clients does. The send-mail edge function uses
# nodemailer, which delivers reliably. See supabase/functions/send-mail/README.md.
#
# Usage:
#   SUPABASE_ACCESS_TOKEN=sbp_xxx SUPABASE_PROJECT_REF=bchojnitamkmnxvwqtdn \
#   BREVO_SMTP_USER=xxxxx@smtp-brevo.com BREVO_SMTP_KEY=xsmtpsib-... \
#   ./setup-email.sh
#
# Safe to re-run: every step is idempotent.
#
# Required env:
#   SUPABASE_ACCESS_TOKEN   Management API token (sbp_...), from
#                           https://supabase.com/dashboard/account/tokens
#   SUPABASE_PROJECT_REF    Project ref, e.g. bchojnitamkmnxvwqtdn
#   BREVO_SMTP_USER         Brevo SMTP relay login (xxxxx@smtp-brevo.com)
#   BREVO_SMTP_KEY          Brevo SMTP key (xsmtpsib-...)
#
# Optional env:
#   BREVO_SMTP_HOST         default smtp-relay.brevo.com
#   BREVO_SMTP_PORT         default 465
#   BREVO_SENDER            default sadim9812@gmail.com (must be verified in Brevo)
#   BREVO_SENDER_NAME       default AddisHome
#   OTP_LENGTH              default 6 (must match the app's code inputs)
#   EMAIL_RATE_LIMIT        default 300 (per-window auth email allowance)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTION_FILE="$SCRIPT_DIR/../functions/send-mail/index.ts"

: "${SUPABASE_ACCESS_TOKEN:?set SUPABASE_ACCESS_TOKEN (sbp_...)}"
: "${SUPABASE_PROJECT_REF:?set SUPABASE_PROJECT_REF (20-char project ref)}"
: "${BREVO_SMTP_USER:?set BREVO_SMTP_USER (Brevo SMTP relay login)}"
: "${BREVO_SMTP_KEY:?set BREVO_SMTP_KEY (Brevo SMTP key)}"

HOST="${BREVO_SMTP_HOST:-smtp-relay.brevo.com}"
PORT="${BREVO_SMTP_PORT:-465}"
SENDER="${BREVO_SENDER:-sadim9812@gmail.com}"
SENDER_NAME="${BREVO_SENDER_NAME:-AddisHome}"
OTP_LENGTH="${OTP_LENGTH:-6}"
RATE_LIMIT="${EMAIL_RATE_LIMIT:-300}"

API="https://api.supabase.com/v1/projects/$SUPABASE_PROJECT_REF"
AUTH="Authorization: Bearer $SUPABASE_ACCESS_TOKEN"
JSON="Content-Type: application/json"

log()  { printf '\n==> %s\n' "$*"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ -f "$FUNCTION_FILE" ] || fail "edge function not found at $FUNCTION_FILE"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v python3 >/dev/null 2>&1 || fail "python3 is required (for JSON parsing)"

# --- 1. Project secrets -------------------------------------------------------
log "Setting project secrets (BREVO_SMTP_*)"
python3 - "$HOST" "$PORT" "$BREVO_SMTP_USER" "$BREVO_SMTP_KEY" "$SENDER" "$SENDER_NAME" <<'PY' | curl -sS -m 60 -X POST "$API/secrets" -H "$AUTH" -H "$JSON" -d @- >/dev/null
import json, sys
host, port, user, key, sender, name = sys.argv[1:]
print(json.dumps([
    {"name": "BREVO_SMTP_HOST", "value": host},
    {"name": "BREVO_SMTP_PORT", "value": port},
    {"name": "BREVO_SMTP_USER", "value": user},
    {"name": "BREVO_SMTP_KEY",  "value": key},
    {"name": "BREVO_SENDER",    "value": sender},
    {"name": "BREVO_SENDER_NAME", "value": name},
]))
PY

# --- 2. Auth config: templates, subjects, OTP length, rate limit --------------
log "Writing token-only email templates + 6-digit OTP config"
python3 - "$OTP_LENGTH" "$RATE_LIMIT" <<'PY' | curl -sS -m 60 -X PATCH "$API/config/auth" -H "$AUTH" -H "$JSON" -d @- | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  otp_length:", d.get("mailer_otp_length"), "| rate_limit_email_sent:", d.get("rate_limit_email_sent"))'
import json, sys
otp_len, rate = sys.argv[1:]
confirmation = ('<h2>Verify Your Email</h2>'
                '<p>Use the verification code below to verify your email address:</p>'
                '<h1 style="letter-spacing: 8px; font-size: 36px;">{{ .Token }}</h1>'
                '<p>This code expires in 15 minutes.</p>')
recovery = ('<h2>Password Reset</h2>'
            '<p>Use the verification code below to reset your password:</p>'
            '<h1 style="letter-spacing: 8px; font-size: 36px;">{{ .Token }}</h1>'
            '<p>This code expires in 15 minutes.</p>')
print(json.dumps({
    "mailer_templates_confirmation_content": confirmation,
    "mailer_templates_recovery_content": recovery,
    "mailer_subjects_confirmation": "Verify your email for AddisHome",
    "mailer_subjects_recovery": "Reset Your Password",
    "mailer_otp_length": int(otp_len),
    "rate_limit_email_sent": int(rate),
}))
PY

# --- 3. Deploy the send-mail edge function ------------------------------------
log "Deploying send-mail edge function ($FUNCTION_FILE)"
curl -sS -m 120 -X POST "$API/functions/deploy?slug=send-mail" \
  -H "$AUTH" \
  -F "file=@$FUNCTION_FILE" \
  -F 'metadata={"entrypoint_path":"index.ts","verify_jwt":false,"name":"Send Mail"}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  status:", d.get("status"), "| version:", d.get("version"))'

# --- 4. Enable the send-email hook --------------------------------------------
HOOK_URI="https://$SUPABASE_PROJECT_REF.supabase.co/functions/v1/send-mail"
log "Enabling send-email hook -> $HOOK_URI"
python3 - "$HOOK_URI" <<'PY' | curl -sS -m 60 -X PATCH "$API/config/auth" -H "$AUTH" -H "$JSON" -d @- | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  hook_send_email_enabled:", d.get("hook_send_email_enabled"), "| uri:", d.get("hook_send_email_uri"))'
import json, sys
uri = sys.argv[1]
print(json.dumps({
    "hook_send_email_enabled": True,
    "hook_send_email_uri": uri,
}))
PY

# --- 5. Verify ----------------------------------------------------------------
log "Verifying configuration"
CONFIG_JSON="$(curl -sS -m 60 "$API/config/auth" -H "$AUTH")"
CONFIG_JSON="$CONFIG_JSON" python3 - "$SENDER" "$SENDER_NAME" <<'PY'
import json, os, sys
sender, sender_name = sys.argv[1:]
d = json.loads(os.environ["CONFIG_JSON"])
ok = True
checks = {
    "templates token-only": "{{ .Token }}" in (d.get("mailer_templates_confirmation_content") or "") and "{{ .ConfirmationURL }}" not in (d.get("mailer_templates_confirmation_content") or ""),
    "otp_length": d.get("mailer_otp_length"),
    "hook enabled": d.get("hook_send_email_enabled"),
}
for k, v in checks.items():
    print(f"  {k}: {v}")
    if v in (None, False): ok = False
# SMTP values are masked by the API once the send-email hook is active; the
# hook (not GoTrue's SMTP) is the delivery path, so that masking is expected.
print("  smtp delivery: via send-mail hook (SMTP config masked by API - expected)")
print("  ALL GOOD" if ok else "  SOME CHECKS FAILED - review above")
PY

printf '\nDone. Test end-to-end: trigger a password reset from the app (or POST /auth/v1/recover)\n'
printf 'and confirm the 6-digit code email arrives in the inbox (check spam on the first send).\n'
