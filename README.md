# Nutanix Move Offline Repository

A self-hosted mirror of the Nutanix Move VM preparation scripts and binaries. Serves the files that Nutanix Move normally fetches from the Move appliance, making it possible to run VM migrations without direct access to the Move appliance IP from the source VMs.

## Background

When Nutanix Move prepares a source VM for migration it runs a preparation script on the VM that downloads additional scripts and binaries from the Move appliance over HTTPS. In environments where the source VMs cannot reach the Move appliance directly, this repo provides an alternative public endpoint serving the exact same files.

The container image is built automatically by GitHub Actions and published to the GitHub Container Registry (`ghcr.io`). The image is a plain nginx serving all resources under `/resources/`.

---

## Repository structure

```
.
├── Dockerfile                   # nginx:alpine with all resources baked in
├── nginx-k8s.conf               # nginx config (HTTP only, TLS terminated by ingress)
├── resources/                   # All scripts and binaries served by the container
│   ├── uvm/
│   │   ├── linux/               # Linux VM entry point scripts
│   │   └── win/                 # Windows VM entry point scripts
│   ├── scripts/
│   │   ├── linux/               # Linux helper scripts
│   │   └── win/                 # Windows helper scripts (PowerShell)
│   ├── installAMD.sh            # VirtIO driver installer (Linux)
│   ├── isAMDInstalled.sh        # VirtIO driver checker (Linux)
│   ├── reconfig_fstab.sh        # fstab reconfiguration (Linux)
│   ├── Nutanix-VirtIO-*.msi     # VirtIO drivers (Windows, 32/64-bit)
│   ├── wmi-net-util.exe         # Network utility (Windows legacy OS)
│   ├── net-util.exe             # Network utility (Windows 11/2025)
│   └── setSANPolicy.bat         # SAN policy script (Windows)
└── k8s/
    └── examples/                # Example Kubernetes manifests
```

---

## Container image

Images are published to: `ghcr.io/gdmjoho/move-repo`

| Tag | When |
|-----|------|
| `latest` | Every push to `main` |
| `sha-<short-sha>` | Every push |
| `1.2.3` / `1.2` | On git tag `v1.2.3` |

The image is built for `linux/amd64` and `linux/arm64`.

---

## Deploy on Kubernetes

### Prerequisites

- Kubernetes cluster with [Traefik](https://traefik.io/) as ingress controller
- [cert-manager](https://cert-manager.io/) with a `letsencrypt` ClusterIssuer
- `kubectl` configured against your cluster

### 1. Edit the ingress hostname

In `k8s/examples/ingress.yaml`, replace `move-repo.example.com` with your actual hostname:

```yaml
  tls:
    - secretName: nutanix-move-repo-tls
      hosts:
        - move-repo.your-domain.com
  rules:
    - host: move-repo.your-domain.com
```

### 2. TLS certificate — choose one option

**Option A — cert-manager (automatic)**

Keep the `cert-manager.io/cluster-issuer: "letsencrypt"` annotation in `ingress.yaml`. cert-manager will create the secret automatically when the ingress is applied. No extra steps needed.

**Option B — manual TLS secret**

If you have your own certificate (e.g. from an internal CA or a wildcard cert), create the secret before applying the ingress:

```bash
kubectl create secret tls nutanix-move-repo-tls \
  --cert=path/to/fullchain.pem \
  --key=path/to/privkey.pem \
  -n nutanix-move-repo
```

Or using an existing `.crt`/`.key` pair:

```bash
kubectl create secret tls nutanix-move-repo-tls \
  --cert=server.crt \
  --key=server.key \
  -n nutanix-move-repo
```

Then remove the `cert-manager.io/cluster-issuer` annotation from `ingress.yaml` before applying.

> **Note:** `k8s/examples/tls-secret.yaml` is an example template showing the Secret structure. Never commit a populated version with real keys to git.

### 3. Apply all manifests

```bash
kubectl apply -f k8s/examples/
```

This creates:
- `Namespace` — `nutanix-move-repo`
- `Deployment` — 1 replica, liveness/readiness probes
- `Service` — ClusterIP on port 80
- `Ingress` — Traefik + cert-manager (automatic TLS)

### 4. Verify

```bash
kubectl rollout status deployment/nutanix-move-repo -n nutanix-move-repo
curl -s https://move-repo.your-domain.com/healthz
```

---

## Usage — preparing source VMs for migration

Replace `<HOSTNAME>` with your ingress hostname in the commands below.

### Linux

```bash
curl -sSk https://<HOSTNAME>/resources/uvm/linux/esx_setup_uvm.sh \
  | sudo sh /dev/stdin \
    --move-address '<HOSTNAME>' \
    --retain-ip \
    --install-amd \
    --reconfig-lvm
```

### Windows

Run in an elevated PowerShell prompt:

```powershell
powershell.exe -command {
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
  $scriptPath = (New-Object System.Net.WebClient).DownloadString('https://<HOSTNAME>/resources/uvm/win/esx_setup_uvm.ps1')
  $retainIP = $true
  $installNgt = $false
  $installVirtio = $true
  $setSanPolicy = $true
  $uninstallVMwareTools = $true
  $minPSVersion = '4.0.0'
  $virtIOVersion = '1.2.5.2'
  Invoke-Command -ScriptBlock ([scriptblock]::Create($scriptPath)) `
    -ArgumentList '<HOSTNAME>',$retainIP,$setSanPolicy,$installNgt,$minPSVersion,$installVirtio,$uninstallVMwareTools,$virtIOVersion
}
```

---

## Updating the image

To release a new version, create a git tag:

```bash
git tag v1.0.0
git push origin v1.0.0
```

GitHub Actions will build and push `ghcr.io/gdmjoho/move-repo:1.0.0` automatically. Update the image tag in `k8s/examples/deployment.yaml` and re-apply.

