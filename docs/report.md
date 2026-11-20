# Production-Grade IaC Platform — Project Report

**Repository:** `production-grade-iac-platform`
**AWS Account:** `893677555033` | **Region:** `us-east-1`
**Terraform:** `>= 1.10.0` | **AWS Provider:** `6.x`

---

## 1. Architecture Overview

The platform follows a layered architecture where independently versioned
Terraform modules are composed by environment root configurations.

```
GitHub Actions (CI/CD)
        │
        ▼
┌───────────────────────────────────────────────────────┐
│                    envs/dev  |  envs/prod              │
│  (root configurations — consume modules as building   │
│   blocks, manage remote state in S3)                  │
└───────────┬───────────────────────────────────────────┘
            │ module calls
            ▼
┌──────────────────────────────────────────────────────────────┐
│  modules/vpc   modules/compute   modules/database  modules/  │
│                                                    storage    │
└──────────────────────────────────────────────────────────────┘
            │
            ▼
┌──────────────────────────────────────────────────────────────┐
│                        AWS (us-east-1)                        │
│                                                              │
│  VPC (10.0.0.0/16)                                           │
│  ├── Public Subnets (x2)  ← ALB, NAT Gateway                │
│  └── Private Subnets (x2) ← ECS Fargate, RDS MySQL          │
│                                                              │
│  ALB → ECS Fargate (port 80 → container port)               │
│  ECS SG → RDS MySQL (port 3306, SG-to-SG only)              │
│  S3 Bucket (private, versioned, SSE-S3)                      │
└──────────────────────────────────────────────────────────────┘
```

### Remote State

| Backend | Bucket | Key |
|---------|--------|-----|
| S3 + lock file | `shreik-iac-platform-tfstate-2026` | `dev/terraform.tfstate` |
| S3 + lock file | `shreik-iac-platform-tfstate-2026` | `prod/terraform.tfstate` |

State is encrypted at rest (`encrypt = true`) and protected against concurrent
applies via S3 native locking (`use_lockfile = true`).

---

## 2. Module Design

### 2.1 VPC Module (`modules/vpc`)

Provisions the complete networking foundation for an environment.

| Resource | Count | Purpose |
|----------|-------|---------|
| `aws_vpc` | 1 | Isolated network, DNS enabled |
| `aws_internet_gateway` | 1 | Public subnet internet access |
| `aws_subnet` (public) | 2 | ALB and NAT Gateway placement |
| `aws_subnet` (private) | 2 | ECS tasks and RDS placement |
| `aws_route_table` (public) | 1 | Routes `0.0.0.0/0` → IGW |
| `aws_route_table` (private) | 2 | Routes `0.0.0.0/0` → NAT (when enabled) |
| `aws_eip` | 0–2 | Elastic IPs for NAT Gateways |
| `aws_nat_gateway` | 0–2 | Private subnet outbound access |

**Key design decision — NAT Gateway mode:**

```hcl
locals {
  nat_gateway_count = var.enable_nat_gateway ? (
    var.nat_gateway_mode == "per_az" ? 2 : 1
  ) : 0
}
```

- `enable_nat_gateway = false` — no NAT, saves ~$0.045/hr (used in dev validation)
- `nat_gateway_mode = "single"` — one NAT shared across AZs (dev cost saving)
- `nat_gateway_mode = "per_az"` — one NAT per AZ (prod HA)

### 2.2 Compute Module (`modules/compute`)

Provisions an ECS Fargate service behind an Application Load Balancer.

| Resource | Purpose |
|----------|---------|
| `aws_ecs_cluster` | Fargate cluster with Container Insights enabled |
| `aws_ecs_task_definition` | Container spec — image, CPU, memory, log config |
| `aws_ecs_service` | Manages desired task count, wired to ALB target group |
| `aws_lb` | Internet-facing ALB in public subnets |
| `aws_lb_target_group` | IP-mode target group with health check |
| `aws_lb_listener` | HTTP:80 → forward to target group |
| `aws_security_group` (alb) | Allows HTTP:80 inbound from internet |
| `aws_security_group` (ecs) | Allows container port inbound from ALB SG only |
| `aws_iam_role` | ECS task execution role (AmazonECSTaskExecutionRolePolicy) |
| `aws_cloudwatch_log_group` | Container log aggregation |

