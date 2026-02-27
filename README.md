# oc-image-mode

[![Build](https://github.com/OpenCHAMI/oc-image-mode/actions/workflows/build_bootc.yml/badge.svg)](https://github.com/OpenCHAMI/oc-image-mode/actions/workflows/build_bootc.yml)
[![Tests](https://github.com/OpenCHAMI/oc-image-mode/actions/workflows/integration_test.yml/badge.svg)](https://github.com/OpenCHAMI/oc-image-mode/actions/workflows/integration_test.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue)](LICENSE)

CentOS Stream 10 [bootc](https://github.com/CentOS/centos-bootc) image preconfigured for [OpenCHAMI](https://github.com/OpenCHAMI) provisioning. Built and pushed to GHCR via GitHub Actions.

Inspired by [redhat-cop/redhat-image-mode-actions](https://github.com/redhat-cop/redhat-image-mode-actions).

## What's in the image

- **cloud-init** -- nocloud-net datasource for OpenCHAMI's cloud-init server
- **openssh-server** -- remote access to compute nodes
- **ipmitool** -- BMC / out-of-band management
- **lldpd** -- network topology discovery
- **rsyslog** -- centralised logging (target set via cloud-init groups)
- **htop, tmux, jq** -- operator quality-of-life tools

A `bootc-user` account with passwordless sudo is created for initial access.

## How it works

<picture>
  <img alt="How oc-image-mode works with OpenCHAMI" src="docs/images/how-it-works.svg">
</picture>

1. GitHub Actions builds the bootc image and pushes it to GHCR.
2. **BSS** hands each compute node its kernel, initrd, and boot parameters.
3. Boot parameters include `ds=nocloud-net;s=http://<cloud-init-server>/cloud-init`, pointing cloud-init at the OpenCHAMI cloud-init server.
4. The cloud-init server uses **SMD** inventory and groups to return per-node configuration.

## Building

Locally:

```bash
buildah bud -t oc-image-mode:latest .
```

No secrets or registry credentials needed -- the base image is public.

### CI triggers

Builds run on **tag pushes** and **pushes to main**, or via **manual dispatch** (Actions tab). The only secret is the automatic `GITHUB_TOKEN`.

Manual dispatch accepts optional inputs:

- **Containerfile** -- path to an alternate Containerfile
- **Extra tags** -- space-separated additional image tags

## Customising the image

Edit the `Containerfile` to add packages. For example:

```dockerfile
RUN dnf -y install ohpc-slurm-client && dnf clean all
```

For node-specific configuration (SSH keys, NTP, syslog targets, etc.), prefer OpenCHAMI cloud-init groups over baking values into the image:

```bash
curl -X POST http://<cloud-init-server>:27777/cloud-init/admin/groups/ \
    -H "Content-Type: application/json" \
    -d '{
        "name": "compute",
        "description": "Compute nodes",
        "file": {
            "content": "#cloud-config\npackage_update: false\nruncmd:\n  - systemctl enable --now slurmd\n",
            "encoding": "plain"
        }
    }'
```

## Deploying

See [docs/deploying-with-openchami.md](docs/deploying-with-openchami.md) for the full walkthrough: registering nodes in SMD, configuring BSS, setting up cloud-init groups, and verifying a boot.

## Tests

Two tiers of automated testing run after each successful build (see [integration_test.yml](.github/workflows/integration_test.yml)):

- **Tier 1 -- Image inspection** (`tests/inspect-image.sh`): mounts the image and verifies packages, services, cloud-init config, and user setup.
- **Tier 2 -- OpenCHAMI smoke test** (`tests/smoke-openchami.sh`): spins up a minimal OpenCHAMI stack via docker compose, registers a fake node, creates cloud-init groups, and validates API responses.

## References

- [OpenCHAMI](https://github.com/OpenCHAMI) -- Open Composable Heterogeneous Adaptable Management Infrastructure
- [OpenCHAMI cloud-init server](https://github.com/OpenCHAMI/cloud-init) -- per-node cloud-init payloads
- [OpenCHAMI BSS](https://github.com/OpenCHAMI/bss) -- Boot Script Service
- [CentOS bootc images](https://github.com/CentOS/centos-bootc) -- upstream bootc project

## License

Apache-2.0. See [LICENSE](LICENSE).
