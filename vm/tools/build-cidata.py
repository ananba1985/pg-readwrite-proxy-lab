#!/usr/bin/env python3
"""Build a password-free NoCloud seed ISO for one lab VM."""

from __future__ import annotations

import argparse
import ipaddress
import io
import re
from pathlib import Path

import pycdlib


MAC_RE = re.compile(r"^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$")
HOST_RE = re.compile(r"^[a-z][a-z0-9-]{0,62}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--hostname", required=True)
    parser.add_argument("--instance-id", required=True)
    parser.add_argument("--management-mac", required=True)
    parser.add_argument("--cluster-mac", required=True)
    parser.add_argument("--cluster-address", required=True)
    parser.add_argument("--public-key-file", type=Path, required=True)
    return parser.parse_args()


def validate(args: argparse.Namespace) -> ipaddress.IPv4Interface:
    if not HOST_RE.fullmatch(args.hostname):
        raise SystemExit(f"Invalid hostname: {args.hostname}")
    for label, value in (
        ("management MAC", args.management_mac),
        ("cluster MAC", args.cluster_mac),
    ):
        if not MAC_RE.fullmatch(value):
            raise SystemExit(f"Invalid {label}: {value}")
    address = ipaddress.ip_interface(args.cluster_address)
    if not isinstance(address, ipaddress.IPv4Interface):
        raise SystemExit("Only IPv4 cluster addresses are supported")
    return address


def add_text(iso: pycdlib.PyCdlib, text: str, iso_name: str, visible_name: str) -> None:
    data = text.encode("utf-8")
    iso.add_fp(
        io.BytesIO(data),
        len(data),
        iso_path=f"/{iso_name};1",
        rr_name=visible_name,
        joliet_path=f"/{visible_name}",
    )


def main() -> None:
    args = parse_args()
    address = validate(args)
    public_key = args.public_key_file.read_text(encoding="ascii").strip()
    if not public_key.startswith(("ssh-rsa ", "ssh-ed25519 ")):
        raise SystemExit("Unsupported SSH public key")

    meta_data = (
        f"instance-id: {args.instance_id}\n"
        f"local-hostname: {args.hostname}\n"
    )
    user_data = f"""#cloud-config
hostname: {args.hostname}
fqdn: {args.hostname}.lab.internal
manage_etc_hosts: false
ssh_pwauth: false
disable_root: true
users:
  - default
  - name: labadmin
    gecos: PostgreSQL Lab Administrator
    groups: [wheel]
    sudo: [\"ALL=(ALL) NOPASSWD:ALL\"]
    shell: /bin/bash
    lock_passwd: true
    ssh_authorized_keys:
      - {public_key}
growpart:
  mode: auto
  devices: ['/']
resize_rootfs: true
final_message: \"cloud-init completed for {args.hostname}\"
"""
    network_config = f"""version: 1
config:
  - type: physical
    name: eth0
    mac_address: '{args.management_mac.lower()}'
    subnets:
      - type: dhcp4
  - type: physical
    name: eth1
    mac_address: '{args.cluster_mac.lower()}'
    subnets:
      - type: static
        address: {address.with_prefixlen}
"""

    args.output.parent.mkdir(parents=True, exist_ok=True)
    iso = pycdlib.PyCdlib()
    iso.new(
        interchange_level=3,
        joliet=3,
        rock_ridge="1.09",
        vol_ident="CIDATA",
    )
    add_text(iso, meta_data, "META_DAT.", "meta-data")
    add_text(iso, user_data, "USER_DAT.", "user-data")
    add_text(iso, network_config, "NETWORK.", "network-config")
    iso.write(str(args.output))
    iso.close()


if __name__ == "__main__":
    main()
