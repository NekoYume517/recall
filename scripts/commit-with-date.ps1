# commit-with-date.ps1 — 按指定时间戳提交
# 用法: .\scripts\commit-with-date.ps1 -Repo D:\path -Date "2026-10-02 09:14:00" -Message "feat: xxx"
param(
  [Parameter(Mandatory=$true)][string]$Repo,
  [Parameter(Mandatory=$true)][string]$Date,
  [Parameter(Mandatory=$true)][string]$Message
)

Push-Location $Repo
try {
  $env:GIT_AUTHOR_DATE    = $Date
  $env:GIT_COMMITTER_DATE = $Date
  git add -A
  $staged = git diff --cached --name-only
  if ([string]::IsNullOrWhiteSpace($staged)) {
    Write-Output "nothing staged, skipped"
  } else {
    git commit -q -m $Message
    Write-Output "committed: $Message @ $Date"
  }
}
finally {
  Remove-Item Env:\GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
  Remove-Item Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
  Pop-Location
}
