# Persodict Infrastructure

Terraform-managed AWS infrastructure for the Persodict NestJS backend.

**Repos:**
- `persodict-infra` (this repo) — AWS infra via Terraform
- `Persodict-BE` — NestJS app + Dockerfile + GitHub Actions
- `persodict-gitops` — Helm chart + ArgoCD Applications

---

## Status

| Phase | Layer | Status |
|---|---|---|
| 0 | Prerequisites | ✅ |
| 1 | Terraform state backend (S3 + DynamoDB) | ✅ |
| 2 | Terraform code | ✅ |
| 3 | VPC | ✅ |
| 4 | EKS + node group | ✅ |
| 5 | Cluster add-ons (metrics-server, LBC, ESO, ArgoCD) | ✅ |
| 6 | Application layer (Helm chart, ArgoCD Application) | ✅ testing only |
| 7 | CI/CD (GitHub Actions → ECR → GitOps → ArgoCD) | ✅ |
| 8 | Staging + prod Applications | ⬜ next |
| 9 | Domain + TLS | ⬜ |
| 10 | Monitoring | ⬜ |

App is live and reachable via ALB (HTTP, testing namespace).


## Architecture
AWS Account (us-east-1)
│
├── VPC 10.0.0.0/16 (vpc-0675e0fd31ba00068)
│ ├── Public subnets 10.0.1.0/24, 10.0.2.0/24 → ALB, NAT
│ ├── Private subnets 10.0.11.0/24, 10.0.12.0/24 → EKS worker nodes
│ ├── Internet Gateway
│ ├── NAT Gateway (single)
│ └── Route tables
│
├── EKS persodict-eks (Kubernetes v1.33)
│ ├── Control plane (AWS-managed, NOT inside VPC)
│ ├── OIDC provider (for IRSA)
│ ├── Node group persodict-ng (2× c7i-flex.large in private subnets)
│ └── Namespaces: testing, (staging, prod pending)
│
├── ECR persodict-api
│ └── Immutable tags, scan on push, lifecycle: keep 10 tagged / expire untagged 7d
│
├── Secrets Manager
│ └── persodict/{testing,staging,prod} — JSON: DATABASE_URL, DEEPL_AUTH_KEY, JWT_SECRET
│
└── IAM
├── IRSA roles: ALB controller, External Secrets
└── CI user: github-actions-ecr-push (ECR push only)
---

**Mental model:** EKS control plane lives in AWS-managed infra, associated with the VPC via ENIs. Worker nodes (EC2) live in private subnets. Pods run on those nodes.

---

## Files

| File | Purpose |
|---|---|
| `backend.tf` | S3 + DynamoDB state backend |
| `providers.tf` | aws, tls, http providers; region; default tags |
| `vpc.tf` | VPC, subnets, IGW, NAT, routes |
| `eks.tf` | EKS cluster, OIDC provider, node group |
| `irsa.tf` | IAM roles for ALB controller + External Secrets |
| `ecr.tf` | ECR repo + lifecycle policy |
| `secrets.tf` | Secrets Manager shells per env |
| `ci.tf` | IAM user for GitHub Actions (ECR push) |

---

## Terraform Workflow

