#!/bin/bash
# ============================================================================
# Supra OpenSearch index template — run ONCE on the production server.
#
# This is the piece that makes the "400 - Rejected by OpenSearch" errors
# structurally impossible:
#   * date_detection / numeric_detection OFF  -> OpenSearch never guesses a type
#   * every dynamic field mapped as keyword    -> a value that is a number in one
#     event and a string in another can NEVER conflict (both stored as keyword)
#   * ignore_malformed = true                  -> a bad value is dropped from the
#     doc instead of rejecting the whole document
#   * total_fields.limit raised                -> Windows events add many fields
#   * number_of_replicas 0                     -> single-node box stays GREEN
#
# Applies to every supra-* index (supra-ied-*, supra-network-*,
# supra-windows-*, supra-logs-*). Re-running is safe (idempotent PUT).
#
# No curl required: this script uses whichever HTTP client exists on the box
# (curl -> wget -> python3 -> the Ruby bundled with fluent-package).
#
# Usage:  sudo bash supra-index-template.sh
# ============================================================================
set -euo pipefail

OS_URL="${OS_URL:-https://localhost:9200}"
OS_USER="${OS_USER:-admin}"
OS_PASS="${OS_PASS:-admin}"
ENDPOINT="${OS_URL}/_index_template/supra-logs"

# ---- template body ----
BODY_FILE="$(mktemp /tmp/supra-template.XXXXXX.json)"
trap 'rm -f "$BODY_FILE"' EXIT
cat > "$BODY_FILE" <<'JSON'
{
  "index_patterns": ["supra-*"],
  "priority": 200,
  "template": {
    "settings": {
      "index.number_of_replicas": 0,
      "index.refresh_interval": "5s",
      "index.mapping.total_fields.limit": 4000,
      "index.mapping.ignore_malformed": true
    },
    "mappings": {
      "date_detection": false,
      "numeric_detection": false,
      "dynamic_templates": [
        { "messages_as_text": { "match": "*essage", "mapping": { "type": "text" } } },
        { "everything_else_as_keyword": { "match_mapping_type": "*", "mapping": { "type": "keyword", "ignore_above": 8191 } } }
      ],
      "properties": {
        "@timestamp":        { "type": "date" },
        "message":           { "type": "text" },
        "Message":           { "type": "text" },
        "raw_message":       { "type": "text" },
        "event_description": { "type": "text" }
      }
    }
  }
}
JSON

echo "Installing index template 'supra-logs' on ${OS_URL} ..."

RUBY_BIN=""
for r in /opt/fluent/bin/ruby /usr/bin/ruby ruby; do
  command -v "$r" >/dev/null 2>&1 && { RUBY_BIN="$r"; break; }
done

RESP=""
if command -v curl >/dev/null 2>&1; then
  echo "  (using curl)"
  RESP="$(curl -sk -u "${OS_USER}:${OS_PASS}" -X PUT "$ENDPOINT" \
          -H 'Content-Type: application/json' --data-binary "@${BODY_FILE}")"

elif command -v wget >/dev/null 2>&1; then
  echo "  (using wget)"
  RESP="$(wget -q -O - --no-check-certificate \
          --user="${OS_USER}" --password="${OS_PASS}" \
          --method=PUT --header='Content-Type: application/json' \
          --body-file="${BODY_FILE}" "$ENDPOINT")"

elif command -v python3 >/dev/null 2>&1; then
  echo "  (using python3)"
  RESP="$(OS_URL="$ENDPOINT" OS_USER="$OS_USER" OS_PASS="$OS_PASS" BODY_FILE="$BODY_FILE" python3 - <<'PY'
import os, ssl, base64, urllib.request
url, user, pw = os.environ["OS_URL"], os.environ["OS_USER"], os.environ["OS_PASS"]
body = open(os.environ["BODY_FILE"], "rb").read()
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
req = urllib.request.Request(url, data=body, method="PUT")
req.add_header("Content-Type", "application/json")
req.add_header("Authorization", "Basic " + base64.b64encode(f"{user}:{pw}".encode()).decode())
try:
    print(urllib.request.urlopen(req, context=ctx).read().decode())
except urllib.error.HTTPError as e:
    print(e.read().decode()); raise SystemExit(1)
PY
)"

elif [ -n "$RUBY_BIN" ]; then
  echo "  (using $RUBY_BIN)"
  RESP="$(OS_URL="$ENDPOINT" OS_USER="$OS_USER" OS_PASS="$OS_PASS" BODY_FILE="$BODY_FILE" "$RUBY_BIN" <<'RB'
require "net/http"; require "uri"; require "openssl"
uri = URI(ENV["OS_URL"]); body = File.read(ENV["BODY_FILE"])
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = (uri.scheme == "https"); http.verify_mode = OpenSSL::SSL::VERIFY_NONE
req = Net::HTTP::Put.new(uri); req["Content-Type"] = "application/json"
req.basic_auth(ENV["OS_USER"], ENV["OS_PASS"]); req.body = body
res = http.request(req); puts res.body
exit 1 unless res.code.to_i == 200 || res.code.to_i == 201
RB
)"

else
  echo "ERROR: no curl, wget, python3, or ruby found on this host." >&2
  exit 1
fi

echo "$RESP"
if echo "$RESP" | grep -q '"acknowledged"[[:space:]]*:[[:space:]]*true'; then
  echo "OK: template installed."
  echo "NOTE: existing supra-* indices keep their old mapping. The template"
  echo "      applies to indices created from now on (a new one rolls daily"
  echo "      with logstash_format). To apply today immediately, delete the"
  echo "      current bad index, e.g.:  supra-windows-\$(date +%Y.%m.%d)"
else
  echo "WARNING: did not see acknowledged:true — check the response above." >&2
  exit 1
fi
