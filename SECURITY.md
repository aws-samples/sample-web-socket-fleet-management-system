# Security Policy

This repository contains **sample code for educational purposes**. It
accompanies a blog post and is intended to demonstrate an architecture pattern,
not to be deployed to production as-is. Review this document before using any
part of it in a real environment.

## Reporting a Vulnerability

If you discover a potential security issue in this project, please notify the
maintainers by opening a **private** report rather than a public issue:

- Open a GitHub Security Advisory ("Report a vulnerability" under the
  repository **Security** tab), or
- Contact the repository maintainers directly.

Please do **not** create a public GitHub issue for security-sensitive reports.
We will acknowledge receipt, investigate, and coordinate a fix and disclosure
timeline with you.

## Scope and Intended Use

This project provisions IAM roles, an authenticated API, KMS keys, SSM
SecureString secrets, DynamoDB tables, an SQS queue, and an ECS/Fargate worker
fleet. It is a **reference implementation**. Before any production use, complete
the hardening steps below and run your own security review against your
organization's standards.

## AWS Services Used

- Amazon DynamoDB (connection lease state + streamed message storage)
- Amazon SQS (work distribution)
- AWS Lambda (event router + API authorizer)
- Amazon API Gateway (HTTP API)
- Amazon ECS on AWS Fargate (worker fleet + test WebSocket server)
- Amazon ECR (container images)
- AWS KMS (encryption keys)
- AWS Systems Manager Parameter Store (SecureString secrets)
- Amazon CloudWatch (logs + metrics)
- Amazon S3 (Terraform remote state)

## Security Controls Already in Place

- **Secrets**: API keys stored in SSM Parameter Store SecureString; nothing
  hardcoded. No account IDs or real ARNs committed.
- **Authorizer**: Fails closed — if the API key is not configured, all requests
  are rejected.
- **API authentication**: Enabled by default (`enable_auth = true`). When the
  custom authorizer is disabled the route falls back to `AWS_IAM`, so the
  endpoint is never unauthenticated.
- **Least privilege**: ECS and Lambda roles are scoped to specific tables,
  queues, and KMS keys.
- **Encryption at rest**: DynamoDB (KMS CMK), SQS (SSE), ECR (KMS CMK),
  S3 state bucket (KMS), Terraform lock table (KMS).
- **KMS key rotation**: Enabled on all customer-managed keys.
- **Network**: ECS tasks run in private subnets with egress via a NAT gateway;
  no auto-assigned public IPs.
- **Container hardening**: Read-only root filesystem on task containers.
- **Log retention**: CloudWatch log groups retain logs for 365 days.
- **Message-content logging**: The worker logs metadata only by default;
  logging message content requires explicitly setting `LOG_MESSAGE_CONTENT=true`
  (off in the shipped task definition) to avoid writing user/PII data to logs.
- **State backend**: KMS-encrypted S3 with full public-access block, versioning,
  and server access logging; DynamoDB state locking.
- **License**: MIT-0.

## Accepted Security Trade-offs (Sample-Level)

The following are acceptable for a clearly-labeled sample but **must be
addressed before production**. Track and close these within 90 days if moving
toward production.

| ID | Trade-off | Production guidance | Risk if unaddressed |
|----|-----------|---------------------|---------------------|
| SD-3 | ECR/KMS is a per-stack CMK without an org key policy | Manage CMKs centrally with an organization key policy and grants | Reduced key-governance controls |
| SD-5 | Dockerfiles use public base images (`public.ecr.aws/docker/library/python`) | Pin base images to a specific digest for reproducibility; use an internal registry if deploying internally | Non-reproducible builds; supply-chain drift |
| SD-6 | State-backend KMS key policy grants broad actions to the account root | Scope key actions to the specific deploy-role ARN | Wider blast radius if an account principal is compromised |

> Note: several controls originally flagged as debt during review — private
> subnets + NAT (SD-1), read-only root filesystem (SD-2), CloudWatch retention
> of 365 days (SD-4), KMS key rotation, and message-content logging (SD-7) —
> have already been implemented in this repository and are listed under
> "Controls Already in Place" above.

## Production Hardening Checklist

Before deploying to production:

1. Scope the Terraform state-backend KMS key policy to your deploy-role ARN.
2. Pin container base images to a digest; mirror to a private registry if
   required by your organization.
3. Remove or debug-gate any logging of message content; log metadata only.
4. Review all IAM policies against your least-privilege standards.
5. Add WAF / rate limiting in front of the API to mitigate abuse and cost
   attacks.
6. Run dependency CVE scanning (`pip-audit`) and container image scanning in CI
   and on a schedule.
7. Enable centralized logging, alerting, and audit (CloudTrail) for the account.
8. Perform an independent security review against your production baseline.

## Dependency and Vulnerability Scanning

Run these locally or in CI before publishing or deploying:

```bash
# Python dependency CVEs
pip install pip-audit
pip-audit -r src/worker/requirements.txt
pip-audit -r src/test-ws-server/requirements.txt
pip-audit -r tests/requirements.txt

# Static analysis
pip install bandit checkov
bandit -r src tests -c .bandit.yaml
checkov -d infrastructure --compact
checkov -f remote-state-backend/terraform-backend.yaml --compact
```
