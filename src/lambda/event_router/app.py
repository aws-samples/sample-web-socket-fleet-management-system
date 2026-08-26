import json
import os
import time
import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
QUEUE_URL = os.environ["QUEUE_URL"]

ddb = boto3.resource("dynamodb")
sqs = boto3.client("sqs")
table = ddb.Table(TABLE_NAME)

def now_ms() -> int:
    return int(time.time() * 1000)

def handler(event, context):
    body = event.get("body", "{}")
    payload = json.loads(body) if isinstance(body, str) else body

    event_type = payload["event_type"].upper()
    connection_id = payload["connection_id"]
    ws_url = payload.get("ws_url")

    pk = f"CONN#{connection_id}"

    if event_type == "START":
        if not ws_url:
            return {"statusCode": 400, "body": "ws_url required for START"}

        table.put_item(Item={
            "pk": pk,
            "desired_state": "STARTED",
            "ws_url": ws_url,
            "last_seq": 0,
            "lease_owner": "",
            "lease_expires_at_ms": 0,
            "updated_at_ms": now_ms(),
        })

        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"pk": pk}))

    elif event_type == "STOP":
        table.update_item(
            Key={"pk": pk},
            UpdateExpression="SET desired_state = :s, updated_at_ms = :t",
            ExpressionAttributeValues={":s": "STOPPED", ":t": now_ms()},
        )
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"pk": pk}))

    elif event_type == "INTERRUPT":
        # optional flag; worker reconnect logic can read this if you want
        table.update_item(
            Key={"pk": pk},
            UpdateExpression="SET interrupt_requested = :b, updated_at_ms = :t",
            ExpressionAttributeValues={":b": True, ":t": now_ms()},
        )
        sqs.send_message(QueueUrl=QUEUE_URL, MessageBody=json.dumps({"pk": pk}))

    else:
        return {"statusCode": 400, "body": f"unknown event_type {event_type}"}

    return {"statusCode": 200, "body": "OK"}
