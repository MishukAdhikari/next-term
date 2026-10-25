#!/bin/bash
# Makes the self-signed certificate Next Term's releases are signed with (docs/signing.md), once:
#
#     scripts/make-signing-identity.sh ~/Backups/next-term-signing
#
# Into that folder, which must be new or empty: NextTermSigning.p12 (the certificate and its private key, under a random
# password), that password in NextTermSigning.p12.password, and the certificate alone in NextTermSigning.cer.pem. It then
# prints the two commands that hand the .p12 to CI. It uploads nothing and never writes into a keychain.
#
# Keep the folder offline, with a backup. A new certificate is a new identity: copies signed with this one refuse an
# update signed with another, and macOS asks its privacy questions again.
set -euo pipefail

out="${1:?usage: scripts/make-signing-identity.sh <new or empty folder>}"
repo="MishukAdhikari/next-term"
name="Next Term Release Signing"
# macOS's own LibreSSL, never a Homebrew OpenSSL 3 ahead of it on PATH, with the .p12's algorithms named: 3DES and a
# SHA-1 MAC are what `security import` reads (OpenSSL 3's AES default is refused as a wrong password).
openssl=/usr/bin/openssl

if [ -e "$out" ] && [ -n "$(ls -A "$out")" ]; then
    echo "$out is not empty; a signing identity is made once, into a new folder." >&2
    exit 1
fi
umask 077
mkdir -p "$out"
chmod 700 "$out"
out="$(cd "$out" && pwd)"
p12="$out/NextTermSigning.p12"
cer="$out/NextTermSigning.cer.pem"

# The private key exists unencrypted only in this folder inside the new one, and only until the .p12 holds it.
work="$(mktemp -d "$out/.work.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/request.cnf" <<CNF
[ req ]
distinguished_name = subject
prompt = no
x509_extensions = code_signing
[ subject ]
CN = $name
[ code_signing ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF
if ! "$openssl" req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes -config "$work/request.cnf" \
    -keyout "$work/key.pem" -out "$cer" 2>"$work/request.log"; then
    cat "$work/request.log" >&2
    exit 1
fi

password="$("$openssl" rand -hex 24)"
NT_P12_PASSWORD="$password" "$openssl" pkcs12 -export -name "$name" -inkey "$work/key.pem" -in "$cer" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout env:NT_P12_PASSWORD -out "$p12"
printf '%s' "$password" > "$p12.password"
# It opens with that password: what CI's `security import` is given.
NT_P12_PASSWORD="$password" "$openssl" pkcs12 -in "$p12" -passin env:NT_P12_PASSWORD -noout

fingerprint="$("$openssl" x509 -in "$cer" -noout -fingerprint -sha1)"
sha1="$(tr -d ':' <<<"${fingerprint#*=}" | tr 'A-F' 'a-f')"
expires="$("$openssl" x509 -in "$cer" -noout -enddate)"

echo "Made \"$name\" in $out:"
echo "  NextTermSigning.p12           the certificate and its private key (password in NextTermSigning.p12.password)"
echo "  NextTermSigning.cer.pem       the certificate alone"
echo "  SHA-1 $sha1, valid until ${expires#*=}"
echo
echo "A build signed with it has a designated requirement that names this SHA-1 (codesign -d -r- shows it;"
echo "scripts/build-dmg.sh prints it as it signs)."
echo
echo "Hand it to CI yourself (nothing has been uploaded):"
printf '  base64 -i %q | gh secret set NEXTTERM_SIGNING_P12 --repo %s\n' "$p12" "$repo"
printf '  gh secret set NEXTTERM_SIGNING_P12_PASSWORD --repo %s < %q\n' "$repo" "$p12.password"
echo
echo "Then keep this folder offline, with a backup."