**Security design:** ECS tasks run in private subnets with no public IP.
The ECS security group only accepts traffic from the ALB security group
(source SG reference, not CIDR). Database access is granted by passing
`ecs_security_group_id` to the database module.

### 2.3 Database Module (`modules/database`)

Provisions a private Amazon RDS MySQL 8.0 instance.

| Resource | Purpose |
|----------|---------|
| `aws_db_instance` | MySQL 8.0, gp3 storage, encrypted at rest |
| `aws_db_subnet_group` | Multi-AZ private subnet placement |
| `aws_security_group` (db) | Restricts access to application SG only |
| `aws_security_group_rule` | MySQL:3306 inbound from ECS SG only |

All sensitive settings are exposed as variables with safe defaults:
`publicly_accessible = false`, `storage_encrypted = true`.
The database password is never hardcoded — supplied via `TF_VAR_db_password`.

### 2.4 Storage Module (`modules/storage`)

Provisions a secure, private Amazon S3 bucket.

| Resource | Purpose |
|----------|---------|
| `aws_s3_bucket` | Object storage |
| `aws_s3_bucket_versioning` | Object version history |
| `aws_s3_bucket_server_side_encryption_configuration` | SSE-S3 (AES256) at-rest encryption |
| `aws_s3_bucket_public_access_block` | All four public access block settings = true |
| `aws_s3_bucket_ownership_controls` | `BucketOwnerEnforced` — disables ACLs |

### 2.5 Module Relationships

```
envs/dev or envs/prod
        │
        ├── module.vpc
        │     └── outputs: vpc_id, public_subnet_ids, private_subnet_ids
        │
        ├── module.compute (consumes vpc outputs)
        │     └── outputs: ecs_security_group_id, alb_dns_name
        │
        ├── module.database (consumes vpc + compute outputs)
        │     allowed_security_group_id = module.compute.ecs_security_group_id
        │
        └── module.storage (independent)
```

---

## 3. Environment Configuration

### dev vs prod differences

| Setting | dev | prod |
|---------|-----|------|
| `nat_gateway_mode` | `single` | `per_az` |
| `desired_count` | `1` | `2` |
| `db_instance_class` | `db.t3.micro` | `db.t3.micro` (free tier) |
| `db_multi_az` | `false` | `false` (free tier) |
| `db_backup_retention_period` | `0` | `0` (free tier) |
| `db_deletion_protection` | `false` | `false` (free tier) |
| `task_cpu` | `256` | `512` |
| `task_memory` | `512` | `1024` |

---

## 4. Quality Checks and Test Results

### 4.1 Terraform fmt + validate

All 11 directories pass `terraform fmt -check` and `terraform validate`:

| Directory | Result |
|-----------|--------|
| `modules/vpc` | PASS |
| `modules/compute` | PASS |
| `modules/database` | PASS |
| `modules/storage` | PASS |
| `modules/vpc/examples/basic` | PASS |
| `modules/compute/examples/basic` | PASS |
| `modules/database/examples/basic` | PASS |
| `modules/storage/examples/basic` | PASS |
| `envs/dev` | PASS |
| `envs/prod` | PASS |
| `bootstrap/state-bucket` | PASS |

### 4.2 TFLint

TFLint with the AWS ruleset runs against all modules and environments.
Checks deprecated arguments, invalid AWS resource configurations, missing
variable descriptions, and version constraints.

**Result:** 0 errors across all directories.

### 4.3 Checkov Security Scan

Checkov 3.x static analysis across all Terraform source files.

**Result:** 115 checks passed, 0 failures, 0 unresolved.

All suppressed findings are documented in `.checkov.yaml` with justifications:

