# fleetcommandav-nixos
Hardened OS for hosting fleetcommandav

# NixOS Installation (via GUI installer)
- User setup
  - Set admin password
  - Create a default user
- No desktop environment
- Allow unfree software
- Setup disk
  - No swap partition (zram is used for swap)

# Configure OS
- Run bootstrap.sh (this repository)

```bash
curl -L https://raw.githubusercontent.com/roguenand/fleetcommandav-nixos/main/bootstrap.sh | sudo bash -s
```
