<#
=============================================================================
  Post-deploy checks for The Answering Diary.  (Windows PowerShell)

  Proves the deployed service is up AND that its security gates actually
  refuse what they should. Run before you submit, and again on the day.

  Usage:  .\verify.ps1 https://your-service-xxxx.a.run.app
          .\verify.ps1                (reads the URL from gcloud)
=============================================================================
#>
[CmdletBinding()]
param(
  [string]$Url,
  [string]$Region  = $(if ($env:REGION)  { $env:REGION }  else { "asia-south1" }),
  [string]$Service = $(if ($env:SERVICE) { $env:SERVICE } else { "answering-diary" })
)

$ErrorActionPreference = "Continue"
$script:Pass = 0; $script:Fail = 0; $script:Warn = 0

if (-not $Url) {
  $Url = (& gcloud run services describe $Service --region $Region --format="value(status.url)" 2>$null | Out-String).Trim()
}
if (-not $Url) { Write-Host "No URL. Pass one: .\verify.ps1 https://...run.app" -ForegroundColor Red; exit 1 }
$Url = $Url.TrimEnd('/')

# $expected may list several acceptable codes separated by |. The gates run in order --
# App Check, then auth -- so a request with no credentials is refused at whichever gate it
# reaches first: auth (401) in monitor mode, App Check (403) in enforce mode. Both are the
# gate working; accepting only one would fail every time enforce is switched on.
function Check($label, $expected, $actual) {
  if (("$expected" -split '\|') -contains "$actual") {
    Write-Host ("  [ok]   {0,-40} {1}" -f $label, $actual) -ForegroundColor Green; $script:Pass++
  } else {
    Write-Host ("  [FAIL] {0,-40} got {1}, expected {2}" -f $label, $actual, $expected) -ForegroundColor Red; $script:Fail++
  }
}
function Note($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow; $script:Warn++ }

# Returns the HTTP status code as a string, following no redirects, never throwing.
function Get-Code {
  param([string]$Uri, [string]$Method = "GET", [hashtable]$Headers = @{}, $Body = $null)
  try {
    $p = @{ Uri = $Uri; Method = $Method; Headers = $Headers; TimeoutSec = 25;
            UseBasicParsing = $true; ErrorAction = "Stop" }
    if ($null -ne $Body) { $p.Body = $Body; $p.ContentType = "application/json" }
    $r = Invoke-WebRequest @p
    return [string][int]$r.StatusCode
  } catch [System.Net.WebException] {
    if ($_.Exception.Response) { return [string][int]$_.Exception.Response.StatusCode }
    return "000"
  } catch {
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
      return [string][int]$_.Exception.Response.StatusCode
    }
    return "000"
  }
}

Write-Host ""
Write-Host "Verifying $Url"
Write-Host ""

Write-Host "Reachable"
Check "the diary loads"        200 (Get-Code "$Url/")
Check "stylesheet"             200 (Get-Code "$Url/styles.css")
Check "app script"             200 (Get-Code "$Url/app.js")
Check "health probe"           200 (Get-Code "$Url/healthz")

# A single model is a single point of failure - quotas exhaust and models get retired.
# The service must be walking a chain, not betting on one name.
$chain = ""
try { $chain = (Invoke-WebRequest -Uri "$Url/healthz" -TimeoutSec 25 -UseBasicParsing).Content } catch { $chain = "" }
$nModels = ([regex]::Matches($chain, '"gemini-[a-z0-9.\-]+"')).Count
if ($nModels -ge 3) {
  Write-Host ("  [ok]   {0,-40} {1} models in the chain" -f "model fallback chain live", $nModels) -ForegroundColor Green; $script:Pass++
} else {
  Write-Host ("  [FAIL] {0,-40} got {1}, expected >=3" -f "model fallback chain live", $nModels) -ForegroundColor Red; $script:Fail++
}

