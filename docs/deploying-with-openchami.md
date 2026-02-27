# Deploying with OpenCHAMI

This guide walks through booting compute nodes with the CentOS Stream 10 bootc image built by this repository, using an [OpenCHAMI](https://github.com/OpenCHAMI) cluster for provisioning.

> **TL;DR** -- Register nodes in SMD, point BSS at the bootc image, create cloud-init groups for per-role config, PXE boot, verify.

## Prerequisites

- A running OpenCHAMI deployment (see the [quickstart](https://github.com/OpenCHAMI/deployment-recipes/tree/main/quickstart))
- The image pushed to GHCR (e.g. `ghcr.io/<your-user>/oc-image-mode:latest`)
- Access to the OpenCHAMI admin APIs (JWT access token)
- Compute nodes capable of PXE booting on the management network

Throughout this guide, replace the placeholder values with your environment's specifics:

| Placeholder | Example |
|---|---|
| `$OCHAMI_HOST` | `foobar.openchami.cluster` |
| `$CACERT` | `cacert.pem` |
| `$ACCESS_TOKEN` | JWT from `gen_access_token` |
| `$IMAGE` | `ghcr.io/<user>/oc-image-mode:latest` |

If you are using the quickstart, source the helper functions first:

```bash
cd deployment-recipes/quickstart/
source bash_functions.sh
get_ca_cert > cacert.pem
ACCESS_TOKEN=$(gen_access_token)
```

## 1. Register nodes in SMD

Each compute node needs a component entry in SMD with its xname and MAC address. This lets BSS and the DHCP service resolve nodes during PXE boot.

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "https://$OCHAMI_HOST:8443/hsm/v2/State/Components" \
    -d '{
        "Components": [
            {
                "ID": "x3000c1b1n1",
                "State": "Ready",
                "NetType": "Sling",
                "Arch": "X86",
                "NID": 1
            }
        ]
    }'
```

Register the node's MAC address as an Ethernet Interface so DHCP and BSS can match it:

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "https://$OCHAMI_HOST:8443/hsm/v2/Inventory/EthernetInterfaces" \
    -d '{
        "Description": "Management NIC",
        "MACAddress": "aa:bb:cc:dd:ee:01",
        "ComponentID": "x3000c1b1n1",
        "IPAddresses": [{"IPAddress": "192.168.0.10"}]
    }'
```

## 2. Configure BSS boot parameters

BSS needs to know which kernel, initrd, and parameters to hand to each node. The critical parameter for OpenCHAMI integration is the cloud-init datasource URL.

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X PUT "https://$OCHAMI_HOST:8443/boot/v1/bootparameters" \
    -d '{
        "macs": ["aa:bb:cc:dd:ee:01"],
        "params": "console=tty0 console=ttyS0,115200 ip=dhcp cloud-init=enabled ds=nocloud-net;s=http://cloud-init:27777/cloud-init/ root=live:$IMAGE rd.live.dir=/ rd.live.squashimg=rootfs",
        "kernel": "https://$OCHAMI_HOST:8443/boot/v1/kernel",
        "initrd": "https://$OCHAMI_HOST:8443/boot/v1/initrd"
    }'
```

Key kernel parameters:

| Parameter | Purpose |
|---|---|
| `cloud-init=enabled` | Activates cloud-init in the initramfs |
| `ds=nocloud-net;s=http://cloud-init:27777/cloud-init/` | Tells cloud-init where to fetch its configuration (see note below) |
| `root=live:$IMAGE` | Points at the bootc image for the root filesystem |

`cloud-init` in the datasource URL is the Docker service hostname used by the quickstart stack. Replace it with the actual IP or hostname of your cloud-init server in production deployments.

Adjust the `kernel` and `initrd` URLs to match your environment's boot artifact locations.

## 3. Set up cloud-init groups

Cloud-init groups let you apply configuration to categories of nodes. The cloud-init server returns per-group YAML files via the vendor-data `#include` mechanism.

### Create a compute group

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "https://$OCHAMI_HOST:8443/cloud-init/admin/groups/" \
    -d '{
        "name": "compute",
        "description": "Compute nodes",
        "file": {
            "content": "#cloud-config\npackage_update: false\nruncmd:\n  - echo \"Node provisioned via OpenCHAMI\" > /var/log/ochami-boot.log\n",
            "encoding": "plain"
        }
    }'
```

### Set cluster defaults (SSH keys, cluster name, etc.)

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "https://$OCHAMI_HOST:8443/cloud-init/admin/cluster-defaults/" \
    -d '{
        "cloud-provider": "openchami",
        "cluster-name": "my-cluster",
        "public-keys": [
            "ssh-ed25519 AAAA... admin@head-node"
        ]
    }'
```

### Add the node to the compute group in SMD

```bash
curl --cacert "$CACERT" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST "https://$OCHAMI_HOST:8443/hsm/v2/groups" \
    -d '{
        "label": "compute",
        "description": "Compute nodes",
        "members": {
            "ids": ["x3000c1b1n1"]
        }
    }'
```

## 4. Boot and verify

PXE boot the node. The boot sequence is:

<picture>
  <img alt="OpenCHAMI boot sequence" src="images/boot-sequence.svg">
</picture>

1. Node PXE boots and contacts CoreDHCP (via OpenCHAMI's coresmd plugin)
2. DHCP directs the node to the iPXE boot script from BSS
3. BSS delivers the kernel, initrd, and kernel parameters
4. The node boots the CentOS Stream 10 bootc image
5. cloud-init starts and fetches its config from the OpenCHAMI cloud-init server
6. Per-node and per-group configurations are applied

### Verify cloud-init ran

SSH into the node (using the SSH key from cluster defaults) and check:

```bash
# Check cloud-init status
cloud-init status --long

# Review cloud-init logs
less /var/log/cloud-init.log

# Confirm the marker file from the compute group
cat /var/log/ochami-boot.log

# Verify services are running
systemctl is-active sshd lldpd rsyslog
```

### Verify from the head node

You can also query the cloud-init impersonation endpoint (if enabled) to see what a node would receive:

```bash
curl --cacert "$CACERT" \
    "https://$OCHAMI_HOST:8443/cloud-init/admin/impersonation/x3000c1b1n1/meta-data"

curl --cacert "$CACERT" \
    "https://$OCHAMI_HOST:8443/cloud-init/admin/impersonation/x3000c1b1n1/vendor-data"
```