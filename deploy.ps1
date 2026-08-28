<#
=============================================================================
  The Answering Diary — one-command deploy to Cloud Run.  (Windows PowerShell)

  This is a direct port of deploy.sh for people working on Windows without
  WSL or Git Bash. It does exactly the same things, in the same order, and is
  equally safe to re-run: every step checks whether the thing already exists.

  Usage:
     .\deploy.ps1                # full deploy (prompts for what it needs)
     .\deploy.ps1 -DryRun        # print what it would do, change nothing
     .\deploy.ps1 -Enforce       # deploy and turn App Check to enforce mode
     .\deploy.ps1 -Redeploy      # skip setup, just rebuild and ship the code

  If PowerShell refuses to run this, it is the execution policy, not the
  script. Allow it for this session only:
     Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
=============================================================================
#>
[CmdletBinding()]
param(
  [switch]$DryRun,
  [switch]$Enforce,
  [switch]$Redeploy,
  [string]$ProjectId = $env:PROJECT_ID,
  [string]$Region    = $(if ($env:REGION)  { $env:REGION }  else { "asia-south1" }),
  [string]$Service   = $(if ($env:SERVICE) { $env:SERVICE } else { "answering-diary" })
)

$ErrorActionPreference = "Stop"
$script:StepNo = 0

function Step($t) { $script:StepNo++; Write-Host ""; Write-Host ("--[ {0:d2} ] {1}" -f $script:StepNo, $t) -ForegroundColor Cyan }
function Ok($t)   { Write-Host "  [ok]   $t" -ForegroundColor Green }
function Skip($t) { Write-Host "  [skip] $t (already done)" -ForegroundColor DarkGray }
function Warn($t) { Write-Host "  [warn] $t" -ForegroundColor Yellow }
function Act($t)  { Write-Host "  [..]   $t" -ForegroundColor Cyan }
function Die($t)  { Write-Host ""; Write-Host "  [FAIL] $t" -ForegroundColor Red; Write-Host ""; exit 1 }

# Run a native command. Returns $true on exit code 0. Never throws.
function Invoke-Native {
  param([string]$Exe, [string[]]$Arguments, [switch]$Quiet)
  if ($DryRun) { Write-Host "  [dry-run] $Exe $($Arguments -join ' ')" -ForegroundColor DarkGray; return $true }
  if ($Quiet) { & $Exe @Arguments *> $null } else { & $Exe @Arguments }
  return ($LASTEXITCODE -eq 0)
}

# Run a native command and capture stdout as a string. Empty string on failure.
function Get-Native {
  param([string]$Exe, [string[]]$Arguments)
  $out = & $Exe @Arguments 2>$null
  if ($LASTEXITCODE -ne 0) { return "" }
  return ($out | Out-String).Trim()
}

# Does a resource exist? (exit code 0 from a `describe` call)
function Test-Native {
  param([string]$Exe, [string[]]$Arguments)
  & $Exe @Arguments *> $null
  return ($LASTEXITCODE -eq 0)
}

# =============================================================================
Step "Preflight"
# =============================================================================
Set-Location -Path $PSScriptRoot

foreach ($f in @("Dockerfile","package.json","server.js","public\index.html","firestore.rules")) {
  if (-not (Test-Path $f)) { Die "Missing $f - run this from the repo root." }
}
Ok "Repo files present"

foreach ($c in @("gcloud","firebase")) {
  if (-not (Get-Command $c -ErrorAction SilentlyContinue)) {
    if ($c -eq "gcloud") { Die "gcloud not found. Install: https://cloud.google.com/sdk/docs/install" }
    else { Die "firebase not found. Install: npm i -g firebase-tools" }
  }
}
Ok "gcloud and firebase found"