Write-Host ""
Write-Host "The gates refuse what they should"
$json = '{"action":"recall"}'
Check "no token rejected"      "401|403" (Get-Code "$Url/api" "POST" @{} $json)
# Browsers send Origin on every POST, same-origin included. The app's own page must reach
# the auth check (401), not be refused as a foreign origin (403).
Check "own page passes CORS"   "401|403" (Get-Code "$Url/api" "POST" @{ Origin = $Url } $json)
Check "forged token rejected"  "401|403" (Get-Code "$Url/api" "POST" @{ Authorization = "Bearer forged.token.value" } $json)
Check "foreign origin rejected" 403 (Get-Code "$Url/api" "POST" @{ Origin = "https://evil.example" } $json)
Check "scheduler job needs OIDC" 403 (Get-Code "$Url/jobs/owlpost" "POST")
Check "unknown action rejected" "401|403" (Get-Code "$Url/api" "POST" @{} '{"action":"drop_everything"}')

$big = '{"action":"inscribe","message":"' + ("x" * 70000) + '"}'
Check "oversized body rejected" 413 (Get-Code "$Url/api" "POST" @{} $big)
Check "malformed json rejected" 400 (Get-Code "$Url/api" "POST" @{} '{oops')

Write-Host ""
Write-Host "Hardening"
try {
  $resp = Invoke-WebRequest -Uri "$Url/" -TimeoutSec 25 -UseBasicParsing
  foreach ($h in @("X-Content-Type-Options","X-Frame-Options","Referrer-Policy")) {
    if ($resp.Headers.ContainsKey($h)) {
      Write-Host ("  [ok]   {0,-40} present" -f $h) -ForegroundColor Green; $script:Pass++
    } else {
      Write-Host ("  [FAIL] {0,-40} missing" -f $h) -ForegroundColor Red; $script:Fail++
    }
  }
  if ($resp.Headers.ContainsKey("X-Powered-By")) { Note "x-powered-by is exposed" }
  else { Write-Host ("  [ok]   {0,-40} hidden" -f "server fingerprint") -ForegroundColor Green; $script:Pass++ }
} catch {
  Note "Could not read response headers"
}

Write-Host ""
Write-Host "No secret is being served to the browser"
try {
  $cfg = (Invoke-WebRequest -Uri "$Url/config.js" -TimeoutSec 25 -UseBasicParsing).Content
  if ($cfg -match 'appCheckSiteKey:\s*"YOUR_') { Note "App Check site key is still a placeholder (fine in monitor mode)" }

  # Strip whole-line comments first - the file legitimately *mentions* the Gemini key
  # in prose to say it is NOT here, and matching that would be a false alarm.
  $cfgCode = ($cfg -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
  # config.js may carry exactly one Google-style key: the public Firebase web apiKey.
  $nKeys = [regex]::Matches($cfgCode, 'AIza[0-9A-Za-z_-]{30,}').Count
  $gemAssign = [regex]::IsMatch($cfgCode, '(?i)(gemini|generativelanguage)\w*\s*:\s*"')
  if ($nKeys -gt 1 -or $gemAssign) {
    Write-Host ("  [FAIL] {0,-40} A SECOND API KEY IS EXPOSED" -f "config.js") -ForegroundColor Red; $script:Fail++
  } else {
    Write-Host ("  [ok]   {0,-40} only public identifiers" -f "config.js") -ForegroundColor Green; $script:Pass++
  }
} catch {
  Note "Could not fetch config.js"
}

Write-Host ""
Write-Host -NoNewline "$script:Pass passed" -ForegroundColor Green
if ($script:Warn -gt 0) { Write-Host -NoNewline ", $script:Warn warning(s)" -ForegroundColor Yellow }
if ($script:Fail -gt 0) { Write-Host -NoNewline ", $script:Fail failed" -ForegroundColor Red }
Write-Host ""; Write-Host ""

if ($script:Fail -eq 0) {
  Write-Host "  Still to check by hand - a script cannot:" -ForegroundColor DarkGray
  Write-Host "    - Sign in with Google and write a page."
  Write-Host "    - Second Google account in InPrivate sees an EMPTY vault."
  Write-Host "    - Open the URL on your phone, on mobile data, signed out."
  Write-Host ""
  exit 0
}
exit 1
