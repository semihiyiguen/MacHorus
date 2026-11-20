#!/usr/bin/env bash
# Creates the stable, self-signed code-signing identity "MacHorus Signing".
#
# A stable identity keeps the app's designated requirement constant, so macOS
# keeps granted permissions (Accessibility, Screen Recording) across updates.
# The identity lives in its own keychain; that keychain's random password is
# stored in the login keychain and never written to disk or the repository.
#
# Idempotent and conservative: an existing identity is never replaced, because
# a new certificate would revoke every user's granted permissions.
set -euo pipefail

IDENTITY="MacHorus Signing"
KC="$HOME/Library/Keychains/machorus-signing.keychain-db"
PW_SERVICE="machorus-signing-keychain"

keychain_password() {
  security find-generic-password -s "$PW_SERVICE" -a "$USER" -w 2>/dev/null
}

identity_can_sign() {
  local pw probe rc=1
  pw="$(keychain_password)" || return 1
  security unlock-keychain -p "$pw" "$KC" 2>/dev/null || return 1
  probe="$(mktemp)"
  cp /bin/echo "$probe"
  codesign --force --sign "$IDENTITY" --keychain "$KC" "$probe" >/dev/null 2>&1 && rc=0
  rm -f "$probe"
  return "$rc"
}

if [[ -e "$KC" ]]; then
  if identity_can_sign; then
    echo "Signing identity '$IDENTITY' already exists and works."
    exit 0
  fi
  echo "Keychain $KC exists but cannot sign. Refusing to replace it; inspect it manually." >&2
  exit 1
fi

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -subj "/CN=$IDENTITY" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# Legacy PBE/MAC algorithms: /usr/bin/openssl is LibreSSL and security(1)
# imports these reliably.
p12_pass="$(openssl rand -hex 24)"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -passout "pass:$p12_pass" -name "$IDENTITY" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1

kc_pass="$(openssl rand -hex 32)"
security add-generic-password -U -s "$PW_SERVICE" -a "$USER" -w "$kc_pass" \
  -l "MacHorus signing keychain" -T /usr/bin/security
security create-keychain -p "$kc_pass" "$KC"
security set-keychain-settings -l -u -t 900 "$KC"   # lock on sleep and after 15 min
security unlock-keychain -p "$kc_pass" "$KC"
security import "$work/identity.p12" -k "$KC" -P "$p12_pass" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$kc_pass" "$KC" >/dev/null

# Prepend the new keychain to the user search list, keeping existing entries.
search_list=("$KC")
while IFS= read -r entry; do
  entry="${entry#"${entry%%[![:space:]]*}"}"
  entry="${entry//\"/}"
  [[ -n "$entry" && "$entry" != "$KC" ]] && search_list+=("$entry")
done < <(security list-keychains -d user)
security list-keychains -d user -s "${search_list[@]}"

if ! identity_can_sign; then
  echo "Identity imported, but codesign cannot sign with it." >&2
  exit 1
fi

echo "Created signing identity '$IDENTITY' in $KC."
echo "Certificate SHA-256: $(openssl x509 -in "$work/cert.pem" -noout -fingerprint -sha256 | cut -d= -f2)"
echo "Next: keep a password-protected backup of this identity, or permissions reset when it is recreated."
