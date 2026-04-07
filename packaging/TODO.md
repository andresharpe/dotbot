# Packaging TODO

Steps to complete package distribution for dotbot.

## Prerequisites

- [ ] Register on [PowerShell Gallery](https://www.powershellgallery.com/) and generate an API key
- [ ] Create GitHub fine-grained PATs for Scoop and Homebrew repo access

## GitHub Secrets & Variables

- [ ] Add secret `PSGALLERY_API_KEY` (from PSGallery account)
- [ ] Add secret `SCOOP_REPO_TOKEN` (fine-grained PAT with `contents: write` on `andresharpe/scoop-dotbot`)
- [ ] Add secret `HOMEBREW_REPO_TOKEN` (fine-grained PAT with `contents: write` on `andresharpe/homebrew-dotbot`)
- [ ] Set repo variable `ENABLE_PSGALLERY` to `true` when ready
- [ ] Set repo variable `ENABLE_SCOOP` to `true` when ready
- [ ] Set repo variable `ENABLE_HOMEBREW` to `true` when ready

## External Repositories

- [ ] Create `andresharpe/scoop-dotbot` repo with `bucket/dotbot.json` from `packaging/scoop/`
- [ ] Create `andresharpe/homebrew-dotbot` repo with `Formula/dotbot.rb` from `packaging/homebrew/`

## First Release

- [ ] Verify `version.json` is set to the desired version (currently `3.1.0`)
- [ ] Tag `v3.1.0` and push — this triggers `.github/workflows/release.yml`
- [ ] Verify GitHub Release is created with `.tar.gz`, `.zip`, and `.sha256` assets

## Verify Install Methods

- [ ] `irm https://raw.githubusercontent.com/andresharpe/dotbot/main/install-remote.ps1 | iex`
- [ ] `Install-Module dotbot -Scope CurrentUser` (PSGallery)
- [ ] `scoop bucket add dotbot https://github.com/andresharpe/scoop-dotbot && scoop install dotbot` (Windows)
- [ ] `brew tap andresharpe/dotbot && brew install dotbot` (macOS/Linux)
- [ ] Run `dotbot help`, `dotbot init`, `dotbot status` from each install method
- [ ] Test upgrade: bump version, re-tag, verify `Update-Module` / `scoop update` / `brew upgrade`

## Optional

- [ ] Set up custom domain (e.g., `irm dotbot.dev/install | iex`)
- [ ] Submit to Scoop `extras` bucket for wider discoverability
- [ ] Consider WinGet manifest submission if there's demand
