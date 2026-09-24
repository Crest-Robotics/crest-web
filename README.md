# crest-web

Caddy reverse proxy for `crest.internal` and a private container registry.

## Architecture

All `*.crest.internal` DNS resolves to `caterpi.crest.internal` via a dnsmasq wildcard on the router. Caddy (using [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)) reads Docker container labels to automatically route subdomains to the correct service — no central config file to maintain.

```
*.crest.internal (dnsmasq wildcard → Pi IP)
        ↓
  Caddy (caddy-docker-proxy)   [caddy/compose.yaml]
        ↓
  crest-web Docker network [compose.yaml]
  ├── registry.crest.internal  [registry/compose.yaml]
  └── any other service on the network, in this repo or any other
```

The top-level `compose.yaml` pins the project name (`crest-web`), defines the `crest-web` network and pulls in each service with `include:`. Always run `up`/`down` from the repo root: the included files reference the network without declaring it, so they can't be run on their own with `-f`.

## Repo structure

```
compose.yaml                  # Project name + include list — run this on the Pi
caddy/compose.yaml            # Caddy reverse proxy
registry/compose.yaml         # Private OCI registry
.env.example                  # Required variables — copy to .env (gitignored)
```

> **Don't change the project name or the `caddy-data` volume key.** The volume `crest-web_caddy-data` holds Caddy's internal CA root key. If it is recreated, every client's trusted CA stops working.

## Setup

### 1. Router DNS (GL-MT6000)

Reserve a static IP for `caterpi` by MAC address: **Clients → caterpi → IP Reservation**.

Then add the wildcard DNS entry. In LuCI (**Network → DHCP and DNS → General Settings → Addresses**), add:

```
/.crest.internal/<caterpi-static-ip>
```

Save and apply.

### 2. Start the stack

Configure the environment:

```sh
cp .env.example .env
$EDITOR .env                     # see comments in the file
mkdir -p /mnt/data/registry      # or whatever REGISTRY_DATA_DIR is set to
```

Then, from the repo root:

```sh
docker compose config            # sanity check
docker compose up -d
```

This creates the `crest-web` network, starts Caddy on ports 80/443 and starts the registry behind it.

> `docker compose down` also removes the `crest-web` network. That fails while containers from other repos are still attached, and those services can't start again until this stack is back up.

### 3. Trust Caddy's local CA

Caddy issues TLS certificates using its built-in local CA. First copy the root cert from the container:

```sh
docker compose cp caddy:/data/caddy/pki/authorities/local/root.crt ./caddy-root.crt
```

**Ubuntu**
```sh
sudo cp caddy-root.crt /usr/local/share/ca-certificates/caddy-root.crt
sudo update-ca-certificates
```

> Firefox manages its own certificate store — import `caddy-root.crt` manually via **Settings → Privacy & Security → View Certificates → Authorities → Import**.

**macOS**
```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain caddy-root.crt
```

**Windows** (run in PowerShell as Administrator)
```powershell
Import-Certificate -FilePath caddy-root.crt -CertStoreLocation Cert:\LocalMachine\Root
```

## Adding a service

A service can live in this repo or in its own repo. Either way, the only requirements are:

1. Join the `crest-web` network
2. Add the three Caddy labels

**In this repo:** create `<service>/compose.yaml` using the template below, but **omit the top-level `networks:` block**: the network is defined in the top-level `compose.yaml`. Then add `- <service>/compose.yaml` to `include:` there.

**In another repo:** use the template as-is (with `external: true`) and run it there. The crest-web stack must be up first.

Minimum template:

```yaml
services:
  my-service:
    image: my-image
    restart: unless-stopped
    networks:
      - crest-web
    labels:
      caddy: my-service.crest.internal
      caddy.reverse_proxy: "{{upstreams <port>}}"
      caddy.tls: internal

networks:
  crest-web:
    external: true
```

To use HTTP only (no TLS, no CA cert required on clients), prefix the domain with `http://` and omit the `caddy.tls` label:

```yaml
labels:
  caddy: http://my-service.crest.internal
  caddy.reverse_proxy: "{{upstreams <port>}}"
```

Caddy picks up the new route automatically when the container starts — no reload needed.

## Registry

A private OCI registry ([CNCF Distribution](https://distribution.github.io/distribution/), `registry:3`) at `https://registry.crest.internal`. Caddy terminates TLS and handles authentication with `basic_auth`. The registry port is not published, and the registry itself runs without auth. Blobs are stored in `REGISTRY_DATA_DIR` (the USB SSD on caterpi).

### Client trust

The Docker daemon, not just your browser, must trust Caddy's root CA. Use either option:

- Install `caddy-root.crt` into the system store (see [step 3](#3-trust-caddys-local-ca)), then **restart dockerd** (`sudo systemctl restart docker`).
- Or install it for this registry only:
  ```sh
  sudo mkdir -p /etc/docker/certs.d/registry.crest.internal
  sudo cp caddy-root.crt /etc/docker/certs.d/registry.crest.internal/ca.crt
  ```

**Podman** uses the system store, or `/etc/containers/certs.d/registry.crest.internal/ca.crt`.

**k3s / containerd** nodes need the CA in `/etc/rancher/k3s/registries.yaml` (or containerd's `hosts.toml`):

```yaml
configs:
  registry.crest.internal:
    tls:
      ca_file: /etc/ssl/certs/caddy-root.crt
    auth:
      username: <user>
      password: <password>
```

### Usage

```sh
docker login registry.crest.internal
docker tag my-image registry.crest.internal/my-image:1.0
docker push registry.crest.internal/my-image:1.0
docker pull registry.crest.internal/my-image:1.0
```

### Cleanup

Deleting tags does not free disk space. To reclaim it:

1. Delete manifests through the registry API, for example with [`regctl`](https://github.com/regclient/regclient):
   ```sh
   regctl registry login registry.crest.internal
   regctl tag rm registry.crest.internal/my-image:old
   ```
2. Run garbage collection, ideally with pushes paused:
   ```sh
   docker compose exec registry registry garbage-collect --delete-untagged /etc/distribution/config.yml
   ```

This is a manual job for now (or a cron job on caterpi).

### Throughput

All pushes and pulls go through the Pi (Caddy and the registry), so large images will be limited by its network and USB SSD speed.
