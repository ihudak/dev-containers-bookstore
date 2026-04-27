#!/usr/bin/env bash
set -euo pipefail

domains_file="${1:-/tmp/allowlist-domains.txt}"
cidrs_file="${2:-/tmp/allowlist-cidrs.txt}"
ipv4_set_name="${3:-allowed_ipv4}"
ipv6_set_name="${4:-allowed_ipv6}"

if [[ ! -f "$domains_file" ]]; then
  printf 'Domains file not found: %s\n' "$domains_file" >&2
  exit 1
fi

if [[ ! -f "$cidrs_file" ]]; then
  printf 'CIDR file not found: %s\n' "$cidrs_file" >&2
  exit 1
fi

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

is_ipv4_cidr() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]
}

is_ipv6_or_cidr() {
  [[ "$1" == *:* ]]
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$command_name" >&2
    exit 1
  fi
}

require_command ipset
require_command getent

# Ensure the live sets exist (first run creates them; subsequent runs reuse them).
ipset create "$ipv4_set_name" hash:net family inet -exist
ipset create "$ipv6_set_name" hash:net family inet6 -exist

# Build new sets in temporary names, then atomically swap them in.
# This eliminates the traffic-drop window that flush+repopulate would cause.
tmp_v4="${ipv4_set_name}_tmp"
tmp_v6="${ipv6_set_name}_tmp"
ipset create "$tmp_v4" hash:net family inet -exist
ipset create "$tmp_v6" hash:net family inet6 -exist
ipset flush "$tmp_v4"
ipset flush "$tmp_v6"

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="$(trim "$raw_line")"
  if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
    continue
  fi

  if is_ipv4 "$line" || is_ipv4_cidr "$line"; then
    ipset add "$tmp_v4" "$line" -exist
    continue
  fi

  if is_ipv6_or_cidr "$line"; then
    ipset add "$tmp_v6" "$line" -exist
    continue
  fi

  mapfile -t resolved_ipv4 < <(getent ahostsv4 "$line" | awk '{print $1}' | sort -u)
  mapfile -t resolved_ipv6 < <(getent ahostsv6 "$line" | awk '{print $1}' | sort -u)

  if [[ ${#resolved_ipv4[@]} -eq 0 && ${#resolved_ipv6[@]} -eq 0 ]]; then
    printf 'Warning: no IPv4 or IPv6 addresses resolved for %s; continuing\n' "$line" >&2
    continue
  fi

  for ip in "${resolved_ipv4[@]}"; do
    ipset add "$tmp_v4" "$ip" -exist
  done

  for ip in "${resolved_ipv6[@]}"; do
    ipset add "$tmp_v6" "$ip" -exist
  done
done < "$domains_file"

while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
  line="$(trim "$raw_line")"
  if [[ -z "$line" || "${line:0:1}" == "#" ]]; then
    continue
  fi

  if is_ipv4 "$line" || is_ipv4_cidr "$line"; then
    ipset add "$tmp_v4" "$line" -exist
    continue
  fi

  if is_ipv6_or_cidr "$line"; then
    ipset add "$tmp_v6" "$line" -exist
    continue
  fi

  printf 'Invalid IP address or CIDR in %s: %s\n' "$cidrs_file" "$line" >&2
  exit 1
done < "$cidrs_file"

# Atomically swap the fully-populated temp sets into the live names.
ipset swap "$tmp_v4" "$ipv4_set_name"
ipset swap "$tmp_v6" "$ipv6_set_name"
# Destroy the old sets (now under the temp names after the swap).
ipset destroy "$tmp_v4"
ipset destroy "$tmp_v6"