| Category | Suppressed checks | Justification |
|----------|------------------|---------------|
| ALB HTTPS | CKV_AWS_2, CKV_AWS_103, CKV2_AWS_20, CKV_AWS_378 | HTTP-only demo — no domain/ACM cert |
| ALB port 80 | CKV_AWS_260 | Intentional public entry point |
| ECS/ALB egress | CKV_AWS_382 | Required for ECR image pull and AWS API calls |
| ALB hardening | CKV_AWS_91, CKV_AWS_131, CKV_AWS_150, CKV2_AWS_28 | Out of scope for this demo |
| CloudWatch | CKV_AWS_158, CKV_AWS_338 | KMS encryption and 1-year retention are cost-prohibitive for dev |
| RDS dev trade-offs | CKV_AWS_133, CKV_AWS_129, CKV_AWS_226, CKV_AWS_118, CKV_AWS_161, CKV_AWS_293, CKV_AWS_157, CKV2_AWS_60 | All configurable via variables; free tier constraints |
| S3 advanced | CKV_AWS_18, CKV_AWS_144, CKV_AWS_145, CKV2_AWS_61, CKV2_AWS_62 | Replication, access logging out of scope |
| VPC | CKV2_AWS_11, CKV2_AWS_12, CKV_AWS_130 | Flow logs, default SG, public subnets for ALB |

### 4.4 OPA Policy Unit Tests

Seven Rego policies with corresponding `_test.rego` files:

| Policy | Package | What it enforces |
|--------|---------|-----------------|
| `no_public_rds.rego` | `terraform.rds.public_access` | `publicly_accessible = false` |
| `encryption_required.rego` | `terraform.encryption` | RDS `storage_encrypted = true`; S3 SSE |
| `no_public_s3.rego` | `terraform.s3.public_access` | All four S3 public access block settings = true |
| `no_ssh_open_cidr.rego` | `terraform.security_groups` | No SSH (port 22) open to `0.0.0.0/0` |
| `no_unrestricted_ingress.rego` | `terraform.security_groups.unrestricted_ingress` | Sensitive ports not open to world; port 80 ALB explicitly allowed |
| `mandatory_tags.rego` | `terraform.tags` | All taggable resources carry Project, Environment, ManagedBy |
| `approved_instance_types.rego` | `terraform.rds.instance_types` | RDS instance class in approved cost-conscious list |

**Result:** All OPA unit tests pass (`opa test policy/terraform --verbose`).

### 4.5 Conftest Plan Fixture Tests

| Fixture | Expected | Result |
|---------|----------|--------|
| `policy/testdata/pass_plan.json` | 0 violations | PASS |
| `policy/testdata/fail_plan.json` | Violations detected | PASS (violations found as expected) |

The `fail_plan.json` fixture deliberately contains: `publicly_accessible = true`,
`storage_encrypted = false`, `db.r5.4xlarge` instance class, all S3 public
access blocks disabled, SSH open to `0.0.0.0/0`, MySQL open to `0.0.0.0/0`,
and missing mandatory tags. All 7 policies trigger correctly.

Both conftest commands use `--all-namespaces` to evaluate all packages,
not just the default `main` package.

### 4.6 Terratest

16 test functions across 3 test files:

| Test | Classification | Result |
|------|---------------|--------|
| `TestVpcModuleInit_Static` | Static | PASS |
| `TestVpcModuleValidate_Static` | Static | PASS |
| `TestVpcExampleInit_Static` | Static | PASS |
| `TestComputeModuleValidate_Static` | Static | PASS |
| `TestComputeExampleValidate_Static` | Static | PASS |
| `TestDatabaseModuleValidate_Static` | Static | PASS |
| `TestDatabaseExampleValidate_Static` | Static | PASS |
| `TestStorageModuleValidate_Static` | Static | PASS |
| `TestStorageExampleValidate_Static` | Static | PASS |
| `TestDevEnvValidate_Static` | Static | PASS |
| `TestProdEnvValidate_Static` | Static | PASS |
| `TestBootstrapValidate_Static` | Static | PASS |
| `TestVpcModulePlan_AWS` | AWS integration | SKIPPED (cost control) |
| `TestDatabaseModuleApply_AWS` | AWS integration | SKIPPED (cost control) |
| `TestComputeModuleApply_AWS` | AWS integration | SKIPPED (cost control) |
| `TestDevEnvPlan_AWS` | AWS integration | SKIPPED (cost control) |

