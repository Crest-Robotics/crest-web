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
caddy/pki/make-csr.sh         # Generates the intermediate CA key + CSR (run on caterpi)
caddy/pki/intermediate.cnf    # OpenSSL config: CSR settings + extensions for signing
registry/compose.yaml         # Private OCI registry
.env.example                  # Required variables — copy to .env (gitignored)
```

> **Don't change the project name or the `caddy-data` volume key.** The volume `crest-web_caddy-data` holds Caddy's issued certificates and ACME state. Losing it isn't fatal, because certificates are re-issued from the intermediate in `CADDY_PKI_DIR`, but there's no reason to recreate it.

## Setup

### 1. Router DNS (GL-MT6000)

Reserve a static IP for `caterpi` by MAC address: **Clients → caterpi → IP Reservation**.

Then add the wildcard DNS entry. In LuCI (**Network → DHCP and DNS → General Settings → Addresses**), add:

```
/.crest.internal/<caterpi-static-ip>
```

Save and apply.

### 2. TLS certificates (company CA)

Caddy issues a certificate for every `caddy.tls: internal` site from its own intermediate CA, signed by the Crest Robotics root CA. Clients only need to trust the company root. The intermediate is name-constrained: it can issue only for `crest.internal` and its subdomains, never for other domains or IP addresses.

The files live on caterpi in `CADDY_PKI_DIR` (default `/etc/crest-pki`), outside the repo. They're mounted read-only into Caddy at `/pki`:

| File | What | Secret? |
|---|---|---|
| `root.crt` | Crest Robotics root CA certificate | no |
| `caddy-intermediate.key` | Intermediate private key (generated on caterpi, never leaves it) | **yes**, `600` |
| `caddy-intermediate.csr` | Signing request sent to the company CA | no |
| `caddy-intermediate.crt` | Signed intermediate certificate | no |

**1. Generate the key and CSR on caterpi:**

```sh
sudo caddy/pki/make-csr.sh                  # writes to /etc/crest-pki; refuses to overwrite a key
```

**2. Sign the CSR with the company CA.** The certificate must carry the extensions in the `[v3_intermediate]` section of `caddy/pki/intermediate.cnf`:

- `basicConstraints = critical, CA:TRUE, pathlen:0`
- `keyUsage = critical, keyCertSign, cRLSign`
- `nameConstraints = critical, permitted;DNS:crest.internal, excluded;IP:0.0.0.0/0.0.0.0, excluded;IP:::/::`

With plain OpenSSL, on the machine holding the company CA key:

```sh
openssl x509 -req -in caddy-intermediate.csr \
  -CA crest-root.crt -CAkey crest-root.key -CAcreateserial \
  -days 730 -sha256 \
  -extfile caddy/pki/intermediate.cnf -extensions v3_intermediate \
  -out caddy-intermediate.crt
```

If the company CA signs from an issuing intermediate rather than the root, make `caddy-intermediate.crt` the full chain: the Caddy intermediate first, then the issuing intermediate. The issuing CA's own `pathlen` must allow one more level.

**3. Install the results on caterpi and check them:**

```sh
sudo cp crest-root.crt /etc/crest-pki/root.crt
sudo cp caddy-intermediate.crt /etc/crest-pki/caddy-intermediate.crt
openssl verify -CAfile /etc/crest-pki/root.crt /etc/crest-pki/caddy-intermediate.crt
openssl x509 -in /etc/crest-pki/caddy-intermediate.crt -noout -enddate -ext nameConstraints
```

> **Caddy never renews a supplied intermediate, and doesn't warn before it expires.** Once it expires, every site's certificate fails to verify. Put the `notAfter` date in the calendar and rotate a month or more ahead. To rotate: move the old key aside, re-run `make-csr.sh`, get the CSR signed, install it, and restart Caddy (`docker compose restart caddy`). Clients need no changes, because the root stays the same.

### 3. Start the stack

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

### 4. Trust the Crest Robotics root CA

Every client needs the company root certificate (`crest-root.crt`, the same file as `root.crt` above) in its trust store. Machines that already trust the company CA need nothing more.

**Ubuntu**
```sh
sudo cp crest-root.crt /usr/local/share/ca-certificates/crest-root.crt
sudo update-ca-certificates
```

> Firefox manages its own certificate store — import `crest-root.crt` manually via **Settings → Privacy & Security → View Certificates → Authorities → Import**.

**macOS**
```sh
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain crest-root.crt
```

**Windows** (run in PowerShell as Administrator)
```powershell
Import-Certificate -FilePath crest-root.crt -CertStoreLocation Cert:\LocalMachine\Root
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

The Docker daemon, not just your browser, must trust the company root CA. Use either option:

- Install `crest-root.crt` into the system store (see [step 4](#4-trust-the-crest-robotics-root-ca)), then **restart dockerd** (`sudo systemctl restart docker`).
- Or install it for this registry only:
  ```sh
  sudo mkdir -p /etc/docker/certs.d/registry.crest.internal
  sudo cp crest-root.crt /etc/docker/certs.d/registry.crest.internal/ca.crt
  ```

**Podman** uses the system store, or `/etc/containers/certs.d/registry.crest.internal/ca.crt`.

**k3s / containerd** nodes need the CA in `/etc/rancher/k3s/registries.yaml` (or containerd's `hosts.toml`):

```yaml
configs:
  registry.crest.internal:
    tls:
      ca_file: /etc/ssl/certs/crest-root.crt
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
