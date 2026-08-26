# Deployment Guide

## Prerequisites

- AWS CLI configured with credentials
- Terraform >= 1.4.0
- Docker
- Python 3.11+

## Step 1: Deploy Terraform Remote State Backend

Creates the S3 bucket and DynamoDB lock table for Terraform state.

```bash
aws cloudformation deploy \
  --template-file remote-state-backend/terraform-backend.yaml \
  --stack-name websocket-poc-devops-terraform-backend \
  --capabilities CAPABILITY_IAM \
  --region us-east-1
```

Verify the stack outputs:

```bash
aws cloudformation describe-stacks \
  --stack-name websocket-poc-devops-terraform-backend \
  --query "Stacks[0].Outputs" \
  --region us-east-1
```

## Step 2: Create SSM Configuration Parameter

Create a JSON file with your configuration. Generate a strong API key
(do NOT commit it to the repository):

```bash
# Generate a random API key
API_KEY=$(openssl rand -hex 24)
echo "Your API key: $API_KEY"
```

Create the config JSON:

```json
{
  "app": "ws-fleet",
  "environment": "dev",
  "service_name_dimension": "WsFleetService",
  "enable_api_auth": true,
  "api_key": "<YOUR_GENERATED_API_KEY>",
  "ecs_desired_count": 2,
  "ecs_min_capacity": 1,
  "ecs_max_capacity": 20,
  "worker_cpu": 1024,
  "worker_memory": 2048,
  "vpc_cidr": "10.20.0.0/16",
  "public_subnet_cidrs": ["10.20.1.0/24", "10.20.2.0/24"]
}
```

Upload to SSM Parameter Store (use SecureString for encryption at rest):

```bash
aws ssm put-parameter \
  --name "/ws-fleet/dev/config" \
  --type SecureString \
  --value '<paste JSON above with your generated key>' \
  --region us-east-1
```

To update an existing parameter:

```bash
aws ssm put-parameter \
  --name "/ws-fleet/dev/config" \
  --type SecureString \
  --value '<paste updated JSON>' \
  --region us-east-1 \
  --overwrite
```

## Step 3: Set Environment Variables

```bash
export AWS_DEFAULT_REGION=us-east-1
export TF_BACKEND_BUCKET=<S3_BUCKET_FROM_STEP_1>
export TF_BACKEND_DYNAMODB_TABLE=<DYNAMODB_TABLE_FROM_STEP_1>
```

## Step 4: Deploy Infrastructure with Terraform

```bash
./deploy.sh --action plan
./deploy.sh --action apply
```

Or manually:

```bash
cd infrastructure

terraform init \
  -backend-config="bucket=${TF_BACKEND_BUCKET}" \
  -backend-config="dynamodb_table=${TF_BACKEND_DYNAMODB_TABLE}" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true"

terraform plan
terraform apply
```

## Step 5: Run End-to-End Test

```bash
# Get the API Gateway URL
API_URL=$(terraform -chdir=infrastructure output -raw api_gateway_url)

# Set your API key (the one you generated in Step 2)
export API_URL
export API_KEY=<YOUR_API_KEY>

python tests/test_flow.py
```

The test script sends START → INTERRUPT → STOP events and validates the
full lifecycle. Check DynamoDB messages table and CloudWatch logs for results.

## Step 6: Send Manual Test Events

```bash
# Start a connection
curl -X POST ${API_URL}/events \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{
    "event_type": "START",
    "connection_id": "meeting-123",
    "ws_url": "ws://test-ws-server.ws-fleet-dev.local:8765"
  }'

# Interrupt (worker releases, another picks up)
curl -X POST ${API_URL}/events \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{"event_type": "INTERRUPT", "connection_id": "meeting-123"}'

# Stop permanently
curl -X POST ${API_URL}/events \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{"event_type": "STOP", "connection_id": "meeting-123"}'
```

## Teardown

```bash
cd infrastructure
terraform destroy

aws ssm delete-parameter --name "/ws-fleet/dev/config" --region us-east-1

aws cloudformation delete-stack \
  --stack-name websocket-poc-devops-terraform-backend \
  --region us-east-1
```

## Security Notes

- API keys are stored in SSM Parameter Store (SecureString) and injected
  via environment variables at deploy time. Never commit keys to the repo.
- The authorizer Lambda will reject all requests if the API_KEY env var
  is not set (fail-closed).
- Use `terraform output -raw api_gateway_url` to retrieve the endpoint
  rather than hardcoding URLs.
