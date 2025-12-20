{ config, lib, pkgs, ... }:

let
  inherit (lib) mkIf mkOption mkEnableOption types optional optionalString concatStringsSep escapeShellArg;

  cfg = config.fcav.vpn;

  routesFlags =
    lib.concatMap (r: [ "--advertise-routes=${r}" ]) (cfg.advertiseRoutes or []);

  upFlags =
    (optional cfg.ssh "--ssh")
    ++ (optional cfg.exitNode "--advertise-exit-node")
    ++ (optional (cfg.loginServer != null) ("--login-server=" + cfg.loginServer))
    ++ [
      "--hostname=${config.networking.hostName}"
    ]
    ++ routesFlags;


  upFlagsStr = concatStringsSep " " (map escapeShellArg upFlags);

  authFile = "/var/lib/fcav/secrets/tailscale-authkey";
  authArg = "--authkey file:${escapeShellArg authFile}";
in
{
  options.fcav.vpn = {
    enable = mkEnableOption "FCAV VPN (Tailscale/Headscale)";

    loginServer = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional Headscale login server URL.";
    };

    ssh = mkOption { type = types.bool; default = false; };
    exitNode = mkOption { type = types.bool; default = true; };

    advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [];
      description = "Routes to advertise via Tailscale (IPv4 or IPv6 CIDRs). For 4via6, put the computed IPv6 prefix here.";
      example = [ "fd7a:115c:a1e0:ab12::/64" ];
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.exitNode || (cfg.advertiseRoutes != []);
        message = "fcav.vpn: set exitNode=true and/or provide advertiseRoutes.";
      }
    ];

    # tailscaled daemon enabled; the "up" flags are handled by fcav-tailscale-up service
    services.tailscale.enable = true;
    services.tailscale.useRoutingFeatures =
      if cfg.exitNode && (cfg.advertiseRoutes != []) then "both"
      else if cfg.exitNode then "client"
      else if (cfg.advertiseRoutes != []) then "server"
      else "client"; # harmless default, but you probably always do one of the above

    services.tailscale.authKeyFile = authFile;

    # Run tailscale up deterministically each boot (with --reset fallback)
    systemd.services.fcav-tailscale-up = {
      description = "FCAV: run tailscale up with config-derived flags";
      after = [ "network-online.target" "tailscaled.service" ];
      wants = [ "network-online.target" "tailscaled.service" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig.Type = "oneshot";
      path = [ pkgs.tailscale pkgs.coreutils ];

      script = ''
        set -euo pipefail

        ${optionalString (authFile != null) ''
        AUTH=${escapeShellArg authFile}
        if [ ! -s "$AUTH" ]; then
          echo "Tailscale auth key not present at $AUTH; skipping tailscale up."
          exit 0
        fi
        ''}

        for i in $(seq 1 10); do
          tailscale status >/dev/null 2>&1 && break || true
          sleep 1
        done

        cmd="tailscale up ${authArg} ${upFlagsStr}"
        echo "Running: $cmd"
        if ! eval "$cmd"; then
          echo "tailscale up failed; retrying with --reset"
          eval "tailscale up --reset ${authArg} ${upFlagsStr}"
        fi
      '';
    };

    # Tweak UDP for optimal performance
    systemd.services.fcav-tailscale-udp-gro-tune = {
      description = "FCAV: tune NIC UDP GRO settings for Tailscale exit/subnet routing";
      after = [ "network.target" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];

      serviceConfig = {Type = "oneshot";};

      path = [ pkgs.iproute2 pkgs.ethtool pkgs.coreutils pkgs.gawk ];

      script = ''
        set -euo pipefail

        # Wait up to 60s for a default route to appear
        for i in $(seq 1 30); do
          NETDEV="$(ip route show default 0.0.0.0/0 2>/dev/null | ${pkgs.gawk}/bin/awk '/default/ {print $5; exit}')"
          [ -n "$NETDEV" ] && break
          sleep 2
        done

        if [ -z "${NETDEV:-}" ]; then
          echo "No default route found; skipping UDP GRO tuning."
          exit 0
        fi

        echo "Applying Tailscale UDP GRO tuning on $NETDEV"
        ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off || true
      '';
    };
  };
}
