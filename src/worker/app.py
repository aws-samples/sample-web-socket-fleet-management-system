import asyncio
import json
import os
import signal
import time
from datetime import datetime
from typing import Dict, Optional
import boto3
import websockets
from botocore.exceptions import ClientError

TABLE_NAME = os.environ["TABLE_NAME"]
MESSAGES_TABLE_NAME = os.environ["MESSAGES_TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]
GSI_NAME = os.environ["GSI_NAME"]
LEASE_SECONDS = int(os.environ.get("LEASE_SECONDS", "20"))
HEARTBEAT_EVERY = int(os.environ.get("HEARTBEAT_EVERY", "5"))
MAX_CONNECTIONS = int(os.environ.get("MAX_CONNECTIONS", "800"))
RECONCILE_EVERY = int(os.environ.get("RECONCILE_EVERY", "60"))
RECONCILE_PAGE_SIZE = int(os.environ.get("RECONCILE_PAGE_SIZE", "50"))
SERVICE_NAME = os.environ.get("SERVICE_NAME", "WsFleetService")
# When true, logs a truncated snippet of received message content to stdout.
# Off by default to avoid writing user/PII data to CloudWatch. Enable only for
# local debugging on non-sensitive data.
LOG_MESSAGE_CONTENT = os.environ.get("LOG_MESSAGE_CONTENT", "false").lower() == "true"


ddb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
cw = boto3.client("cloudwatch")
table = ddb.Table(TABLE_NAME)
messages_table = ddb.Table(MESSAGES_TABLE_NAME)

WORKER_ID = f"worker-{os.getpid()}-{int(time.time())}"
shutdown_event = asyncio.Event()
connections: Dict[str, dict] = {}


def now_ms():
    return int(time.time() * 1000)


def signal_handler(signum, frame):
    print(f"Received signal {signum}, initiating graceful shutdown...")
    asyncio.create_task(shutdown_event.set())


async def try_acquire_lease(pk: str) -> Optional[dict]:
    """Attempt to acquire lease on a connection. Returns connection data if successful."""
    try:
        resp = table.update_item(
            Key={"pk": pk},
            UpdateExpression="SET lease_owner = :w, lease_expires_at_ms = :exp, updated_at_ms = :now",
            ConditionExpression="attribute_not_exists(lease_expires_at_ms) OR lease_expires_at_ms < :now",
            ExpressionAttributeValues={
                ":w": WORKER_ID,
                ":exp": now_ms() + LEASE_SECONDS * 1000,
                ":now": now_ms(),
            },
            ReturnValues="ALL_NEW",
        )
        return resp["Attributes"]
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return None
        raise


async def renew_lease(pk: str) -> bool:
    """Renew lease for owned connection."""
    try:
        table.update_item(
            Key={"pk": pk},
            UpdateExpression="SET lease_expires_at_ms = :exp, updated_at_ms = :now",
            ConditionExpression="lease_owner = :w",
            ExpressionAttributeValues={
                ":w": WORKER_ID,
                ":exp": now_ms() + LEASE_SECONDS * 1000,
                ":now": now_ms(),
            },
        )
        return True
    except ClientError:
        return False


async def release_lease(pk: str):
    """Release lease on connection."""
    try:
        table.update_item(
            Key={"pk": pk},
            UpdateExpression="SET lease_owner = :empty, lease_expires_at_ms = :zero",
            ConditionExpression="lease_owner = :w",
            ExpressionAttributeValues={":w": WORKER_ID, ":empty": "", ":zero": 0},
        )
    except ClientError:
        pass


async def manage_websocket(pk: str, ws_url: str, last_seq: int):
    """Manage a single WebSocket connection with heartbeat and message handling."""
    conn_data = {"pk": pk, "ws_url": ws_url, "last_seq": last_seq, "ws": None}
    connections[pk] = conn_data
    connection_id = pk.split("#", 1)[1] if "#" in pk else pk

    try:
        async with websockets.connect(ws_url) as ws:
            conn_data["ws"] = ws
            print(f"[{pk}] Connected to {ws_url}")
            await ws.send(json.dumps({"connection_id": connection_id}))

            async def heartbeat_loop():
                while not shutdown_event.is_set():
                    await asyncio.sleep(HEARTBEAT_EVERY)
                    if not await renew_lease(pk):
                        print(f"[{pk}] Lost lease, closing connection")
                        return

            async def receive_loop():
                async for msg in ws:
                    try:
                        data = json.loads(msg) if isinstance(msg, str) else msg
                        # Support transcript format (speaker+text) and generic formats
                        if data.get("type") == "transcript":
                            message_text = f"[{data.get('speaker', 'Unknown')}] {data.get('text', '')}"
                        else:
                            message_text = data.get("data") or data.get("text") or data.get("message", str(data))
                        timestamp_ms = int(time.time() * 1000)

                        # Log metadata only by default. Message content can
                        # contain user/PII data, so it is only logged when
                        # LOG_MESSAGE_CONTENT is explicitly enabled.
                        if LOG_MESSAGE_CONTENT:
                            print(f"[{pk}] Received: {message_text[:80]}")
                        else:
                            print(f"[{pk}] Received message ({len(message_text)} chars)")
                        messages_table.put_item(
                            Item={
                                "pk": pk,
                                "sk": str(timestamp_ms),
                                "connection_id": connection_id,
                                "message_data": message_text,
                                "raw_event": json.dumps(data),
                                "timestamp_ms": timestamp_ms,
                                "received_at": datetime.utcnow().isoformat() + "Z",
                                "worker_id": WORKER_ID,
                                "ttl": int(time.time()) + (7 * 86400)
                            }
                        )
                    except Exception as e:
                        print(f"[{pk}] Error processing message: {e}")

            async def check_desired_state():
                while not shutdown_event.is_set():
                    await asyncio.sleep(10)
                    resp = table.get_item(Key={"pk": pk})
                    item = resp.get("Item", {})
                    if item.get("desired_state") == "STOPPED":
                        print(f"[{pk}] Desired state is STOPPED, closing")
                        return
                    # Optional extension: INTERRUPT support for reconnection testing.
                    # The blog covers START/STOP and crash recovery as the core pattern.
                    # INTERRUPT is supplementary — it forces a lease release so another
                    # worker re-acquires the connection without stopping it permanently.
                    if item.get("interrupt_requested"):
                        print(f"[{pk}] Interrupt requested, releasing lease for re-acquisition")
                        # Clear the flag so the next worker doesn't see it
                        try:
                            table.update_item(
                                Key={"pk": pk},
                                UpdateExpression="REMOVE interrupt_requested",
                                ConditionExpression="lease_owner = :w",
                                ExpressionAttributeValues={":w": WORKER_ID},
                            )
                        except ClientError:
                            pass
                        return

            await asyncio.gather(heartbeat_loop(), receive_loop(), check_desired_state())

    except Exception as e:
        print(f"[{pk}] WebSocket error: {e}")
    finally:
        await release_lease(pk)
        connections.pop(pk, None)
        print(f"[{pk}] Connection closed")


async def poll_sqs():
    """Poll SQS for connection events."""
    print("[SQS] Starting SQS polling loop...")
    while not shutdown_event.is_set():
        if len(connections) >= MAX_CONNECTIONS:
            print(f"[SQS] At max capacity, waiting...")
            await asyncio.sleep(5)
            continue

        try:
            print(f"[SQS] Polling queue (current connections: {len(connections)})...")
            resp = await asyncio.to_thread(
                sqs.receive_message,
                QueueUrl=QUEUE_URL,
                MaxNumberOfMessages=1,
                WaitTimeSeconds=10,
                VisibilityTimeout=30,
            )

            messages = resp.get("Messages", [])
            print(f"[SQS] Received {len(messages)} messages")

            for msg in messages:
                body = json.loads(msg["Body"])
                pk = body["pk"]

                if pk in connections:
                    sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])
                    continue

                conn_data = await try_acquire_lease(pk)
                if conn_data and conn_data.get("desired_state") == "STARTED":
                    asyncio.create_task(
                        manage_websocket(pk, conn_data["ws_url"], conn_data.get("last_seq", 0))
                    )

                sqs.delete_message(QueueUrl=QUEUE_URL, ReceiptHandle=msg["ReceiptHandle"])

        except Exception as e:
            print(f"SQS polling error: {e}")
            await asyncio.sleep(5)


