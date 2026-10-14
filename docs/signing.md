# Release signing

Next Term's releases are signed with one self-signed code-signing certificate, **Next Term Release Signing**. It is
Next Term's own, not Apple's: nothing is notarized. It is also not the release key that signs each release's checksum
(`scripts/sign-release.sh`, `release@next-term.mishuk.me`), which the installer and the updater check first and which
does not change.

## Why

macOS keeps what you allowed (Desktop, Documents, Downloads, a removable or network volume, the camera, the
microphone, contacts, calendars, location, photos, controlling another app) for the app's designated requirement. An
ad-hoc signature's requirement is that one build's hash, so to macOS every update was a new app and it could ask
again. The certificate's requirement names the bundle id and the certificate itself, by its SHA-1, such as

```
identifier "me.mishuk.nextterm" and certificate leaf = H"<the certificate's SHA-1>"
```

It is the same for every build the certificate signs, so your answers carry over from one update to the next.
`codesign -d -r- "/Applications/Next Term.app"` prints it.

## What you see

- **The first install from the disk image** is still blocked once: Next Term is not notarized (that takes an Apple
  Developer ID) and macOS doesn't know this certificate. Allow it with **Open Anyway**, as the README says. The
  one-line installer is not blocked.
- **The first update to a signed release**, from one signed ad hoc, installs as updates always have. Your earlier
  answers were for the ad-hoc build, so macOS may ask once more for each folder or device you had allowed, the first
  time Next Term or a command in it uses it again. On a Mac without a Secure Enclave, where Secrets keeps its key in
  the login keychain, macOS may also ask once whether Next Term may use that key: choose **Always Allow**. Settings
  macOS never asks about, such as Full Disk Access, stop applying: if you turned one on for Next Term, remove Next
  Term from that list in **System Settings → Privacy & Security** with **−** and add it again with **+**, once.
- **Every update after that** asks nothing. A copy signed with the certificate installs an update only when it is
  signed with the same certificate, besides its checksum being signed with the release key.

For the first signed release's notes:

> Next Term is now signed with its own certificate, so macOS remembers what you allow (folders, the camera, the
> microphone and the rest) from one update to the next. After this update it may ask you once more. If you turned on
> Full Disk Access for Next Term, remove it from that list in System Settings → Privacy & Security and add it again.

## For the maintainer

1. Make the identity once, into a new folder: `scripts/make-signing-identity.sh ~/Backups/next-term-signing`. It
   writes the certificate and its key as a `.p12` under a random password, prints the certificate's SHA-1 and
   expiry date, and prints the two `gh secret set` commands (`NEXTTERM_SIGNING_P12`, the `.p12` in base64, and
   `NEXTTERM_SIGNING_P12_PASSWORD`). It uploads nothing and writes into no keychain; run the two commands yourself.
2. CI imports the `.p12` into a keychain of the job's own, signs the app with the certificate's SHA-1 (the hardened
   runtime and the same entitlements as before), and deletes the keychain at the end of the job, also after a
   failure. The Build DMG step prints `designated requirement: …`, which must name the SHA-1 the script printed (in
   lowercase), never a `cdhash`. Without the secrets, as in a fork's pull request, the build is signed ad hoc as before,
   and a tag built that way gets a warning.
3. Once a signed release is out, never publish one signed ad hoc or with another certificate: copies on a signed build
   refuse it as an update ("The new app's signature is broken.") and have to be installed again by hand.
4. Keep the folder offline, with a backup. Losing the key or making a new one is a new identity: signed copies stop
   updating in the app, and macOS asks its questions again. The certificate is valid for 10 years; renewing it is the
   same change.
5. To sign a build on your Mac, open the `.p12` to add it to your login keychain (its password is in the `.password`
   file beside it), then run `SIGN_ID=<the SHA-1> scripts/build-dmg.sh`.

The disk image itself is left unsigned with this certificate. Gatekeeper checks a signed disk image as it opens and
can't pass a self-signed one; unsigned, the image opens as before, and only the app asks for Open Anyway. The
checksum signed with the release key is what vouches for the image.