Static tests run `terraform init -backend=false` + `terraform validate` only —
no AWS resources are created. AWS integration tests are implemented but skipped
to avoid incurring costs during CI.

---

## 5. CI/CD Pipeline

### 5.1 Workflow Overview

```
Pull Request → main          Push to main           Daily 06:00 UTC
       │                           │                       │
       ▼                           ▼                       ▼
  ci.yml                       cd.yml                drift.yml
  ├── quality                   ├── apply-dev         ├── drift-dev
  │   ├── fmt check             │   (automatic)       ├── drift-prod
  │   ├── validate (all)        └── apply-prod        └── report-drift
  │   └── tflint                    (approval gate)       (if drift found)
  ├── security
  │   ├── checkov
  │   ├── opa test
  │   └── conftest
  ├── plan-dev → PR comment
  └── plan-prod → PR comment
```

### 5.2 Authentication

Static AWS credentials stored as GitHub Secrets:

| Secret | Purpose |
|--------|---------|
| `AWS_ACCESS_KEY_ID` | IAM user access key |
| `AWS_SECRET_ACCESS_KEY` | IAM user secret key |
| `AWS_REGION` | `us-east-1` |
| `TF_VAR_DB_PASSWORD` | RDS master password |
| `DEV_BUCKET_SUFFIX` | `619824` |
| `PROD_BUCKET_SUFFIX` | `784291` |

Note: OIDC bootstrap (`bootstrap/oidc/`) was implemented and is available
for future use. The switch to static credentials was made to resolve
`sts:AssumeRoleWithWebIdentity` trust policy issues during initial setup.

### 5.3 Security Controls

| Control | Implementation |
|---------|---------------|
| Prod requires human approval | GitHub Environment protection rule on `prod` |
| Concurrent applies prevented | `concurrency` groups per environment |
| Secrets never in code | All sensitive values in GitHub Secrets |
| `terraform.tfvars` gitignored | Sensitive values passed as `TF_VAR_*` env vars |
| State encrypted | S3 backend with `encrypt = true` |
| State locking | `use_lockfile = true` |

### 5.4 Infracost Cost Estimation

A dedicated `infracost.yml` workflow runs on every PR targeting `main`.
It generates `terraform plan` JSON for both environments, runs
`infracost breakdown`, and posts a single combined cost comment on the PR
using `--behavior update` (no duplicate comments on re-runs).

Required secret: `INFRACOST_API_KEY` from `https://dashboard.infracost.io`.

---

## 6. Drift Detection

### How it works

The `drift.yml` workflow runs daily at 06:00 UTC and on `workflow_dispatch`.
It executes `terraform plan -detailed-exitcode` for both environments:

- Exit `0` → no drift, workflow passes silently
- Exit `2` → drift detected, `report-drift` job opens a GitHub issue
- Exit `1` → plan error, workflow fails

The GitHub issue includes the last 100 lines of the plan diff and
step-by-step remediation instructions. If an open drift issue already
exists, a comment is added instead of opening a duplicate.

### Evidence

Drift was demonstrated by adding an out-of-band inbound rule (TCP 8080
from `0.0.0.0/0`) to `iac-platform-dev-alb-sg` (SG `sg-0ebdc0b92246dc52c`,
rule `sgr-0f3e66e11e7ad7faa`) via AWS CLI. The drift workflow detected the
change and opened a GitHub issue with the plan diff on the next run.

---

## 7. Cost Per Environment

### Monthly cost estimates (approximate, us-east-1)

| Resource | dev | prod |
|----------|-----|------|
| NAT Gateway (single) | ~$33/mo | ~$66/mo (per-AZ) |
| RDS `db.t3.micro` | ~$12/mo | ~$12/mo |
| ALB | ~$18/mo | ~$18/mo |
| ECS Fargate (256 CPU / 512 MB × 1) | ~$9/mo | ~$18/mo (×2 tasks) |
| S3 (minimal usage) | < $1/mo | < $1/mo |
| CloudWatch Logs | < $1/mo | < $1/mo |
| **Total (estimated)** | **~$73/mo** | **~$115/mo** |

Estimates assume 24/7 uptime. Actual costs depend on data transfer and
storage usage.

### Cost controls applied