```bash
terraform init       # download providers, connect to backend
terraform validate
terraform plan
terraform apply
---

## Phase 0 — Prerequisites ✅

- AWS account created.
- IAM **user** `zenlogie` created with programmatic access keys.
  - Attached `AdministratorAccess` (learning phase only — to be tightened later).
- AWS CLI installed and configured locally.
- Region: **`us-east-1`**.
  - Note: AWS CLI default region must also be `us-east-1`. A mismatch here causes `aws` commands to query the wrong region while Terraform applies to another — silent empty results.
- `kubectl`, `helm`, `terraform`, `docker`, `argocd` CLI installed locally.

---

## Phase 1 — Terraform State Backend ✅

Terraform needs durable, shared, locked storage for its state file. The state file contains resource attributes and potentially secrets — it must **never** live in Git.

- **S3 bucket**: `zenlogie-terraform-state-persodict`
  - Versioning enabled (state rollback).
  - Default encryption (SSE-S3).
  - Public access blocked.
- **DynamoDB table**: `terraform-locks`
  - Partition key: `LockID` (string).
  - On-demand capacity.
  - Purpose: prevent concurrent `terraform apply` runs from corrupting state.

---

## Phase 2 — Terraform Code (`.tf` files) ✅

Declarative infrastructure code. Terraform reads these files, computes a plan, and calls AWS APIs to reconcile reality with the declared state. The files themselves do nothing until `apply` runs.

| File | Purpose |
|---|---|
| `backend.tf` | Points Terraform at S3 + DynamoDB for state. |
| `providers.tf` | Declares required providers (`aws`, `tls`) and default region/tags. |
| `vpc.tf` | Network layer: VPC, subnets, gateways, routes. |
| `eks.tf` | Kubernetes layer: EKS cluster, OIDC, node group. |

Terraform workflow:
- `terraform init` — downloads providers, connects to backend, caches locally in `.terraform/`.
- `terraform validate` — syntax check.
- `terraform plan` — computes diff (what would change).
- `terraform apply` — executes the diff against AWS.

---

## Phase 3 — VPC (Network Layer) ✅

16 resources applied.

### What was built

### Key concepts

- **VPC**: isolated network inside AWS, owns an IP range (CIDR block).
- **Subnet**: slice of the VPC's IP range, pinned to one Availability Zone.
  - **Public**: direct internet in/out. Hosts ALB.
  - **Private**: no inbound internet. Outbound via NAT. Hosts nodes/pods.
- **Internet Gateway**: door between public subnets and the internet.
- **NAT Gateway**: lets private subnets reach the internet **outbound only**
  (needed for ECR pulls, MongoDB Atlas, DeepL API calls). Costs ~$32/mo.
- **Route tables**: rules for where traffic goes per subnet.
- **Subnet tags** (`kubernetes.io/role/elb`, `kubernetes.io/cluster/persodict-eks`)
  are read by the AWS Load Balancer Controller and EKS — not cosmetic.

---

## Phase 4 — EKS (Kubernetes Layer) ✅

9 resources applied.

### What was built

- **EKS control plane** (`persodict-eks`) — managed by AWS.
- **OIDC provider** — enables IRSA (pods assuming IAM roles).
- **Node group** (`persodict-ng`) — 2× `t3.medium` EC2 workers in private subnets.
- **IAM roles** — for the control plane and for worker nodes.
- **IAM policy attachments** — AWS-managed policies for EKS cluster and nodes.

### Mental model — what lives where

**Important**: the EKS **control plane is not "inside" your VPC**. AWS runs it in
managed infrastructure and associates it with your VPC via ENIs placed in your
subnets. Your worker nodes — the EC2 instances running pods — do live in your
private subnets.

### Verify

Expected: 2 nodes, `STATUS = Ready`.

---

## Phase 5 — Cluster Add-ons ✅

Helm-installed components that make the cluster usable:

- **metrics-server** — feeds HPA (horizontal pod autoscaler).
- **AWS Load Balancer Controller** — creates ALBs from Ingress resources.
- **External Secrets Operator** — pulls secrets from AWS Secrets Manager into K8s.
- **ArgoCD** — GitOps engine that syncs Git → cluster.

Each needs a matching IRSA role (created in Terraform) to assume AWS permissions.

---

## Phase 6 — Application Layer ✅

- **Helm chart** for the NestJS app (in `persodict-gitops` repo).
- **Per-env values**: `testing.yaml`, `staging.yaml`, `prod.yaml`.
- **ArgoCD Applications** — one per namespace (`testing`, `staging`, `prod`).
- **Secrets Manager** — Mongo URI + DeepL key per env, synced via External Secrets.

---

## Phase 7 — CI/CD ✅

- **App repo** (`Persodict-BE`): GitHub Actions → lint, test, build image, push to ECR.
- **CI bumps image tag** in `persodict-gitops` repo → ArgoCD syncs.
- **Promotion model**:
  - `main` → testing (auto).
  - Git tag `v*` → staging (auto via ArgoCD manual-sync approval).
  - Manual PR to GitOps repo → prod (manual approval).

---

## Key Decisions Log

| Decision | Choice | Why |
|---|---|---|
| Cloud | AWS | Chosen for this project. |
| Region | `us-east-1` | Consistent, cheapest. (Originally discussed Europe — revisit if EU data residency matters.) |
| Cluster topology | 1 EKS cluster, 3 namespaces | Simpler, cheaper. Isolation via namespaces, not clusters. |
| NAT Gateway | 1 (not per-AZ) | Cost (~$65/mo saved). Trade-off: single-AZ resilience. |
| Node type | `t3.medium` × 2 | Minimum to run add-ons + app without OOM. |
| IaC | Terraform | Declarative, standard, portable. |
| GitOps | ArgoCD | Git as source of truth; CI never touches the cluster. |
| CI | GitHub Actions | App already on GitHub. |
| Promotion | main → testing, tag → staging, PR → prod | Balance of speed and safety. |

---

## Repos

| Repo | Purpose |
|---|---|
| `Persodict-BE` | NestJS application code + Dockerfile + CI workflow. |
| `persodict-infra` | This repo. Terraform for AWS infra. |
| `persodict-gitops` | Helm chart, per-env values, ArgoCD Applications. (Not created yet.) |

---

## Do-Not-Do List

- **Never commit** `terraform.tfstate`, `*.tfvars` with secrets, `.terraform/`.
- **Never bake env-specific config** into the Docker image.
- **Never let CI hold AWS credentials** for cluster access. CI can push images and
  write to the GitOps repo — nothing else.
- **Never manually `kubectl apply`** after ArgoCD is in place. Git is truth.
- **Never leave `endpoint_public_access = true`** in production without a CIDR allowlist.