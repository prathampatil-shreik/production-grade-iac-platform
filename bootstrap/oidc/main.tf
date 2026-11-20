terraform {
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
  }

  backend "s3" {
    bucket       = "shreik-iac-platform-tfstate-2026"
    key          = "bootstrap/oidc/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "iac-platform"
      ManagedBy = "Terraform"
      Purpose   = "github-actions-oidc"
    }
  }
}

data "aws_caller_identity" "current" {}

# ── GitHub Actions OIDC Provider ─────────────────────────────────────────────

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "github-actions-oidc"
  }
}

# ── IAM Role — GitHub Actions CI (plan only) ─────────────────────────────────
# Assumed by the CI workflow on pull requests.
#
# Sub claim shapes GitHub sends for CI jobs:
#   pull_request event : repo:<org>/<repo>:pull_request
#   job inside env     : repo:<org>/<repo>:environment:<env-name>
#
# The CI plan-dev and plan-prod jobs run inside the "dev" and "prod"
# environments, so we must allow both sub claim forms.

data "aws_iam_policy_document" "github_ci_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Allow pull_request events AND environment-scoped jobs (plan-dev, plan-prod)
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:pull_request",
        "repo:${var.github_org}/${var.github_repo}:environment:dev",
        "repo:${var.github_org}/${var.github_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name                 = "github-actions-ci-${var.github_repo}"
  assume_role_policy   = data.aws_iam_policy_document.github_ci_assume_role.json
  max_session_duration = 3600

  tags = {
    Name    = "github-actions-ci-${var.github_repo}"
    Purpose = "ci-plan-only"
  }
}

resource "aws_iam_role_policy_attachment" "github_ci_readonly" {
  role       = aws_iam_role.github_ci.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

data "aws_iam_policy_document" "github_ci_state" {
  statement {
    sid    = "StateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "github_ci_state" {
  name   = "state-access"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_state.json
}

# ── IAM Role — GitHub Actions CD (apply) ─────────────────────────────────────
# Assumed by the CD workflow on push to main.
#
# IMPORTANT: When a job specifies `environment: dev` or `environment: prod`,
# GitHub replaces the ref-based sub claim with an environment-scoped one:
#   repo:<org>/<repo>:environment:dev
#   repo:<org>/<repo>:environment:prod
#
# The trust policy MUST list these environment sub claims, not the ref claim.
# Using StringLike with a wildcard covers both environments in one condition.

data "aws_iam_policy_document" "github_cd_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Allow jobs running inside the dev and prod GitHub Environments.
    # The ref claim is overridden by the environment claim when environment: is set.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:environment:dev",
        "repo:${var.github_org}/${var.github_repo}:environment:prod",
      ]
    }
  }
}

resource "aws_iam_role" "github_cd" {
  name                 = "github-actions-cd-${var.github_repo}"
  assume_role_policy   = data.aws_iam_policy_document.github_cd_assume_role.json
  max_session_duration = 3600

  tags = {
    Name    = "github-actions-cd-${var.github_repo}"
    Purpose = "cd-apply"
  }
}

resource "aws_iam_role_policy_attachment" "github_cd_power_user" {
  role       = aws_iam_role.github_cd.name
  policy_arn = "arn:aws:iam::aws:policy/PowerUserAccess"
}

data "aws_iam_policy_document" "github_cd_iam" {
  statement {
    sid    = "IamRoleManagement"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:DeleteRole",
      "iam:AttachRolePolicy",
      "iam:DetachRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:PassRole",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:UpdateAssumeRolePolicy",
    ]
    resources = [
      "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/iac-platform-*",
    ]
  }

  statement {
    sid    = "StateAccess"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
    ]
    resources = [
      "arn:aws:s3:::${var.state_bucket_name}",
      "arn:aws:s3:::${var.state_bucket_name}/*",
    ]
  }
}

resource "aws_iam_role_policy" "github_cd_iam" {
  name   = "iam-and-state-access"
  role   = aws_iam_role.github_cd.id
  policy = data.aws_iam_policy_document.github_cd_iam.json
}
