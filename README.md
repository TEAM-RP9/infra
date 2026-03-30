**Art Bridge Deployment – Infrastructure Setup Summary**

Project goal: deploy the full-stack **Art Bridge photo gallery application** to a small Ubuntu VM using Docker, and verify that the infrastructure stack (frontend, backend, database, object storage, and reverse proxy) is operational so application development can continue.

---

# 1. Server Environment

Infrastructure was deployed on a virtual machine with the following characteristics:

| Component         | Configuration                     |
| ----------------- | --------------------------------- |
| OS                | Ubuntu 24.04 LTS                  |
| Disk              | ~20 GB (tight storage constraint) |
| Deployment method | Docker Compose                    |
| Access            | SSH with key authentication       |
| Reverse proxy     | Nginx                             |

The limited disk size required optimization of Docker images and build processes.

---

# 2. Repository Structure on the VM

The application was deployed into:

```
/home/ubuntu/rp9/
│
├── art-bridge-backend/     (Spring Boot backend)
├── art-bridge-client/      (Next.js frontend)
└── infra/                  (deployment configuration)
     ├── docker-compose.yml
     ├── nginx.conf
     └── .env
```

The `infra` directory manages the full infrastructure stack through Docker Compose.

---

# 3. Docker Architecture

The application stack consists of five primary services.

| Service    | Purpose                              |
| ---------- | ------------------------------------ |
| postgres   | relational database for metadata     |
| minio      | object storage for images            |
| minio-init | initializes storage bucket           |
| backend    | Spring Boot API                      |
| frontend   | Next.js web application              |
| nginx      | reverse proxy and public entry point |

All containers run on a shared Docker network:

```
artbridge-net
```

Only **Nginx exposes a public port**.

---

# 4. Reverse Proxy Routing

Nginx routes requests to internal services.

| Route     | Target                |
| --------- | --------------------- |
| `/`       | frontend (Next.js)    |
| `/api/`   | backend (Spring Boot) |
| `/media/` | MinIO object storage  |

Example URL flow:

```
Browser → Nginx → Backend → Postgres / MinIO
```

Example image URL returned by the backend:

```
http://<vm-ip>/media/photos/original/<image-id>.jpg
```

---

# 5. Storage Architecture

Two storage systems were configured.

### PostgreSQL

Stores:

* image metadata
* application relational data

Connection details:

```
DB: artbridge
User: ab_admin
Host: postgres (inside Docker)
Port: 5432
```

### MinIO

Stores:

* image binary files

Bucket created:

```
photos
```

MinIO initialization container automatically:

1. connects to MinIO
2. creates the bucket
3. sets public download access

Log confirmation:

```
Bucket created successfully `local/photos`
Access permission set to `download`
```

---

# 6. Disk Space Optimization

The VM originally experienced disk exhaustion due to Docker layers.

Investigation showed heavy usage under:

```
/var/lib/containerd/
```

Cleanup was performed with Docker pruning.

To prevent further issues:

### Backend Dockerfile optimization

Implemented **multi-stage build**:

```
build stage → Gradle
runtime stage → JRE only
```

This removes the full JDK from the runtime image.

### Frontend Dockerfile optimization

Next.js was configured with:

```
output: 'standalone'
```

Final container includes only:

* standalone server
* static assets
* required node modules

This significantly reduces image size.

---

# 7. Backend Build Fix

The backend build initially failed due to a **Java toolchain mismatch**.

Gradle required:

```
Java 21
```

The Docker build environment was updated to match the required version.

After correction, the backend image successfully built.

---

# 8. Container Startup Verification

After building images, the stack was started using:

```
sudo docker compose up -d
```

Container status was verified:

```
sudo docker compose ps
```

All major services were running.

---

# 9. Service Connectivity Testing

A series of infrastructure tests were executed.

## Frontend → Nginx

Test:

```
curl http://localhost/
```

Result:

```
200 OK
```

Frontend rendered correctly in the browser.

---

## Backend → Nginx

Test:

```
curl http://localhost/api/
```

Response:

```
404 Not Found
```

This is expected because the root API endpoint does not exist.

The response confirmed:

```
Nginx → backend routing works
```

---

## Backend Startup Logs

Logs confirmed successful startup:

```
Tomcat started on port 8080
Started ArtBridgeBackendApplication
```

Important subsystems confirmed operational:

### PostgreSQL connection

```
HikariPool - Added connection
Database: jdbc:postgresql://postgres:5432/artbridge
```

### Flyway initialization

```
Schema history table created
No migrations found
```

### Hibernate initialization

```
EntityManagerFactory initialized
```

---

# 10. Object Storage Connectivity

Internal connectivity test from another container:

```
wget http://minio:9000
```

Response:

```
403 Forbidden
```

This confirms:

```
Docker network → MinIO reachable
```

---

## Public media route test

```
curl http://localhost/media/photos/
```

Result:

```
200 OK
```

This verified the full chain:

```
Browser
   ↓
Nginx
   ↓
MinIO
   ↓
photos bucket
```

---

# 11. Database Connectivity

Database availability was verified.

VM test:

```
psql -h localhost -U ab_admin -d artbridge
```

Connection succeeded.

---

# 12. Remote Database Access Setup

Attempted connection through **DBeaver** initially failed due to incorrect host configuration.

DBeaver SSH tunneling succeeded, but the database connection timed out.

The issue was that the database host was set incorrectly.

Correct configuration:

| Setting  | Value     |
| -------- | --------- |
| Host     | localhost |
| Port     | 5432      |
| Database | artbridge |

Reason:

When SSH tunneling is enabled, the database connection must target **localhost through the tunnel**, not the VM IP or Docker hostname.

After correction, DBeaver connected successfully.

---

# 13. Infrastructure Status

At the end of the setup process the entire stack was verified as operational.

| Component                      | Status    |
| ------------------------------ | --------- |
| Nginx                          | working   |
| Frontend                       | working   |
| Backend container              | running   |
| Backend → Postgres             | connected |
| Backend → MinIO                | reachable |
| Media routing                  | working   |
| Postgres access via SSH tunnel | working   |

The environment is now suitable for **frontend and backend feature development**.

---

# 14. Remaining Observation

Backend logs indicated that **Flyway migrations exist in the application but no migration files are present**.

```
No migrations found
```

This means the database schema is currently empty or created manually.

This prompted the discussion about **Flyway database migrations**, which manage schema creation through versioned SQL files.
