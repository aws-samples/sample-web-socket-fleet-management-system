# WebSocket Fleet Management System

> **Disclaimer:** This is sample code for educational purposes. It is not
> production-ready and must be hardened before production use. See
> [SECURITY.md](SECURITY.md) for the list of accepted security trade-offs and
> the required production hardening steps.

Companion repository for the blog post: **"Building Resilient Real-Time Streaming Workers on AWS with ECS Fargate and DynamoDB Leases"**

This system manages hundreds of concurrent outbound WebSocket connections using lease-based coordination, automatic failover, and horizontal auto-scaling.

## Architecture

```mermaid
flowchart LR
    Client[External System] -->|REST API| APIGW[API Gateway]
    APIGW --> Auth[Authorizer Lambda]
    APIGW --> Router[Event Router Lambda]
    Router --> DDB[(DynamoDB\nConnections Table)]
    Router --> SQS[[SQS Queue]]
    SQS --> Worker1[ECS Worker 1]
    SQS --> Worker2[ECS Worker 2]
    SQS --> WorkerN[ECS Worker N]
    Worker1 --> DDB
    Worker2 --> DDB
    WorkerN --> DDB
    Worker1 -->|WebSocket| Upstream1[Upstream Source]
    Worker2 -->|WebSocket| Upstream2[Upstream Source]
    WorkerN -->|WebSocket| UpstreamN[Upstream Source]
    Worker1 --> CW[CloudWatch Metrics]
    Worker2 --> CW
    WorkerN --> CW
    CW --> ASG[ECS Auto Scaling]
    ASG --> Worker1
    ASG --> Worker2
    ASG --> WorkerN
```

## How It Works

1. An external system sends a START event via the REST API with a `ws_url`
2. The Event Router Lambda writes the connection record to DynamoDB and queues an SQS message
3. An ECS worker picks up the message, acquires a DynamoDB lease, and opens a WebSocket connection to the upstream source
4. The worker streams incoming messages to a DynamoDB messages table
5. On INTERRUPT, the worker releases its lease and another worker re-acquires the connection
6. On STOP, the worker closes the connection permanently

## Lease Lifecycle

Each WebSocket connection is owned by exactly one worker via a DynamoDB lease. Conditional writes guarantee atomic ownership transitions.

```mermaid
stateDiagram-v2
    [*] --> Unclaimed: Event Router creates record
    Unclaimed --> Acquired: Worker conditional write succeeds
    Acquired --> Renewed: Heartbeat every 5s
    Renewed --> Renewed: Heartbeat continues
    Renewed --> Released: Graceful shutdown (SIGTERM) or INTERRUPT
    Renewed --> Expired: Worker crash / network partition
    Released --> Unclaimed: lease_expires_at_ms = 0
    Expired --> Acquired: Reconciliation re-acquires
    Unclaimed --> Acquired: SQS notification or reconciliation
```

## Lease Acquisition Race Condition

DynamoDB conditional writes ensure exactly one worker wins when multiple workers race for the same connection.

```mermaid
sequenceDiagram
    participant A as Worker A
    participant DDB as DynamoDB
    participant B as Worker B

    A->>DDB: update_item(pk, ConditionExpression: lease expired)
    B->>DDB: update_item(pk, ConditionExpression: lease expired)
    DDB-->>A: 200 OK (lease acquired)
    DDB-->>B: ConditionalCheckFailedException
    A->>A: Start WebSocket connection
    B->>B: Skip, move to next item
```

## Failure Recovery

When a worker crashes, its leases expire after 20 seconds. The reconciliation loop on surviving workers detects and re-acquires orphaned connections.

```mermaid
sequenceDiagram
    participant WA as Worker A
    participant DDB as DynamoDB
    participant WB as Worker B
    participant US as Upstream Source

    WA->>US: WebSocket connected
    Note over WA: T=0: Worker A crashes
    WA--xUS: Connection dropped

    Note over DDB: T=20s: Lease expires

    Note over WB: T=60s: Reconciliation runs
    WB->>DDB: Query GSI (desired_state=STARTED, lease expired)
    DDB-->>WB: Returns orphaned connection
    WB->>DDB: try_acquire_lease (conditional write)
    DDB-->>WB: 200 OK
    WB->>US: New WebSocket connection
    Note over WB,US: Streaming resumes
```

## Auto-Scaling

Workers publish a custom CloudWatch metric (`ActiveConnections`). A target tracking policy scales the ECS service to maintain ~700 connections per task.

