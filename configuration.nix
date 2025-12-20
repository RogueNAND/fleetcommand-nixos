{ config, pkgs, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./common.nix
    ./host.nix
    ./fcav-vpn.nix
  ];
}
