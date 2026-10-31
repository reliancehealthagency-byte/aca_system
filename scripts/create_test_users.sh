#!/usr/bin/env bash
# Creates the two slice-one test users (admin + agent) in Supabase Auth via the Admin API.
# Passwords are generated here and written ONLY to $OUT (chmod 600). Nothing secret is printed.
# Usage: SUPABASE_ENV=/path/to/supabase.env OUT=/path/to/test_users.env scripts/create_test_users.sh
set -euo pipefail
: "${SUPABASE_ENV:?path to env file with SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY}"
: "${OUT:?path for the generated credentials file}"
set -a; . "$SUPABASE_ENV"; set +a
umask 077
[ -e "$OUT" ] && { echo "$OUT already exists; not overwriting"; exit 1; }
ADMIN_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
AGENT_PW=$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)
create() {
  local email=$1 pw=$2
  curl -s -o /dev/null -w "%{http_code}" -X POST "$SUPABASE_URL/auth/v1/admin/users" \
    -H "apikey: $SUPABASE_SERVICE_ROLE_KEY" -H "Authorization: Bearer $SUPABASE_SERVICE_ROLE_KEY" \
    -H 'content-type: application/json' \
    -d "{\"email\":\"$email\",\"password\":\"$pw\",\"email_confirm\":true}"
}
a=$(create admin.test@example.com "$ADMIN_PW"); g=$(create agent.test@example.com "$AGENT_PW")
echo "admin.test@example.com -> HTTP $a; agent.test@example.com -> HTTP $g"
cat > "$OUT" <<EOT
# Slice-one TEST users (fake, @example.com). Generated $(date -Iseconds). Do not commit.
TEST_ADMIN_EMAIL=admin.test@example.com
TEST_ADMIN_PASSWORD=$ADMIN_PW
TEST_AGENT_EMAIL=agent.test@example.com
TEST_AGENT_PASSWORD=$AGENT_PW
EOT
chmod 600 "$OUT"
