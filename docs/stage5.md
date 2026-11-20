# Stage 5 — Drift Detection and Cost Controls

## Overview

Stage 5 adds automated drift detection via a scheduled GitHub Actions workflow
and documents cost control practices for this project.

---

## 1. Drift Detection Workflow

**File:** `.github/workflows/drift.yml`

### How it works

```
06:00 UTC daily (or manual trigger)
         │
         ▼
┌─────────────────┐     ┌──────────────────┐
│   drift-dev     │     │   drift-prod     │
│                 │     │                  │
│ terraform plan  │     │ terraform plan   │
│ -detailed-      │     │ -detailed-       │
│  exitcode       │     │  exitcode        │
│                 │     │                  │
│ exit 0 → clean  │     │ exit 0 → clean   │
│ exit 2 → drift  │     │ exit 2 → drift   │
└────────┬────────┘     └────────┬─────────┘
         │                       │
         └──────────┬────────────┘
                    ▼
           drift detected?
                    │
              yes   │   no
                    ▼
          ┌──────────────────┐
          │  report-drift    │
          │                  │
          │ Open GitHub issue│
          │ with plan diff   │
          │ + remediation    │
          │ instructions     │
          └──────────────────┘
```

### Trigger

| Trigger | When |
|---------|------|
| `schedule` | Daily at 06:00 UTC |
| `workflow_dispatch` | Manual — used for testing and evidence |

### Exit code semantics

| Exit code | Meaning | Action |
|-----------|---------|--------|
| `0` | No changes — infrastructure matches state | Nothing |
| `2` | Changes detected — drift found | Open/update GitHub issue |
| `1` | Plan error | Workflow fails |

### Issue behaviour

- If no open drift issue exists → creates a new one with labels `drift` and `infrastructure`
- If an open drift issue already exists → adds a comment (avoids duplicate issues)
- Issue body includes the last 100 lines of the plan diff and remediation steps
- Plan output is uploaded as a workflow artifact (retained 7 days)

---

## 2. Drift Detection Evidence

### Step 1 — Baseline (no drift)

Trigger the workflow manually via **Actions → Drift Detection → Run workflow**.

Expected result: both `drift-dev` and `drift-prod` complete with exit code `0`.
The `report-drift` job is skipped. No issue is opened.

### Step 2 — Introduce manual drift

Make an out-of-band change in the AWS Console to simulate drift:

**Example change used for evidence:**
1. Go to AWS Console → EC2 → Security Groups
2. Find `iac-platform-dev-alb-sg`
3. Add an inbound rule: TCP port 8080 from `0.0.0.0/0`
4. Save the rule

This change is not in Terraform state — it will be detected as drift.

### Step 3 — Drift detected

Trigger the workflow manually again.

Expected result:
- `drift-dev` exits with code `2`
- `report-drift` runs and opens a GitHub issue titled:
  `[Drift] Infrastructure drift detected in: dev`
- Issue body contains the plan diff showing the unexpected security group rule

### Step 4 — Remediation

Two remediation paths:

**Option A — Revert the manual change (unintentional drift):**
1. Go to AWS Console → EC2 → Security Groups → `iac-platform-dev-alb-sg`
2. Delete the manually added port 8080 rule
3. Re-run the drift workflow — exit code `0`, no new issue

**Option B — Reconcile via Terraform (intentional change):**
1. Update `modules/compute/main.tf` to add the rule in code
2. Open a PR → CI runs plan → merge → CD applies
3. Re-run the drift workflow — exit code `0`, no new issue

---

## 3. Cost Controls

### Primary cost drivers

| Resource | Approx. cost | Control |
|----------|-------------|---------|
| NAT Gateway | ~$0.045/hr + data | `enable_nat_gateway = false` during dev |
| RDS `db.t3.micro` | ~$0.017/hr | `terraform destroy -target=module.database` when not needed |
| ALB | ~$0.008/hr | Included in compute module, destroy when idle |
| ECS Fargate | Per vCPU/memory/sec | `desired_count = 0` stops tasks without destroying infra |

### Cost control practices applied in this project

| Practice | Implementation |
|----------|---------------|
| Free tier RDS | `db.t3.micro`, `backup_retention_period = 0`, no Multi-AZ |
| Single NAT Gateway in dev | `nat_gateway_mode = "single"` (vs `per_az` in prod) |
| Stop tasks without destroy | `desired_count = 0` in tfvars |
| Destroy after sessions | `terraform destroy` locally after development |
| No accidental applies | CD requires PR merge; prod requires manual approval |
| State locking | S3 backend with `use_lockfile = true` prevents concurrent applies |

---

## 4. Files in Stage 5

| File | Purpose |
|------|---------|
| `.github/workflows/drift.yml` | Scheduled drift detection workflow |
| `docs/stage5.md` | This document |
