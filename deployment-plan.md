# Art Bridge: VM Storage Recovery + Lightweight CI/CD

## Context

The VM (Ubuntu 24.04, 20GB) is at capacity because Docker images are built **directly on the VM** on every deploy. This leaves large build-time images permanently cached:
- `gradle:8.10-jdk21` (~1.2GB) — only needed to compile the JAR, not to run it
- `node:20-alpine` with full build cache from multi-stage builds
- Build cache accumulates between deploys (current scripts use `docker image prune -f` which only removes *dangling* images, not named build-time base images)

**Fix:** Build Docker images on GitHub Actions CI runners (free, ephemeral), push to `ghcr.io`, have the VM only pull final lightweight runtime images.

---

## Part 1: Manual Recovery (Run Right Now on the VM)

```bash
# 1. Baseline
df -h /
sudo docker system df

# 2. Remove ALL build cache (safe — no running containers affected)
sudo docker builder prune -af

# 3. Remove all unused images (safe if stack is running — images used by live containers won't be removed)
# Check what's running first:
sudo docker ps --format "table {{.Names}}\t{{.Image}}"
sudo docker image prune -af
# This removes gradle:8.10-jdk21 (~1.2GB), old intermediate layers, previous artbridge-* images

# 4. Remove stopped containers
sudo docker container prune -f

# 5. Clean stray build output directories on the VM (not needed once CI builds images)
rm -rf /home/ubuntu/rp9/art-bridge-backend/build/
rm -rf /home/ubuntu/rp9/art-bridge-client/.next/

# 6. Trim system journal logs
sudo journalctl --vacuum-size=100M

# 7. Git GC on all repos
cd /home/ubuntu/rp9/art-bridge-backend && git gc --aggressive --prune=now
cd /home/ubuntu/rp9/art-bridge-client && git gc --aggressive --prune=now
cd /home/ubuntu/rp9/infra && git gc --aggressive --prune=now

# 8. After
df -h /
sudo docker system df
```

**Estimated recovery: 2–6GB** (biggest wins: builder prune + image prune -af)

---

## Part 2: CI/CD Changes

### Files to change:
1. `art-bridge-backend/.github/workflows/ci.yml`
2. `art-bridge-backend/.github/workflows/deploy.yml`
3. `art-bridge-client/.github/workflows/ci.yml`
4. `art-bridge-client/.github/workflows/deploy.yml`
5. `infra/.github/workflows/deploy.yml`
6. `infra/docker-compose.yml`
7. `art-bridge-client/.dockerignore` (**new file** — critical, fixes a bug where `COPY . .` could overwrite deps-stage node_modules)

---

### Prerequisite: GitHub Package Permissions

In each repo: **Settings → Actions → General → Workflow permissions → Read and write permissions** (allows `GITHUB_TOKEN` to push to ghcr.io).

For the VM to pull without auth: go to `github.com/YOUR_ORG?tab=packages`, find each package, **Package Settings → Change visibility → Public**.

---

### Change 1: `art-bridge-backend/.github/workflows/ci.yml`

Replace the final `docker build` step with a conditional build+push that only fires on `main`:

```yaml
name: Backend CI
on:
  push:
    branches: ["main", "develop"]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "21"
      - uses: gradle/actions/setup-gradle@v4
      - run: ./gradlew clean bootJar

      - name: Log in to GitHub Container Registry
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push backend image
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/artbridge-backend:main
```

---

### Change 2: `art-bridge-backend/.github/workflows/deploy.yml`

Remove `git pull` on the backend repo (source no longer needed on VM), remove `--build`, add `docker compose pull`:

```yaml
      - run: |
          ssh -p "${{ secrets.VM_PORT }}" "${{ secrets.VM_USER }}@${{ secrets.VM_HOST }}" '
            set -e
            cd /home/ubuntu/rp9/infra

            sudo docker compose pull backend
            sudo docker compose up -d --no-deps backend

            sudo docker image prune -af
            sudo docker builder prune -af

            for i in $(seq 1 24); do
              if curl -fsS --max-time 5 http://localhost/api/actuator/health > /dev/null 2>&1; then
                echo "Backend healthy"; break
              fi
              if [ $i -eq 24 ]; then
                echo "Backend unhealthy after 2 minutes"
                sudo docker compose logs --tail=100 backend; exit 1
              fi
              echo "Attempt $i/24 - retrying in 5s..."; sleep 5
            done
            sudo docker compose ps backend
          '
```

(Keep the rest of the file — `on:`, `concurrency:`, `if:`, SSH setup — unchanged.)

---

### Change 3: `art-bridge-client/.github/workflows/ci.yml`

Same pattern as backend:

