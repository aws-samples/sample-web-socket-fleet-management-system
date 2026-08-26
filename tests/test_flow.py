#!/usr/bin/env python3
"""
End-to-end test script that exercises the full flow via the public API Gateway.

1. START  → Worker connects to WS server → streams transcript
2. INTERRUPT → Worker releases lease → another worker re-acquires → resumes
3. STOP  → Worker closes connection permanently

Run from anywhere (laptop, CI) — only needs access to the public API Gateway URL.
Verify results in DynamoDB messages table and CloudWatch logs.

Usage:
    export API_URL=https://xxx.execute-api.us-east-1.amazonaws.com
    export API_KEY=<YOUR_API_KEY>
    python tests/test_flow.py
"""
import json
import os
import sys
import time

import requests

API_URL = os.environ.get("API_URL", "").rstrip("/")
API_KEY = os.environ.get("API_KEY", "")
WS_SERVER = os.environ.get("WS_SERVER", "ws://test-ws-server.ws-fleet-dev.local:8765")
CONNECTION_ID = os.environ.get("CONNECTION_ID", "test-meeting-001")


def send_event(event_type: str, connection_id: str, ws_url: str = None):
    """Send a START/STOP/INTERRUPT event to the Event Router via API Gateway."""
    payload = {
        "event_type": event_type,
        "connection_id": connection_id,
    }
    if ws_url:
        payload["ws_url"] = ws_url

    headers = {"Content-Type": "application/json", "x-api-key": API_KEY}
    url = f"{API_URL}/events"

    print(f"\n{'='*60}")
    print(f"  {event_type} → {connection_id}")
    print(f"{'='*60}")

    try:
        resp = requests.post(url, json=payload, headers=headers, timeout=30)
        print(f"  Status: {resp.status_code}")
        print(f"  Body:   {resp.text}")
        return resp
    except requests.exceptions.RequestException as e:
        print(f"  ✗ Network error: {e}")
        sys.exit(1)


def wait(seconds: int, reason: str):
    """Wait with a message."""
    print(f"\n  ⏳ Waiting {seconds}s — {reason}")
    time.sleep(seconds)


def main():
    if not API_URL:
        print("ERROR: Set API_URL environment variable")
        sys.exit(1)
    if not API_KEY:
        print("ERROR: Set API_KEY environment variable")
        sys.exit(1)

    print("\n" + "=" * 60)
    print("  WebSocket Fleet — End-to-End Test")
    print("=" * 60)
    print(f"  API:           {API_URL}")
    print(f"  WS Server:     {WS_SERVER}")
    print(f"  Connection ID: {CONNECTION_ID}")
    print("=" * 60)

    # Step 1: START
    print("\n\n▶ STEP 1: START streaming")
    resp = send_event("START", CONNECTION_ID, ws_url=WS_SERVER)
    if resp.status_code != 200:
        print("  ✗ Failed to start. Exiting.")
        sys.exit(1)
    print("  ✓ START accepted")

    wait(20, "Worker picks up SQS message, acquires lease, connects to WS server")
    wait(30, "Letting transcript stream for 30 seconds...")

    # Step 2: INTERRUPT
    print("\n\n▶ STEP 2: INTERRUPT (release lease, another worker resumes)")
    resp = send_event("INTERRUPT", CONNECTION_ID)
    if resp.status_code != 200:
        print("  ✗ Failed to interrupt.")
    else:
        print("  ✓ INTERRUPT accepted")

    wait(15, "Worker sees interrupt, releases lease")
    wait(70, "Reconciliation picks up orphaned connection (up to 60s)")
    wait(20, "Resumed streaming for 20 seconds...")

    # Step 3: STOP
    print("\n\n▶ STEP 3: STOP (permanent close)")
    resp = send_event("STOP", CONNECTION_ID)
    if resp.status_code != 200:
        print("  ✗ Failed to stop.")
    else:
        print("  ✓ STOP accepted")

    wait(15, "Worker sees STOPPED, closes connection")

    # Done
    print("\n\n" + "=" * 60)
    print("  ✓ TEST COMPLETE")
    print("=" * 60)
    print("  Verify results:")
    print("    • DynamoDB messages table — transcript rows for this connection")
    print("    • CloudWatch /ecs/ws-fleet-dev-worker — lease acquire/release logs")
    print("    • CloudWatch /ecs/ws-fleet-dev-test-ws-server — connect/disconnect logs")
    print()


if __name__ == "__main__":
    main()