async def reconcile_orphaned_connections():
    """Periodically scan for connections with expired leases and re-acquire them."""
    print("[RECONCILE] *** RECONCILIATION TASK STARTED ***")
    
    while not shutdown_event.is_set():
        await asyncio.sleep(RECONCILE_EVERY)
        
        print(f"[RECONCILE] Running reconciliation check... (current connections: {len(connections)})")

        if len(connections) >= MAX_CONNECTIONS:
            print(f"[RECONCILE] At max capacity ({MAX_CONNECTIONS}), skipping")
            continue

        try:
            now = now_ms()
            print(f"[RECONCILE] Querying GSI for orphaned connections (now={now})")
            
            resp = table.query(
                IndexName=GSI_NAME,
                KeyConditionExpression="desired_state = :state AND lease_expires_at_ms < :now",
                ExpressionAttributeValues={":state": "STARTED", ":now": now},
                Limit=RECONCILE_PAGE_SIZE,
            )
            
            items = resp.get("Items", [])
            print(f"[RECONCILE] Found {len(items)} orphaned connections")

            for item in items:
                pk = item["pk"]
                print(f"[RECONCILE] Checking {pk} (lease_expires_at_ms={item.get('lease_expires_at_ms')})")
                
                if pk not in connections and len(connections) < MAX_CONNECTIONS:
                    print(f"[RECONCILE] Attempting to acquire {pk}")
                    conn_data = await try_acquire_lease(pk)
                    if conn_data:
                        print(f"[RECONCILE] Successfully acquired {pk}, starting WebSocket")
                        asyncio.create_task(
                            manage_websocket(pk, conn_data["ws_url"], conn_data.get("last_seq", 0))
                        )
                    else:
                        print(f"[RECONCILE] Failed to acquire {pk} (another worker got it)")
                else:
                    print(f"[RECONCILE] Skipping {pk} (already managing or at capacity)")

        except Exception as e:
            print(f"[RECONCILE] Error: {e}")
            import traceback
            traceback.print_exc()


