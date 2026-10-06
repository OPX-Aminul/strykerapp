# Release signing keys

Everything needed to sign a release build of this app lives in this folder.

## ⚠️ Read this first

**This repository is public.** The keystore below — including its **private key** —
plus both passwords are committed here. That means:

* **Anyone can sign an APK that Android will accept as an update to this app.**
* The key can never be made secret again; it is in the git history forever.
* A publicly-known signing key protects nothing. It only keeps *your own* builds
  updating over each other, which is all a public key can do.

The safe alternative: put the four values below into
**Settings → Secrets and variables → Actions** (`SIGNING_KEYSTORE_BASE64`,
`SIGNING_STORE_PASSWORD`, `SIGNING_KEY_ALIAS`, `SIGNING_KEY_PASSWORD`), then delete
this folder from git (`git rm -r signing`). The workflow prefers those secrets
automatically. Making the repository private also keeps this out of the way.

## The key

| Item | Value |
|---|---|
| Keystore file | `signing/stryker-release.jks` |
| Keystore format | JKS |
| Key alias | `stryker` |
| Store password | `xeB7c8HXKxlJOlpTkZbBft78` |
| Key password | `xeB7c8HXKxlJOlpTkZbBft78` |
| Key algorithm | RSA 2048 bit |
| Signature algorithm | SHA256withRSA |
| Valid until | 2054-02-21 |
| Certificate (public) | `signing/stryker-release-cert.pem` |
| SHA-256 fingerprint | `34:A1:E9:76:08:41:5E:33:02:50:F9:BC:6A:AD:48:26:BD:0D:3E:50:9C:4C:FD:6F:35:E5:A0:54:18:3C:AF:BE` |

### Public certificate

```pem
-----BEGIN CERTIFICATE-----
MIIDZzCCAk+gAwIBAgIIVeM1bDyQtu8wDQYJKoZIhvcNAQELBQAwYTELMAkGA1UE
BhMCQkQxDjAMBgNVBAcTBURoYWthMRMwEQYDVQQKEwpPUFgtQW1pbnVsMRMwEQYD
VQQLEwpTdHJ5a2VyT1NTMRgwFgYDVQQDEw9TdHJ5a2VyIFJlbGVhc2UwIBcNMjYx
MDA2MjIzOTM1WhgPMjA1NDAyMjEyMjM5MzVaMGExCzAJBgNVBAYTAkJEMQ4wDAYD
VQQHEwVEaGFrYTETMBEGA1UEChMKT1BYLUFtaW51bDETMBEGA1UECxMKU3RyeWtl
ck9TUzEYMBYGA1UEAxMPU3RyeWtlciBSZWxlYXNlMIIBIjANBgkqhkiG9w0BAQEF
AAOCAQ8AMIIBCgKCAQEA7vntMSLOlJM5ElQyfinD6DkDMTMD/6WyCj07rpvKLSdV
goQ5fuAiP48hHdNhrU7BCPS7X+D4bhUPn6+LynU++KDnJRNS1mJ2FIoPjNLMkqM+
EL/qrhKB3/OVUewqVI7NcNvY069YZYfKbxVY4kKsqK/llXJ7zcbqEY6aie+JRrg+
dkhI5DqgEkMDsNSADHesav9jxVqs61AWx5ElVuJigwV0aWq4z3tEGypTo9+/fufC
ngiYlYuZnpZHBizRuE4p6VzcwDf8CH185XtqL/FtWK5LinmDH8DCMmhantWKalBs
Rdx21hkWxOGkYz1F2BdK14bQsWU6v/VhR3lHR5H9kwIDAQABoyEwHzAdBgNVHQ4E
FgQUvdX4CrVqPBeL6vrfbM5z839FUtIwDQYJKoZIhvcNAQELBQADggEBAKe/dHCu
foxQ7Uv9S0TwyBttOx++J/XF/lhh1nSyae0yuSWULcXAr+XdFgyEp2Qf7z3iy1PM
pd30uPonB/AfkCxJKv/O4EOFCv/ursZbcM58sTc8GbzY3Dxk2P4/ctFxwOhFgOeU
RP99BL2Q7QvJkEEjxJ1hGfAoRDnWrvuA7Z/fg7jfCV1qudPpo97DzEgVs+zz/5bv
Uw+qEYFgXa+nQj9V/i0iaAjEkaRY/ZRjW3lQnMV8TLoX7ohCOOVNA4LQodie4TqE
mmKW98EnidO2QhdfAp17406jO562Dsc0Q+/KWfMLSiYbuR7k3iEPjCRYMbWyg1SI
Hx7ShvcZA2mRs/Y=
-----END CERTIFICATE-----
```

### Keystore, base64 (same bytes as the `.jks` above)

```
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
```

## How CI uses it

`.github/workflows/release.yml` resolves signing material in this order:

1. Repository secret `SIGNING_KEYSTORE_BASE64` (decoded to a temp `.jks`), if set.
2. Otherwise `signing/signing.properties` + the `.jks` in this folder.
3. Otherwise the build falls back to an unsigned **debug** APK.

It then exports `STRYKER_RELEASE_STORE_FILE`, `STRYKER_RELEASE_STORE_PASSWORD`,
`STRYKER_RELEASE_KEY_ALIAS` and `STRYKER_RELEASE_KEY_PASSWORD`, which
`app/build.gradle` reads in its `signingConfigs.release` block.

Every future release must use this same key, otherwise Android refuses to install
it over an older build (`INSTALL_FAILED_UPDATE_INCOMPATIBLE`).

## Building a signed APK locally

```bash
./gradlew :app:assembleRelease \
  -PSTRYKER_RELEASE_STORE_FILE="$PWD/signing/stryker-release.jks" \
  -PSTRYKER_RELEASE_STORE_PASSWORD='xeB7c8HXKxlJOlpTkZbBft78' \
  -PSTRYKER_RELEASE_KEY_ALIAS=stryker \
  -PSTRYKER_RELEASE_KEY_PASSWORD='xeB7c8HXKxlJOlpTkZbBft78'
```

## Rotating the key

A new key means existing installs can no longer be updated in place — users have to
uninstall and reinstall. To rotate:

```bash
keytool -genkeypair -v -keystore signing/stryker-release.jks -storetype JKS \
  -alias stryker -keyalg RSA -keysize 2048 -validity 10000 \
  -dname "CN=Stryker Release, OU=StrykerOSS, O=OPX-Aminul, L=Dhaka, C=BD" \
  -storepass '<new-password>' -keypass '<new-password>'
```

Then update `signing/signing.properties`, this file, and any repository secrets.
