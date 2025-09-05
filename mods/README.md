# Factorio Mods (local development)

This folder holds local mod sources and built zips used by Ansible.

Layout:
- Factorio-AI-agent_<version>/ — mod source (control.lua, info.json)
- (built) ansible/files/mods/Factorio-AI-agent_<version>.zip — packaged by Tools/package_mod.sh

Quick start:
- Update `mods/Factorio-AI-agent_*/info.json` with:
  - `"name": "Factorio-AI-agent"`
  - `"version": "0.0.X"`
  - `"factorio_version": "2.0"`
- Package locally and (optionally) deploy:
  - Local package only: `Tools/package_mod.sh --source mods/Factorio-AI-agent_<ver>`
  - Package + remote deploy + restart: `Tools/package_mod.sh --source mods/Factorio-AI-agent_<ver> --remote auto --instances "ai1,ai2"`

Notes:
- Zip naming must be `<name>_<version>.zip` and will be copied to `ansible/files/mods` (and `/srv/factorio/mods` on remote when `--remote` is used).
- The Ansible role enables all zips found on the server in `mod-list.json` (plus base).
