#!/usr/bin/env bash
# Scan a SKILL.md (or any markdown) for dangerous content patterns.
# Categories: SEC_DISABLE, SEC_PERMISSIVE, CRED_EXFIL, OBFUSC_B64,
#             OBFUSC_UNICODE, TOOL_BROAD, URL_EXTERNAL.
#
# Usage: validate-skill-content.sh <file>
# Env:   ALLOW_FILE  override path to .content-check-allow (default: repo root)
# Exit:  0 clean, 1 unjustified hit, 2 usage error.

set -uo pipefail

file="${1:-}"
if [[ -z "$file" || ! -f "$file" ]]; then
  echo "usage: validate-skill-content.sh <file>" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
allow_file="${ALLOW_FILE:-$repo_root/.content-check-allow}"

# Normalize $file to a repo-root-relative path so allow-file keys are stable
# regardless of whether the caller passed `./SKILL.md`, `SKILL.md`, or an
# absolute path. Falls back to the original path if it's outside the repo.
file_abs=$(cd "$(dirname "$file")" && pwd)/$(basename "$file")
file_key="${file_abs#"$repo_root"/}"

# Categories as "TAG||extended-regex" pairs (case-insensitive).
declare -a CATEGORIES=(
  'SEC_DISABLE||(disable|turn[ _-]?off|skip|bypass)[ _-]+(auth|authn|authz|sso|mfa|2fa|tls|ssl|cert|verification|signature|sandbox|seccomp|apparmor|selinux)'
  'SEC_PERMISSIVE||(allow[_-]?all|trust[_-]?all|trust-all-certs|--no-verify|--insecure|--disable[_-]?ssl|verify[ _=]+false|YOLO|0\.0\.0\.0/0|::/0|chmod[ ]+(-R[ ]+)?0?777)'
  # `nc` is included alongside `ncat` because the `(^|[^a-zA-Z])...[[:space:]]+`
  # boundary correctly excludes the substring inside words like "once",
  # "concurrent", "non-reasoning". Without that boundary, `nc` was too noisy.
  'CRED_EXFIL||(^|[^a-zA-Z])(curl|wget|nc|ncat)[[:space:]]+.{0,200}(token|api[_-]?key|secret|password|bearer|aws_secret|gh_token|anthropic_api_key|gitlab_token)'
  'OBFUSC_B64||(base64[ _-]?-d|base64[ ]+--decode|echo[ ]+[A-Za-z0-9+/]{40,}={0,2})'
  'TOOL_BROAD||^[ ]*allowed-tools:[ ]*["'\'']?\*["'\'']?[ ]*$'
)
# Note: OBFUSC_HEX (\\x.. sequences) is not scanned because it false-positives
# heavily on shell examples in markdown. Add later if a real exfil pattern emerges.

# URL allowlist: localhost, our org, anthropic, ollama, huggingface, etc.
URL_ALLOW='^https?://(localhost|127\.0\.0\.1|::1|github\.com/IsmaelMartinez|github\.com/anthropics|docs\.anthropic\.com|platform\.claude\.com|claude\.com|claude\.ai|ollama\.com|huggingface\.co|embracethered\.com)'

# Read allow-file into a newline-delimited string, leading + trailing newline so
# membership checks via `*$'\n'key$'\n'*` are unambiguous. Bash 3-compatible
# (no associative arrays).
allow_keys=$'\n'
if [[ -f "$allow_file" ]]; then
  while IFS= read -r entry || [[ -n "$entry" ]]; do
    entry="${entry%%#*}"
    entry="${entry%"${entry##*[![:space:]]}"}"
    entry="${entry#"${entry%%[![:space:]]*}"}"
    [[ -z "$entry" ]] && continue
    allow_keys="$allow_keys$entry"$'\n'
  done < "$allow_file"
fi

violations=0
report_hit() {
  local tag="$1" line_no="$2" content="$3"
  local key_line="$tag:$file_key:$line_no"
  local sha
  sha=$(printf '%s' "$content" | shasum -a 256 | awk '{print $1}')
  local key_sha="$tag:sha256:$sha"
  if [[ "$allow_keys" == *$'\n'"$key_line"$'\n'* || "$allow_keys" == *$'\n'"$key_sha"$'\n'* ]]; then
    return 0
  fi
  echo "::error file=$file_key,line=$line_no::$tag: ${content:0:120}" >&2
  violations=$((violations+1))
}

# Regex-based categories.
for entry in "${CATEGORIES[@]}"; do
  tag="${entry%%||*}"
  pat="${entry##*||}"
  while IFS=: read -r line_no content; do
    [[ -z "$line_no" ]] && continue
    report_hit "$tag" "$line_no" "$content"
  done < <(grep -nEi "$pat" "$file" 2>/dev/null || true)
done

# OBFUSC_UNICODE: zero-width / bidi / tag chars. Use perl for the unicode regex
# because macOS BSD grep lacks -P. perl is on every macOS and Ubuntu by default.
while IFS=: read -r line_no content; do
  [[ -z "$line_no" ]] && continue
  report_hit "OBFUSC_UNICODE" "$line_no" "$content"
done < <(perl -CSD -ne 'print "$.:$_" if /[\x{200B}-\x{200F}\x{202A}-\x{202E}\x{2060}-\x{206F}]/' "$file" 2>/dev/null || true)

# CONFLICT_MARKER: unresolved git merge markers. Structural prevention for
# the class of regression PR #41 remediated (conflict markers landing on main
# because CI didn't assert ROADMAP/SKILL parseability).
while IFS=: read -r line_no content; do
  [[ -z "$line_no" ]] && continue
  report_hit "CONFLICT_MARKER" "$line_no" "$content"
done < <(grep -nE '^(<<<<<<< |>>>>>>> |=======$)' "$file" 2>/dev/null || true)

# URL_EXTERNAL: every http(s) URL not in the allowlist.
while IFS=: read -r line_no content; do
  [[ -z "$line_no" ]] && continue
  while read -r url; do
    [[ -z "$url" ]] && continue
    if ! [[ "$url" =~ $URL_ALLOW ]]; then
      report_hit "URL_EXTERNAL" "$line_no" "$url"
    fi
  done < <(grep -oE 'https?://[^ )"'\''<>]+' <<<"$content")
done < <(grep -nE 'https?://' "$file" 2>/dev/null || true)

if (( violations > 0 )); then
  echo "validate-skill-content: $violations violation(s) in $file" >&2
  exit 1
fi
echo "OK $file"