```mermaid
flowchart LR
    W1[Worker 1\n750 conns] -->|put_metric_data| CW[CloudWatch\nActiveConnections]
    W2[Worker 2\n720 conns] -->|put_metric_data| CW
    CW -->|Avg > 700| Policy[Target Tracking Policy]
    Policy -->|Scale out| ECS[ECS Service]
    ECS --> W3[Worker 3\nnew task]
```

## Project Structure

```
.
├── infrastructure/              # Terraform IaC
│   ├── main.tf                  # Root module wiring
│   ├── modules/
│   │   ├── resources/
│   │   │   ├── dynamodb/        # DynamoDB table + GSI
│   │   │   ├── sqs/             # SQS work queue
│   │   │   └── lambda/          # Lambda function packaging
│   │   └── workflows/
│   │       ├── api-gateway/     # HTTP API + authorizer
│   │       ├── ecs-worker/      # Fargate service + auto-scaling
│   │       └── test-ws-server/  # Test transcript WebSocket server
│   ├── variables.tf
│   ├── outputs.tf
│   └── providers.tf
├── src/
│   ├── lambda/
│   │   ├── event_router/        # START/STOP/INTERRUPT handler
│   │   └── authorizer/          # API key validation
│   ├── worker/
│   │   ├── app.py               # Worker: SQS poll, lease, WebSocket, reconcile
│   │   ├── Dockerfile
│   │   └── requirements.txt
│   └── test-ws-server/
│       ├── app.py               # Transcript streaming WebSocket server
│       ├── Dockerfile
│       └── requirements.txt
├── tests/
│   ├── test_flow.py             # End-to-end test script (START/INTERRUPT/STOP)
│   └── websocket_server.py      # Local dev WebSocket server
├── docs/
│   └── DEPLOYMENT.md            # Step-by-step deployment guide
└── deploy.sh                    # Deployment wrapper script
```

## Key Configuration

| Parameter | Value | Rationale |
|-----------|-------|-----------|
| Lease duration | 20s | Fast failover while surviving brief network hiccups |
| Heartbeat interval | 5s | 4x safety margin before lease expiry |
| Reconciliation interval | 60s | Balance recovery speed vs. DynamoDB read cost |
| Max connections/task | 800 | Based on memory/CPU profiling per connection |
| Scale-out cooldown | 2 min | Prevent thrashing during traffic spikes |
| Scale-in cooldown | 15 min | Allow connections to stabilize |

## Getting Started

### Prerequisites

- AWS CLI configured with credentials
- Terraform >= 1.4.0
- Python 3.11+
- Docker

### Deploy

See [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) for the full step-by-step guide.

```bash
# Set required environment variables
export AWS_DEFAULT_REGION=us-east-1
export TF_BACKEND_BUCKET=<your-terraform-state-bucket>
export TF_BACKEND_DYNAMODB_TABLE=<your-terraform-lock-table>

# Plan and apply
./deploy.sh --action plan
./deploy.sh --action apply
```

### Run the end-to-end test

```bash
export API_URL=<your-api-gateway-url>
export API_KEY=<your-api-key>
python tests/test_flow.py
```

### Send a manual test event

```bash
curl -X POST ${API_URL}/events \
  -H "Content-Type: application/json" \
  -H "x-api-key: ${API_KEY}" \
  -d '{
    "event_type": "START",
    "connection_id": "meeting-123",
    "ws_url": "ws://test-ws-server.ws-fleet-dev.local:8765"
  }'
```

### Local development

```bash
# Start the local WebSocket server (transcript mode)
python tests/websocket_server.py

# Or manual mode (send messages via HTTP API)
python tests/websocket_server.py --mode manual
```

## Security

- API keys are stored in AWS SSM Parameter Store (SecureString) and injected
  as environment variables at deploy time. Keys are never committed to the repo.
- The authorizer Lambda fails closed: if the API_KEY env var is missing,
  all requests are rejected.
- Terraform state is encrypted with KMS in S3 with DynamoDB locking.
- ECS tasks use least-privilege IAM roles scoped to specific DynamoDB tables
  and SQS queues.

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for reporting security issues.

## Reporting Issues

Please file a GitHub issue for any bugs or feature requests. All issues will be
prioritized based on resource availability. Pull requests for fixes are welcome.

## Contributions

We welcome community contributions! See [CONTRIBUTING](CONTRIBUTING.md) for
guidelines.

## License

This library is licensed under the MIT-0 License. See the [LICENSE](LICENSE) file.

## Authors

- Siddhesh Tiwari — Data Scientist, AWS Professional Services
- Ajay Raghunathan
- Dustin Whitney
- Chetan Padhiyar - Delivery Consultant, AWS Professional Services
