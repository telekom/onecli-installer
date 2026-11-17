Write-Host "ERROR: OneCLI's install scripts have moved to Deutsche Telekom's internal GitLab. Use the install command from the OneCLI documentation there." -ForegroundColor Red
# Under `irm | iex` $PSCommandPath is empty: return keeps the user's shell open.
if ($PSCommandPath) { exit 1 }
return
