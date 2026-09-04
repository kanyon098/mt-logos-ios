# Mt. Logos — iOS wrapper

A thin WKWebView shell around **https://mtlogos.com** — the App Store version of Mt. Logos.
Free download, no in-app purchase; the subscription lives entirely on the website (Stripe).
Logging in here is the exact same account as the website and the Android app.

This is a **separate, public** repo from the main app on purpose: it holds no business data
and no secrets in its code (everything sensitive lives in GitHub Actions secrets below), so
its GitHub Actions builds get free, uncapped macOS runner minutes — the private main repo's
free macOS minutes are capped and would run out fast.

## How it works

- `Sources/` — the whole app: one `WKWebView` pointed at `mtlogos.com`, with a custom
  User-Agent (`... MtLogosApp/1`) that the Worker (`worker/src/index.js` in the main repo)
  reads to switch `/login` and `/pay` into "app mode" — no prices, no subscribe button, no
  external purchase link. That's what keeps this compliant with App Store Guideline 3.1.1 /
  3.1.3(e). Links to anything off mtlogos.com open in Safari instead of dead-ending here.
- `project.yml` — an [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. There is **no
  committed `.xcodeproj`** — the CI workflow generates one fresh on every run
  (`xcodegen generate`), so nothing here needs Xcode to edit or review.
- `.github/workflows/ios-release.yml` — builds, signs, and uploads to TestFlight on every
  push to `main`, entirely on GitHub's hosted macOS runner. No Mac required, ever.

## Updating the app itself

You almost never need to. Since this is just a web view, any change deployed to mtlogos.com
via `Go Live.bat` (in the main repo) is live in this app the next time it loads — no rebuild,
no resubmission. Rebuild/resubmit here only for things about the **native shell** itself:
app name, icon, bundle id, the User-Agent string, or a new native capability.

## Required GitHub secrets (Settings -> Secrets and variables -> Actions)

| Secret | What it is |
|---|---|
| `APPSTORE_API_KEY_ID` | Key ID from App Store Connect -> Users and Access -> Integrations |
| `APPSTORE_API_ISSUER_ID` | Issuer ID from the same page |
| `APPSTORE_API_PRIVATE_KEY` | The full contents of the downloaded `AuthKey_XXXXXXXXXX.p8` file, pasted as-is (including the `-----BEGIN/END PRIVATE KEY-----` lines) |
| `BUILD_CERTIFICATE_P12` | The Apple Distribution certificate, exported as a `.p12` and base64-encoded (see below) |
| `P12_PASSWORD` | The password you chose when exporting that `.p12` |

**Never commit any of these to the repo.** GitHub secrets are the only place they should live.

### Turning a downloaded `.cer` (from Apple) into the `BUILD_CERTIFICATE_P12` secret value

Apple's Certificates page gives you a `.cer` (the public certificate only). Combined with the
private key that was generated locally when the CSR was made (never uploaded anywhere), it
becomes an importable `.p12`. On the Windows machine that generated the CSR:

```powershell
# 1) Import the downloaded certificate — this completes the pending request and
#    pairs it with the private key already sitting in the Windows certificate store.
certreq -accept path\to\downloaded.cer

# 2) Find the resulting certificate (matches the "Mt Logos LLC" subject) and export
#    it, WITH its private key, as a .p12/.pfx.
$cert = Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -match "Mt Logos LLC" } | Select-Object -First 1
$pw = ConvertTo-SecureString -String "choose-a-password-here" -Force -AsPlainText
Export-PfxCertificate -Cert $cert -FilePath mtlogos-distribution.p12 -Password $pw

# 3) Base64-encode it for pasting into the GitHub secret.
[Convert]::ToBase64String([IO.File]::ReadAllBytes("mtlogos-distribution.p12")) | Set-Clipboard
# now paste (Ctrl+V) directly into the BUILD_CERTIFICATE_P12 secret value on GitHub
```

Set `P12_PASSWORD` to whatever password you chose in step 2.
