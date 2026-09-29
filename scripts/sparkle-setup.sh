#!/bin/sh
# One-time setup for in-app updates. Creates Sparkle's EdDSA signing key in
# your login keychain (or reuses the one already there), writes its public
# half to Resources/sparkle-public-key.txt for bundle.sh, and tells you how
# to hand the private half to the release workflow. Run it once, on your
# Mac, then commit the public key file. Public keys aren't secret.
set -e
cd "$(dirname "$0")/.."

# SwiftPM downloads Sparkle's tools along with the framework.
[ -d .build/artifacts/sparkle ] || swift package resolve
GENERATE_KEYS="$(find .build/artifacts/sparkle -type f -name generate_keys -perm -u+x | head -n 1)"
if [ -z "$GENERATE_KEYS" ]; then
    echo "error: Sparkle's generate_keys isn't under .build/artifacts/sparkle; run swift package resolve" >&2
    exit 1
fi

# Asks the keychain for permission; creates the key only if there's none yet.
"$GENERATE_KEYS"
"$GENERATE_KEYS" -p | tr -d '[:space:]' > Resources/sparkle-public-key.txt
echo
echo "Wrote Resources/sparkle-public-key.txt: $(cat Resources/sparkle-public-key.txt)"
cat <<EOF

Next, give the release workflow the private key, then delete the export:

    $GENERATE_KEYS -x private.key
    gh secret set SPARKLE_ED_PRIVATE_KEY < private.key
    rm private.key

and commit Resources/sparkle-public-key.txt. Keep the key in your keychain
(and a backup somewhere safe): releases signed with any other key won't
install for people who already have Ballast.
EOF
