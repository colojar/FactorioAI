# Ansible: Factorio server provisioning and mod deploy

Prereqs:
- Ansible Core 2.14+ (tested with 2.18)
- community.general collection (for ufw) if using firewall tasks
- SSH access to your server(s)
- Install collections: `ansible-galaxy install -r requirements.yml`

Inventory:
- `inventory.yml` defines host `ceres.coloweb.be` (user `tripkipke` by default).

Files:
- `files/factorio-space-age_linux_2.0.60.tar.xz` — headless server tarball
- `files/mods/Factorio-AI-agent_<version>.zip` — local agent mod zip (required)

Role: `roles/factorio_server`
- Installs Factorio under `/opt/factorio` and data under `/srv/factorio`
- Creates per-instance saves and systemd units `factorio-<instance>.service`
- Builds `mod-list.json` from all mod zips present on server
- Optional: UFW rules per instance, logrotate

Important vars (see `roles/factorio_server/defaults/main.yml`):
- `instances`: list of instance names (e.g., `["ai1","ai2"]`)
- `game_port_base`: default 34197, unique per instance
- `rcon_port_base`: default 27015, unique per instance
- `mods_download`: list of mods to fetch from Mod Portal (optional)
- Mod Portal creds (optional): set in `ansible/.secrets/factorio.yml`

Provision server:
```bash
ansible-playbook -i inventory.yml factorio-server.yml
```

Deploy/upgrade the agent mod:
```bash
# Package + upload + restart selected instances
ansible-playbook -i inventory.yml deploy-agent-mod.yml -e agent_version=0.0.2 -e 'agent_instances=["ai1","ai2"]'
# Or pass a simple string
ansible-playbook -i inventory.yml deploy-agent-mod.yml -e agent_version=0.0.2 -e agent_instances="ai1,ai2"

# Direct packager (optional): Tools/package_mod.sh
# Auto-detect remote from inventory, then copy and restart selected instances
../Tools/package_mod.sh --remote auto --instances "ai1,ai2"
```

Toggles:
- Firewall (UFW): `ufw_manage: true`, `ufw_enable: true`, `ufw_default_policy: deny` (uses community.general.ufw)
- Logrotate: `logrotate_manage: true`

Troubleshooting:
- If a task fails due to missing agent zip, ensure it exists under `files/mods/` with correct `<name>_<version>.zip` (name must be `Factorio-AI-agent`).
- If ports collide, adjust `game_port_base`/`rcon_port_base` or instance list.
