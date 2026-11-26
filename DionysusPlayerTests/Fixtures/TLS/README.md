# TLS test fixtures

Test-only certificates and private keys (the `.p12` files, password
`dionysus`). They protect nothing: never reuse them anywhere real.

Regenerate with Homebrew OpenSSL 3 or later:

```sh
Scripts/generate-tls-fixtures.sh
```

| Name | What it is |
| --- | --- |
| `selfSignedA`, `selfSignedB` | Self-signed RSA-2048, CN `selfsigned-a.dionysus.test` / `selfsigned-b.dionysus.test` (`.der`, `.p12`) |
| `testCA` | The CA that issued the leaves below (`.der`) |
| `nameLeaf` | Issued by `testCA`, SANs `media.dionysus.test` and `*.wild.dionysus.test` (`.der`, `.p12`) |
| `nameLeafOther` | Issued by `testCA`, SAN `other.dionysus.test` (`.der`) |

The CA and the self-signed pair are valid for about 20 years from generation.
The CA-issued leaves (`nameLeaf`, `nameLeafOther`) are valid for 800 days: Apple's
TLS policy refuses a CA-issued server certificate valid for more than 825 days,
even under a custom anchor ("Certificate exceeds maximum temporal validity
period"). So tests that evaluate them pin a verify date inside their window
(`ServerTrustPolicyTests.nameLeafVerifyDate`; update it when regenerating), and
no live handshake uses them. Last generated 2026-11-23 (leaves valid to
2029-01-31). PKCS#12 uses OpenSSL 3's AES-256-CBC
and SHA-256 MAC, which `SecPKCS12Import` accepts (the old RC2 default it doesn't).
