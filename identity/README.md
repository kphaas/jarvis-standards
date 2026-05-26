# Identity Registry

Per-service RS256 public keys for JARVIS service-to-service authentication.

This registry is the canonical list of consuming-side public keys. Services that issue RS256 JWTs hold the corresponding private key on their runtime node — private keys never live in this repo.

See [ADR-0002 — State Native, Compute Containerized](docs/adr/ADR-0002-state-native-compute-containerized.md) for the runtime-node ownership rule, and [ADR-0003 — Progressive Secrets Management](docs/adr/ADR-0003-progressive-secrets-management.md) for the rotation cadence.

## Layout

| Path | Contains | Permissions |
|---|---|---|
| `identity/services/<service>_public.pem` | RSA public key for verifying RS256 JWTs issued by `<service>` | committed, public-readable |

Private keys live on the issuing service's runtime node:

| Service | Runtime node | Private key path |
|---|---|---|
| Council | Brain | `~/jarvis/pki/services/council_private.pem` (chmod 600) |

The single-row table will grow as Stage 2 lands additional service identities; the registry is intentionally sparse in v1.

Sister key sets in `~/jarvis/pki/` on Brain (Alpha-era, pre-this-registry — not consumed via this repo): `jwt/jwt_{private,public}.pem`, `services/{brain,buddy,endpoint,forge,gateway,sandbox}_*.pem`. Those land in the registry on the Alpha-5 Phase 5.0 migration cycle.

## Adding a new service identity

1. On the service's runtime node, generate the keypair (RSA 2048-bit to match the existing Alpha pattern):

    ```bash
    mkdir -p ~/jarvis/pki/services
    /opt/homebrew/bin/openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
      -out ~/jarvis/pki/services/<service>_private.pem
    chmod 600 ~/jarvis/pki/services/<service>_private.pem
    /opt/homebrew/bin/openssl pkey -in ~/jarvis/pki/services/<service>_private.pem -pubout \
      -out /tmp/<service>_public.pem
    chmod 644 /tmp/<service>_public.pem
    ```

2. Verify the pair matches (see "Pair fingerprint compare" below). If MISMATCH: stop, delete generated files, regenerate.

3. SCP the public key off the runtime node to a workstation, copy into `jarvis-standards/identity/services/<service>_public.pem`. Re-run the fingerprint compare on the SCP'd copy to confirm the transfer didn't corrupt the file.

4. Open a PR in jarvis-standards. P-trait — repo owner merges.

5. After merge, consuming services pull the latest standards and load the new public key from `identity/services/<service>_public.pem`.

## Pair fingerprint compare

Use the DER form of the public key as the fingerprint subject — independent of PEM whitespace and identical whether derived from the private or read from the public file:

```bash
priv_fp=$(/opt/homebrew/bin/openssl pkey -in <private>.pem -pubout -outform DER \
            | /opt/homebrew/bin/openssl sha256 | awk '{print $2}')
pub_fp=$(/opt/homebrew/bin/openssl pkey -pubin -in <public>.pem -outform DER \
            | /opt/homebrew/bin/openssl sha256 | awk '{print $2}')
[ "$priv_fp" = "$pub_fp" ] && echo MATCH || echo MISMATCH
```

The DER-then-SHA256 form is preferred over comparing PEM text directly because PEM line wrapping and trailing newlines can differ between OpenSSL versions while the underlying key bytes are identical.

## Verification snippet (Python / PyJWT)

```python
import jwt  # PyJWT
from pathlib import Path

pub = Path("identity/services/council_public.pem").read_text()
decoded = jwt.decode(
    token,
    pub,
    algorithms=["RS256"],
    audience="<expected-aud>",
    issuer="council",
)
```

Consumer code in Council (and Alpha/Forge once their identities migrate to this registry) loads `<service>_public.pem` once at startup, caches the parsed key, and re-loads only on SIGHUP or scheduled rotation.

## Rotation

90-day cadence per ADR-0003 progressive rotation. Procedure:

1. **Generate new keypair** on the runtime node, suffixed by date to keep the old key valid during cutover (e.g. `council_private_20260825.pem` alongside the current file).
2. **Atomically swap** the private key file when the service is ready to start issuing tokens under the new key.
3. **Commit the new public key** to `identity/services/<service>_public.pem` and move the previous file to `identity/services/archive/<service>_public_<rotated-date>.pem`. PR + merge.
4. **Consumers** load both the current key and the most recent archived key during the grace period; verification accepts tokens signed by either. The grace period is the maximum lifetime of a token issued under the old key.
5. **Remove the archived public key** after the grace period — all tokens signed under the old key have expired by then.

Rotation tooling lives under ADR-0003 follow-up F-055 (LaunchAgent-driven rotation with grace period). Until that ships, rotation is manual.

## References

- [ADR-0002 — State Native, Compute Containerized](docs/adr/ADR-0002-state-native-compute-containerized.md)
- [ADR-0003 — Progressive Secrets Management](docs/adr/ADR-0003-progressive-secrets-management.md)
- Council Stage 2 Deliverable B — this registry's seed (`council_public.pem`)