async def publish_metrics():
    """Publish CloudWatch metrics for autoscaling."""
    print("[METRICS] Starting metrics publishing loop...")
    while not shutdown_event.is_set():
        await asyncio.sleep(30)
        try:
            print(f"[METRICS] Publishing ActiveConnections={len(connections)}")
            cw.put_metric_data(
                Namespace="WsFleet",
                MetricData=[
                    {
                        "MetricName": "ActiveConnections",
                        "Value": len(connections),
                        "Unit": "Count",
                        "Dimensions": [{"Name": "ServiceName", "Value": SERVICE_NAME}],
                    }
                ],
            )
        except Exception as e:
            print(f"Metrics error: {e}")


async def graceful_shutdown():
    """Wait for shutdown signal and close all connections gracefully."""
    await shutdown_event.wait()
    print("Shutting down gracefully...")
    tasks = []
    for pk, conn in list(connections.items()):
        if conn.get("ws"):
            tasks.append(conn["ws"].close())
        tasks.append(release_lease(pk))

    await asyncio.gather(*tasks, return_exceptions=True)
    print("Shutdown complete")


async def main():
    signal.signal(signal.SIGTERM, signal_handler)
    signal.signal(signal.SIGINT, signal_handler)

    print(f"Worker {WORKER_ID} starting...")
    print(f"Configuration:")
    print(f"  TABLE_NAME: {TABLE_NAME}")
    print(f"  QUEUE_URL: {QUEUE_URL}")
    print(f"  GSI_NAME: {GSI_NAME}")
    print(f"  RECONCILE_EVERY: {RECONCILE_EVERY}s")
    print(f"  MAX_CONNECTIONS: {MAX_CONNECTIONS}")
    
    print("\nStarting async tasks...")
    print("Test 1: Creating poll_sqs task...")
    task1 = asyncio.create_task(poll_sqs())
    
    print("Test 2: Creating reconcile task...")
    task2 = asyncio.create_task(reconcile_orphaned_connections())
    
    print("Test 3: Creating metrics task...")
    task3 = asyncio.create_task(publish_metrics())
    
    print("Test 4: Creating graceful_shutdown task...")
    task4 = asyncio.create_task(graceful_shutdown())
    
    print("Test 5: All tasks created, now gathering...")
    
    try:
        await asyncio.gather(task1, task2, task3, task4, return_exceptions=False)
    except Exception as e:
        print(f"FATAL ERROR in main: {e}")
        import traceback
        traceback.print_exc()


if __name__ == "__main__":
    asyncio.run(main())