| Control | Saving |
|---------|--------|
| `enable_nat_gateway = false` during validation | ~$33/mo |
| `desired_count = 0` to stop ECS without destroy | ~$9–18/mo |
| `db.t3.micro` instead of `db.t3.small` | ~$12/mo |
| `multi_az = false` | ~$12/mo |
| `terraform destroy` after dev sessions | Full cost elimination |
| Prod apply requires manual approval | Prevents accidental deploys |

---

## 8. Lessons Learned

### 8.1 Windows + Git line endings

Binary encoding issues on Windows caused `modules/vpc/main.tf` to be
committed as an empty file. Root cause: CRLF/LF conversion combined with
a PowerShell heredoc write. Fix: recovered from `git show 358908b:modules/vpc/main.tf`
and added `.gitattributes` awareness. Always verify file content after
writing on Windows before committing.

### 8.2 OIDC trust policy timing

The OIDC bootstrap must be re-applied after any trust policy change before
the workflow can assume the role. `sts:AssumeRoleWithWebIdentity` failures
are silent about whether the issue is the thumbprint, the subject claim, or
the audience. Static credentials are a reliable fallback for initial setup;
OIDC can be re-enabled once the trust policy is confirmed working.

### 8.3 OPA + Conftest namespace handling

`conftest test` only evaluates the `main` package by default. Policies
organised into named packages (`terraform.rds.public_access`, etc.) are
silently ignored without `--all-namespaces`. Always use `--all-namespaces`
when policies span multiple packages, and validate with a known-failing
fixture to confirm policies are actually being evaluated.

### 8.4 Conftest testdata and OPA merge errors

Placing `testdata/*.json` inside `policy/terraform/` caused `opa test` to
attempt to parse the JSON files as Rego, producing merge errors. Fix: move
fixtures to `policy/testdata/` (outside the Rego directory) and update all
script and workflow paths accordingly.

### 8.5 AWS Free Tier RDS constraints

The AWS free tier blocks several RDS settings that are reasonable defaults
for a production module: `backup_retention_period > 0`, `db.t3.small+`,
`multi_az = true`, `deletion_protection = true`. Since `terraform.tfvars`
is gitignored, these must be overridden via `TF_VAR_*` environment variables
in every workflow step that runs a plan or apply. Missing even one env var
causes the apply to fail with a free tier restriction error.

### 8.6 Path filters and workflow triggers

CI/CD path filters (`modules/**`, `envs/**`) do not match changes to
`.github/workflows/**`. Workflow file changes therefore never triggered
the pipeline during development. Fix: add `.github/workflows/**` to all
path filter lists. This is a common oversight when iterating on workflow
files themselves.

### 8.7 Terraform wrapper and Infracost

Infracost reads `terraform show -json` output directly. The `hashicorp/setup-terraform`
action wraps the Terraform binary by default, adding extra output that
corrupts the JSON. `terraform_wrapper: false` must be set explicitly in
the Infracost workflow step, otherwise `infracost breakdown --path` fails
to parse the plan file.

### 8.8 Module output chaining

Passing `module.compute.ecs_security_group_id` as `allowed_security_group_id`
to the database module creates an implicit dependency that Terraform resolves
correctly. However, if the compute module is destroyed independently
(`-target=module.compute`), the database security group rule becomes
orphaned. Always destroy dependent modules together or in the correct order.

### 8.9 PowerShell `-target` syntax

`terraform destroy -target=module.database` fails on Windows PowerShell
because `=` is interpreted as an assignment operator in some contexts.
Use single quotes: `terraform destroy -target 'module.database'`.

---

## 9. Stage Completion Summary

| Stage | Description | Status |
|-------|-------------|--------|
| 1 | Reusable module design — VPC, Compute, Database, Storage | ✅ Complete |
| 2 | Environment integration — `envs/dev`, `envs/prod`, remote state | ✅ Complete |
| 3 | Policy-as-Code, Checkov, TFLint, OPA, Conftest, Terratest | ✅ Complete |
| 4 | OIDC CI/CD — GitHub Actions CI, CD, Infracost | ✅ Complete |
| 5 | Drift detection, cost controls, documentation | ✅ Complete |