```yaml
name: Frontend CI
on:
  push:
    branches: ["main", "develop"]
  pull_request:

jobs:
  build:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: "20"
          cache: "npm"
          cache-dependency-path: package-lock.json
      - run: npm ci
      - run: npm run build

      - name: Log in to GitHub Container Registry
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Build and push frontend image
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: ghcr.io/${{ github.repository_owner }}/artbridge-frontend:main
```

---

### Change 4: `art-bridge-client/.github/workflows/deploy.yml`

```yaml
      - run: |
          ssh -p "${{ secrets.VM_PORT }}" "${{ secrets.VM_USER }}@${{ secrets.VM_HOST }}" '
            set -e
            cd /home/ubuntu/rp9/infra

            sudo docker compose pull frontend
            sudo docker compose up -d --remove-orphans frontend

            sudo docker image prune -af
            sudo docker builder prune -af

            curl -fsS http://localhost/ > /dev/null
            sudo docker compose ps
          '
```

---

### Change 5: `infra/.github/workflows/deploy.yml`

Only `infra` repo needs `git pull` (for compose file + nginx config). Remove git pulls for backend and client:

```yaml
      - run: |
          ssh -p "${{ secrets.VM_PORT }}" "${{ secrets.VM_USER }}@${{ secrets.VM_HOST }}" '
            set -e
            cd /home/ubuntu/rp9/infra && git fetch --all && git checkout main && git pull --ff-only

            sudo docker compose pull backend frontend
            sudo docker compose up -d --remove-orphans

            sudo docker image prune -af
            sudo docker builder prune -af

            curl -fsS http://localhost/ > /dev/null
            curl -fsS http://localhost/api/actuator/health > /dev/null
            sudo docker compose ps
          '
```

---

### Change 6: `infra/docker-compose.yml`

Add `image:` fields to `backend` and `frontend`. Keep `build:` as local dev fallback. Pin minio version:

```yaml
  minio:
    image: minio/minio:RELEASE.2025-01-20T14-49-07Z   # was: latest

  backend:
    image: ghcr.io/OWNER/artbridge-backend:main        # replace OWNER with actual GitHub org/user
    build:
      context: ../art-bridge-backend
      dockerfile: Dockerfile
    container_name: artbridge-backend
    # ... rest unchanged

  frontend:
    image: ghcr.io/OWNER/artbridge-frontend:main       # replace OWNER with actual GitHub org/user
    build:
      context: ../art-bridge-client
      dockerfile: Dockerfile
    container_name: artbridge-frontend
    # ... rest unchanged
```

When both `image:` and `build:` are present:
- `docker compose pull` fetches the registry image
- `docker compose up` (no `--build`) uses the pulled image
- `docker compose up --build` builds locally (for dev)

---

### Change 7: `art-bridge-client/.dockerignore` (new file)

```
node_modules/
.next/
.git/
.gitignore
*.md
.env
.env.*
.github/
```

**Why critical:** The frontend Dockerfile does `COPY . .` in the build stage. Without this file, the CI's `node_modules/` gets copied into the Docker build context, overwriting the deps-stage output and potentially causing incorrect dependencies or bloated images.

---

## Migration Sequence (order matters)

1. Create `art-bridge-client/.dockerignore` → merge to main
2. Update `infra/docker-compose.yml` with `image:` fields and pinned minio → merge to main
3. Update backend `ci.yml` → merge to main → **wait for CI to run** → verify `ghcr.io/OWNER/artbridge-backend:main` exists
4. Update frontend `ci.yml` → merge to main → **wait for CI to run** → verify `ghcr.io/OWNER/artbridge-frontend:main` exists
5. Set both ghcr.io packages to **Public** in GitHub Package Settings
6. Run Part 1 manual cleanup on the VM
7. Update all 3 `deploy.yml` files → merge → trigger `workflow_dispatch` test
8. Verify on VM: `sudo docker system df` — build cache should stay near zero on subsequent deploys

**Do not merge the deploy.yml changes (step 7) before the images exist in ghcr.io (steps 3–4).**

---

## Expected Ongoing VM Footprint After Migration

| Image | Size | Notes |
|-------|------|-------|
| `eclipse-temurin:21-jre` | ~250MB | Was: `gradle:8.10-jdk21` at ~1.2GB |
| `node:20-alpine` (runner only) | ~150MB | Was: full build stage cached |
| `postgres:16` | ~400MB | unchanged |
| `minio/minio:RELEASE...` | ~200MB | unchanged |
| `nginx:1.27-alpine` | ~50MB | unchanged |
| Build cache | ~0MB | nothing built on VM |
| **Total** | **~1.05GB** | vs. ~4–6GB+ previously |
