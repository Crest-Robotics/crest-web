# crest-web

Caddy reverse proxy for `crest.internal`, plus a reference example for onboarding new services.

## Architecture

All `*.crest.internal` DNS resolves to `caterpi.crest.internal` via a dnsmasq wildcard on the router. Caddy (using [caddy-docker-proxy](https://github.com/lucaslorentz/caddy-docker-proxy)) reads Docker container labels to automatically route subdomains to the correct service — no central config file to maintain.

```
*.crest.internal (dnsmasq wildcard → Pi IP)
        ↓
  Caddy (caddy-docker-proxy)   [compose.yaml]
        ↓
  crest-web Docker network
  └── any service on the network, in any repo
```

## Repo structure

```
compose.yaml           # Caddy — run once on the Pi
compose.whoami.yaml    # Reference example for new services
```

## Setup

### 1. Router DNS (GL-MT6000)

Reserve a static IP for `caterpi` by MAC address: **Clients → caterpi → IP Reservation**.

Then add the wildcard DNS entry. In LuCI (**Network → DHCP and DNS → General Settings → Addresses**), add:

```
/.crest.internal/<caterpi-static-ip>
```

Save and apply.

### 2. Start Caddy

```sh
docker compose -f compose.yaml up -d
```

This creates the `crest-web` Docker network and starts Caddy on ports 80/443.

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

Services live in their own repos. Use `compose.whoami.yaml` as a reference — the only requirements are:

1. Join the `crest-web` external network
2. Add the three Caddy labels

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