$acct = Get-Native "gcloud" @("auth","list","--filter=status:ACTIVE","--format=value(account)")
if (-not $acct) { Die "Not logged in to gcloud. Run: gcloud auth login" }
Ok "gcloud account: $($acct -split "`n" | Select-Object -First 1)"

if (-not (Test-Native "firebase" @("projects:list"))) { Die "Not logged in to firebase. Run: firebase login" }
Ok "firebase authenticated"

# ---------- settings ----------
if (-not $ProjectId) {
  $suggest = "answering-diary-" + (Get-Random -Minimum 1000 -Maximum 9999)
  $inp = Read-Host "  Project id [$suggest]"
  $ProjectId = if ($inp) { $inp } else { $suggest }
}
$inp = Read-Host "  Region [$Region]"
if ($inp) { $Region = $inp }

Write-Host ""
Write-Host "  Project  $ProjectId"
Write-Host "  Region   $Region"
Write-Host "  Service  $Service"
Write-Host ""
$go = Read-Host "  Proceed? [Y/n]"
if ($go -match '^[nN]') { Die "Cancelled." }

$RuntimeSa   = "diary-runtime@$ProjectId.iam.gserviceaccount.com"
$SchedulerSa = "diary-scheduler@$ProjectId.iam.gserviceaccount.com"

if ($Redeploy) {
  Step "Redeploy only - rebuilding and shipping"
  Invoke-Native "gcloud" @("run","deploy",$Service,"--source",".","--region",$Region,"--project",$ProjectId,"--quiet") | Out-Null
  $u = Get-Native "gcloud" @("run","services","describe",$Service,"--region",$Region,"--project",$ProjectId,"--format=value(status.url)")
  Ok "Live at $u"
  exit 0
}

# =============================================================================
Step "Project and billing"
# =============================================================================
if (Test-Native "gcloud" @("projects","describe",$ProjectId)) {
  Skip "Project $ProjectId exists"
} else {
  Act "Creating project $ProjectId"
  if (-not (Invoke-Native "gcloud" @("projects","create",$ProjectId,"--name=The Answering Diary"))) {
    Die "Could not create the project. The id may be taken - try another."
  }
  Ok "Project created"
}
Invoke-Native "gcloud" @("config","set","project",$ProjectId) -Quiet | Out-Null

$billing = Get-Native "gcloud" @("billing","projects","describe",$ProjectId,"--format=value(billingEnabled)")
if ($billing -eq "True") {
  Skip "Billing already linked"
} else {
  Warn "Billing is not linked. Cloud Run and Secret Manager require it."
  Write-Host ""
  & gcloud billing accounts list 2>$null
  Write-Host ""
  $bid = Read-Host "  Billing account id (XXXXXX-XXXXXX-XXXXXX), or blank to link manually later"
  if ($bid) {
    Invoke-Native "gcloud" @("billing","projects","link",$ProjectId,"--billing-account=$bid") | Out-Null
    Ok "Billing linked"
  } else {
    Die "Billing is required. Link it in the console, then re-run this script."
  }
}

# =============================================================================
Step "Enabling APIs (this takes a minute)"
# =============================================================================
Invoke-Native "gcloud" @("services","enable",
  "run.googleapis.com","cloudbuild.googleapis.com","artifactregistry.googleapis.com",
  "secretmanager.googleapis.com","firestore.googleapis.com","identitytoolkit.googleapis.com",
  "firebaseappcheck.googleapis.com","generativelanguage.googleapis.com","cloudscheduler.googleapis.com",
  "--project",$ProjectId) | Out-Null
Ok "APIs enabled"

# =============================================================================
Step "Firebase and Firestore"
# =============================================================================
$fbList = Get-Native "firebase" @("projects:list")
if ($fbList -match [regex]::Escape($ProjectId)) {
  Skip "Firebase already added to project"
} else {
  Act "Adding Firebase to the project"
  Invoke-Native "firebase" @("projects:addfirebase",$ProjectId) | Out-Null
  Ok "Firebase added"
}

if (Test-Native "gcloud" @("firestore","databases","describe","--project",$ProjectId)) {
  Skip "Firestore database exists"
} else {
  Act "Creating Firestore database"
  if (-not (Invoke-Native "gcloud" @("firestore","databases","create","--location=$Region","--project",$ProjectId) -Quiet)) {
    Invoke-Native "gcloud" @("firestore","databases","create","--location=nam5","--project",$ProjectId) | Out-Null
  }
  Ok "Firestore created"
}

# =============================================================================
Step "Web app and public config"
# =============================================================================
$appsOut = Get-Native "firebase" @("apps:list","WEB","--project",$ProjectId)
$appId = ([regex]::Match($appsOut, '1:\d+:web:[a-f0-9]+')).Value
if (-not $appId) {
  Act "Registering a Firebase web app"
  Invoke-Native "firebase" @("apps:create","WEB","The Answering Diary","--project",$ProjectId) -Quiet | Out-Null
  $appsOut = Get-Native "firebase" @("apps:list","WEB","--project",$ProjectId)
  $appId = ([regex]::Match($appsOut, '1:\d+:web:[a-f0-9]+')).Value
  Ok "Web app registered"
} else {
  Skip "Web app exists"
}

if (-not $DryRun -and $appId) {
  Act "Writing public/config.js from the live project config"
  $sdkJson = Get-Native "firebase" @("apps:sdkconfig","WEB",$appId,"--project",$ProjectId,"--json")
  if ($sdkJson) {
    # Preserve an App Check site key already filled in, rather than clobbering it.
    $siteKey = "YOUR_RECAPTCHA_V3_SITE_KEY"
    if (Test-Path "public\config.js") {
      $m = [regex]::Match((Get-Content "public\config.js" -Raw), 'appCheckSiteKey:\s*"([^"]*)"')
      if ($m.Success -and $m.Groups[1].Value) { $siteKey = $m.Groups[1].Value }
    }
    $raw = $sdkJson | ConvertFrom-Json
    $c = if ($raw.result) { $raw.result.sdkConfig } elseif ($raw.sdkConfig) { $raw.sdkConfig } else { $raw }
    $cfg = @"
// Public Firebase web config - safe to expose (identifiers, NOT secrets).
// Generated by deploy.ps1 from the live project. The Gemini key is NOT here:
// it lives in Secret Manager and is used only server-side.
window.APP_CONFIG = {
  firebase: {
    apiKey: "$($c.apiKey)",
    authDomain: "$($c.authDomain)",
    projectId: "$($c.projectId)",
    appId: "$($c.appId)",
  },
  // Same origin - this Cloud Run service serves both the diary and its API.
  apiBase: "/api",

  // App Check (reCAPTCHA v3). Public by design. Register the site key at
  // Firebase Console -> App Check -> Apps -> your web app -> reCAPTCHA v3.
  appCheckSiteKey: "$siteKey",
  appCheckDebug: false,
};
"@
    [System.IO.File]::WriteAllText((Join-Path $PWD "public\config.js"), $cfg, (New-Object System.Text.UTF8Encoding $false))
    Ok "public/config.js written for $ProjectId"
    if ($siteKey -eq "YOUR_RECAPTCHA_V3_SITE_KEY") { Warn "App Check site key still a placeholder - fine for now (monitor mode)." }
  } else {
    Warn "Could not fetch the SDK config. Fill public/config.js by hand."
  }
}

if ($DryRun) {
  Write-Host "  [dry-run] would write .firebaserc" -ForegroundColor DarkGray
} else {
  [System.IO.File]::WriteAllText((Join-Path $PWD ".firebaserc"),
    "{`"projects`":{`"default`":`"$ProjectId`"}}", (New-Object System.Text.UTF8Encoding $false))
  Ok ".firebaserc set"
}

# =============================================================================
Step "Google sign-in - one manual step"
# =============================================================================
Write-Host "  This one cannot be scripted. In another tab:"
Write-Host ""
Write-Host "    https://console.firebase.google.com/project/$ProjectId/authentication/providers" -ForegroundColor White
Write-Host ""
Write-Host "    Authentication -> Sign-in method -> Google -> Enable -> Save"
Read-Host "`n  Press Enter once Google sign-in is enabled" | Out-Null

# =============================================================================
Step "Gemini API key -> Secret Manager"
# =============================================================================
function Set-GeminiSecret {
  param([switch]$NewVersion)
  $secure = Read-Host "  Paste the Gemini API key (hidden)" -AsSecureString
  $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
  try { $plain = [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
  finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
  if (-not $plain) { Die "Empty key." }

  # gcloud needs a file. We use a temp file, no BOM, deleted immediately after.
  # (The server trims whitespace, so a stray newline would be harmless anyway.)
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    [System.IO.File]::WriteAllText($tmp, $plain, (New-Object System.Text.UTF8Encoding $false))
    if ($DryRun) {
      Write-Host "  [dry-run] would store the secret" -ForegroundColor DarkGray
    } elseif ($NewVersion) {
      & gcloud secrets versions add GEMINI_API_KEY --data-file=$tmp --project $ProjectId | Out-Null
    } else {
      & gcloud secrets create GEMINI_API_KEY --data-file=$tmp --replication-policy=automatic --project $ProjectId | Out-Null
    }
  } finally {
    # Overwrite before deleting so the bytes do not linger in the temp dir.
    [System.IO.File]::WriteAllText($tmp, ("0" * 256))
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    $plain = $null
  }
}

if (Test-Native "gcloud" @("secrets","describe","GEMINI_API_KEY","--project",$ProjectId)) {
  Skip "Secret GEMINI_API_KEY exists"
  $rot = Read-Host "  Add a new version (rotate the key)? [y/N]"
  if ($rot -match '^[yY]') { Set-GeminiSecret -NewVersion; Ok "New secret version added" }
} else {
  Write-Host "  Get one from Google AI Studio -> Get API key."
  Set-GeminiSecret
  Ok "Secret created"
}

# =============================================================================
Step "Least-privilege service accounts"
# =============================================================================
if (Test-Native "gcloud" @("iam","service-accounts","describe",$RuntimeSa,"--project",$ProjectId)) {
  Skip "Runtime service account exists"
} else {
  Invoke-Native "gcloud" @("iam","service-accounts","create","diary-runtime","--display-name=Answering Diary runtime","--project",$ProjectId) | Out-Null
  Ok "Runtime service account created"
}

Act "Granting exactly three roles (not the broad default account)"
Invoke-Native "gcloud" @("secrets","add-iam-policy-binding","GEMINI_API_KEY","--member=serviceAccount:$RuntimeSa","--role=roles/secretmanager.secretAccessor","--project",$ProjectId) -Quiet | Out-Null
Invoke-Native "gcloud" @("projects","add-iam-policy-binding",$ProjectId,"--member=serviceAccount:$RuntimeSa","--role=roles/datastore.user") -Quiet | Out-Null
Invoke-Native "gcloud" @("projects","add-iam-policy-binding",$ProjectId,"--member=serviceAccount:$RuntimeSa","--role=roles/firebaseauth.viewer") -Quiet | Out-Null
Ok "secretAccessor / datastore.user / firebaseauth.viewer"

# =============================================================================
Step "Firestore security rules"
# =============================================================================
Act "Deploying default-deny, per-writer isolation rules"
Invoke-Native "firebase" @("deploy","--only","firestore:rules","--project",$ProjectId) | Out-Null
Ok "Rules live - the vault was never briefly open"

# =============================================================================
Step "Deploying to Cloud Run (builds the container; a few minutes)"
# =============================================================================
Invoke-Native "gcloud" @("run","deploy",$Service,
  "--source",".","--region",$Region,"--project",$ProjectId,
  "--service-account",$RuntimeSa,"--allow-unauthenticated",
  "--min-instances","0","--max-instances","10","--memory","512Mi","--cpu","1","--timeout","60",
  "--set-env-vars","APPCHECK_MODE=monitor,GEMINI_CHAT_MODELS=gemini-2.5-flash-lite;gemini-2.5-flash;gemini-3.6-flash,GEMINI_EMBED_MODELS=gemini-embedding-001",
  "--quiet") | Out-Null

if ($DryRun) {
  $Url = "https://$Service-dryrun.a.run.app"
} else {
  $Url = Get-Native "gcloud" @("run","services","describe",$Service,"--region",$Region,"--project",$ProjectId,"--format=value(status.url)")
}
if (-not $Url) { Die "Could not read the service URL." }
Ok "Deployed: $Url"

# =============================================================================
Step "Authorising the domain for Google sign-in"
# =============================================================================
$hostName = $Url -replace '^https://',''
if ($DryRun) {
  Write-Host "  [dry-run] would authorise $hostName" -ForegroundColor DarkGray
} else {
  try {
    $token = Get-Native "gcloud" @("auth","print-access-token")
    $api = "https://identitytoolkit.googleapis.com/admin/v2/projects/$ProjectId/config"
    $cur = Invoke-RestMethod -Uri $api -Headers @{ Authorization = "Bearer $token" } -Method Get
    $domains = @($cur.authorizedDomains)
    if ($domains -contains $hostName) {
      Skip "$hostName already authorised"
    } else {
      $domains += $hostName
      $body = @{ authorizedDomains = $domains } | ConvertTo-Json -Compress
      Invoke-RestMethod -Uri "${api}?updateMask=authorizedDomains" `
        -Headers @{ Authorization = "Bearer $token" } -Method Patch `
        -ContentType "application/json" -Body $body | Out-Null
      Ok "$hostName authorised for sign-in"
    }
  } catch {
    Warn "Could not authorise automatically. Add it by hand:"
    Write-Host "     Firebase Console -> Authentication -> Settings -> Authorised domains -> $hostName"
  }
}

# =============================================================================
Step "Weekly Owl Post schedule"
# =============================================================================
if (Test-Native "gcloud" @("iam","service-accounts","describe",$SchedulerSa,"--project",$ProjectId)) {
  Skip "Scheduler service account exists"
} else {
  Invoke-Native "gcloud" @("iam","service-accounts","create","diary-scheduler","--display-name=Answering Diary scheduler","--project",$ProjectId) | Out-Null
  Ok "Scheduler service account created"
}

Invoke-Native "gcloud" @("run","services","add-iam-policy-binding",$Service,"--region",$Region,"--project",$ProjectId,"--member=serviceAccount:$SchedulerSa","--role=roles/run.invoker") -Quiet | Out-Null
Ok "Scheduler may invoke the service"

Act "Telling the service which caller to trust"
Invoke-Native "gcloud" @("run","services","update",$Service,"--region",$Region,"--project",$ProjectId,
  "--update-env-vars","SCHEDULER_SA=$SchedulerSa,JOB_AUDIENCE=$Url/jobs/owlpost","--quiet") -Quiet | Out-Null

$jobArgs = @("--location",$Region,"--project",$ProjectId,
  "--schedule","0 8 * * 1","--time-zone","Asia/Kolkata",
  "--uri","$Url/jobs/owlpost","--http-method","POST",
  "--oidc-service-account-email",$SchedulerSa,"--oidc-token-audience","$Url/jobs/owlpost")

if (Test-Native "gcloud" @("scheduler","jobs","describe","owlpost-weekly","--location",$Region,"--project",$ProjectId)) {
  Invoke-Native "gcloud" (@("scheduler","jobs","update","http","owlpost-weekly") + $jobArgs) -Quiet | Out-Null
  Ok "Weekly schedule updated"
} else {
  Invoke-Native "gcloud" (@("scheduler","jobs","create","http","owlpost-weekly") + $jobArgs) -Quiet | Out-Null
  Ok "Weekly schedule created - Mondays 08:00 IST"
}

# =============================================================================
Step "Optional: App Check enforce mode"
# =============================================================================
if ($Enforce) {
  Invoke-Native "gcloud" @("run","services","update",$Service,"--region",$Region,"--project",$ProjectId,"--update-env-vars","APPCHECK_MODE=enforce","--quiet") -Quiet | Out-Null
  Ok "Enforce mode ON - unattested clients are refused"
} else {
  Skip "Left in monitor mode (recommended first deploy)"
  Write-Host "     Register reCAPTCHA v3 at App Check, put the site key in public/config.js,"
  Write-Host "     watch the metrics, then re-run:  .\deploy.ps1 -Enforce"
}

# =============================================================================
Step "Verifying"
# =============================================================================
if ($DryRun) {
  Warn "Dry run - nothing was deployed, so nothing to verify."
} else {
  if (Test-Path ".\verify.ps1") { & .\verify.ps1 $Url }
  else { Warn "verify.ps1 not found - check the URL by hand." }
}

# =============================================================================
Write-Host ""
Write-Host "  The diary is open." -ForegroundColor Green
Write-Host ""
Write-Host "  Prototype link (submit this):"
Write-Host "  $Url" -ForegroundColor White
Write-Host ""
Write-Host "  Next:"
Write-Host "    1. Open it, sign in, write a page, seal a memory."
Write-Host "    2. Open InPrivate as a second Google account - the vault should be empty."
Write-Host "    3. Register App Check, then:  .\deploy.ps1 -Enforce"
Write-Host "    4. Logs:  gcloud run services logs read $Service --region $Region --limit 50"
Write-Host ""
