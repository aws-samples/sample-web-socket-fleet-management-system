#!/usr/bin/env python3
"""
WebSocket test server that simulates a live meeting transcript stream.

Modes:
  --mode transcript  (default) Auto-streams a simulated meeting transcript
  --mode manual      Waits for you to send messages via the HTTP control API

In both modes the HTTP control API is available for sending manual messages,
broadcasting, checking status, and stopping individual streams.

Usage:
    python tests/websocket_server.py
    python tests/websocket_server.py --mode manual
    python tests/websocket_server.py --port 8765 --http-port 8766

Then tell the fleet to connect:
    curl -X POST <api-url>/events \
      -H "x-api-key: <key>" \
      -d '{"event_type": "START", "connection_id": "meeting-123", "ws_url": "ws://localhost:8765"}'
"""
import argparse
import asyncio
import json
import random
import time
from datetime import datetime, timedelta

import websockets
from aiohttp import web

# ---------------------------------------------------------------------------
# Simulated transcript data
# ---------------------------------------------------------------------------

SPEAKERS = ["Sarah Chen", "Mike Johnson", "Priya Patel", "David Kim", "Lisa Wang"]

TRANSCRIPT_SEGMENTS = [
    ("Sarah Chen", "Good morning everyone. Let's get started with the standup. Mike, do you want to kick us off?"),
    ("Mike Johnson", "Sure. Yesterday I finished the API integration for the payment service. Today I'm working on the retry logic for failed transactions."),
    ("Sarah Chen", "Any blockers?"),
    ("Mike Johnson", "Yeah, actually. I need access to the staging payment gateway credentials. Can someone from DevOps help with that?"),
    ("Priya Patel", "I can help with that after this meeting. I'll send you the vault path."),
    ("Mike Johnson", "Perfect, thanks Priya."),
    ("Sarah Chen", "Great. Priya, you're next."),
    ("Priya Patel", "Yesterday I deployed the new monitoring dashboards to production. Today I'm investigating the memory leak we saw in the worker pods."),
    ("David Kim", "Is that the one causing the OOM kills around 3 AM?"),
    ("Priya Patel", "Exactly. I've got heap dumps from last night. Looks like it might be the connection pool not releasing properly."),
    ("Sarah Chen", "That's high priority. Do you need help?"),
    ("Priya Patel", "I think I'm okay for now. If I can't figure it out by noon I'll pull David in."),
    ("David Kim", "Sounds good. I'm available after eleven."),
    ("Sarah Chen", "David, your turn."),
    ("David Kim", "I'm wrapping up the database migration script. The schema changes for the new reporting tables are ready. I'll run it against staging today."),
    ("Lisa Wang", "Will that require any downtime?"),
    ("David Kim", "No, it's all additive. New tables and indexes only. No breaking changes to existing queries."),
    ("Lisa Wang", "Good. The analytics team has been asking about the new fields."),
    ("Sarah Chen", "Lisa, what about you?"),
    ("Lisa Wang", "I'm finishing the user story mapping for the Q3 features. I have a draft ready for review. I'll share it in the team channel after this."),
    ("Sarah Chen", "Can you walk us through the highlights in tomorrow's planning session?"),
    ("Lisa Wang", "Absolutely. I'll prepare a five-minute overview."),
    ("Sarah Chen", "Perfect. Anything else before we wrap up?"),
    ("Mike Johnson", "Quick one — the load test results from Friday look good. We're handling three thousand requests per second with p99 under two hundred milliseconds."),
    ("Priya Patel", "Nice. That's a big improvement from last month."),
    ("Sarah Chen", "Great work everyone. Let's sync again tomorrow. Have a good day."),
    ("David Kim", "Thanks, bye everyone."),
    ("Lisa Wang", "Bye!"),
]

FILLER_TOPICS = [
    ("Let me share my screen. Can everyone see the diagram?", "architecture review"),
    ("I think we should consider using a message queue here instead of direct API calls.", "design discussion"),
    ("The customer reported this issue again yesterday. We need to prioritize the fix.", "bug triage"),
    ("I've updated the documentation. Can someone review the PR?", "documentation"),
    ("The sprint velocity looks good this week. We're on track for the release.", "sprint update"),
    ("Has anyone looked into the new version of the framework? There are some breaking changes.", "tech debt"),
    ("I'll set up a separate meeting to discuss the security audit findings.", "security"),
    ("The CI pipeline is taking forty minutes now. We should look at parallelizing the tests.", "devops"),
]

# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------

connected_clients: dict = {}
server_stats = {"total_connections": 0, "messages_sent": 0}
SERVER_MODE = "transcript"  # set by CLI args
# Local test server bind host. Defaults to all interfaces so the fleet running
# in containers/other hosts can reach it. Override with --host for local-only.
BIND_HOST = "0.0.0.0"  # nosec B104

# ---------------------------------------------------------------------------
# Transcript streaming logic
# ---------------------------------------------------------------------------


async def stream_transcript(websocket, connection_id: str):
    """Stream a simulated meeting transcript to a connected client."""
    seq = 0
    meeting_start = datetime.utcnow()

    # Send meeting start event
    seq += 1
    start_event = {
        "type": "meeting_start",
        "seq": seq,
        "meeting_id": f"MTG-{random.randint(1000, 9999)}",
        "title": "Daily Standup - Engineering Team",
        "participants": SPEAKERS,
        "started_at": meeting_start.isoformat() + "Z",
    }
    await websocket.send(json.dumps(start_event))
    server_stats["messages_sent"] += 1

    # Stream transcript segments with realistic pacing
    elapsed = timedelta(seconds=0)

    for speaker, text in TRANSCRIPT_SEGMENTS:
        delay = random.uniform(1.0, 2.5)
        await asyncio.sleep(delay)

        elapsed += timedelta(seconds=random.uniform(3, 12))
        timestamp = meeting_start + elapsed

        seq += 1
        message = {
            "type": "transcript",
            "seq": seq,
            "speaker": speaker,
            "text": text,
            "timestamp": timestamp.isoformat() + "Z",
            "confidence": round(random.uniform(0.92, 0.99), 2),
            "is_final": True,
        }

        try:
            await websocket.send(json.dumps(message))
            server_stats["messages_sent"] += 1
            print(f"  [{connection_id}] seq={seq} {speaker}: {text[:50]}...")
        except websockets.exceptions.ConnectionClosed:
            return

    # After main transcript, loop with filler content indefinitely
    print(f"  [{connection_id}] Main transcript done, continuing with generated content...")
    while True:
        delay = random.uniform(2.0, 4.0)
        await asyncio.sleep(delay)

        speaker = random.choice(SPEAKERS)
        filler_text, topic = random.choice(FILLER_TOPICS)
        elapsed += timedelta(seconds=random.uniform(5, 15))
        timestamp = meeting_start + elapsed

        seq += 1
        message = {
            "type": "transcript",
            "seq": seq,
            "speaker": speaker,
            "text": f"[{topic}] {filler_text}",
            "timestamp": timestamp.isoformat() + "Z",
            "confidence": round(random.uniform(0.88, 0.99), 2),
            "is_final": True,
        }

        try:
            await websocket.send(json.dumps(message))
            server_stats["messages_sent"] += 1
        except websockets.exceptions.ConnectionClosed:
            return


# ---------------------------------------------------------------------------
# WebSocket handler
# ---------------------------------------------------------------------------


async def websocket_handler(websocket):
    """Handle a new WebSocket connection from a worker."""
    client_addr = websocket.remote_address
    server_stats["total_connections"] += 1

    # Worker sends its connection_id as the first message
    try:
        first_msg = await asyncio.wait_for(websocket.recv(), timeout=10.0)
        data = json.loads(first_msg)
        connection_id = data.get("connection_id", str(client_addr))
    except Exception:
        connection_id = f"unknown-{client_addr}"

    print(f"[CONNECT] {connection_id} from {client_addr}")
    connected_clients[connection_id] = {
        "websocket": websocket,
        "connected_at": datetime.utcnow().isoformat(),
    }

    try:
        if SERVER_MODE == "transcript":
            await stream_transcript(websocket, connection_id)
        else:
            # Manual mode: just hold the connection open
            await websocket.wait_closed()
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.pop(connection_id, None)
        print(f"[DISCONNECT] {connection_id}")


# ---------------------------------------------------------------------------
# HTTP control API (available in both modes)
# ---------------------------------------------------------------------------


async def http_status(request):
    """GET /status - server status and connected clients."""
    return web.json_response({
        "status": "running",
        "mode": SERVER_MODE,
        "connected_clients": len(connected_clients),
        "connection_ids": list(connected_clients.keys()),
        "total_connections": server_stats["total_connections"],
        "total_messages_sent": server_stats["messages_sent"],
    })


async def http_send_message(request):
    """POST /send - send a manual message to one or all clients."""
    data = await request.json()
    message = data.get("message", "Manual test message")
    connection_id = data.get("connection_id")

    if connection_id:
        if connection_id in connected_clients:
            ws = connected_clients[connection_id]["websocket"]
            payload = json.dumps({"data": message, "timestamp": time.time()})
            await ws.send(payload)
            server_stats["messages_sent"] += 1
            print(f"[SEND] -> {connection_id}: {message}")
            return web.json_response({"status": "sent", "connection_id": connection_id})
        else:
            return web.json_response(
                {"error": "connection not found", "available": list(connected_clients.keys())},
                status=404,
            )
    else:
        # Broadcast to all
        print(f"[BROADCAST] -> {len(connected_clients)} clients: {message}")
        count = 0
        for conn_id, client in list(connected_clients.items()):
            try:
                payload = json.dumps({"data": message, "timestamp": time.time()})
                await client["websocket"].send(payload)
                count += 1
                server_stats["messages_sent"] += 1
            except Exception:
                pass
        return web.json_response({"status": "broadcast", "sent_to": count})


async def http_stop_stream(request):
    """POST /stop - disconnect a specific client (simulates meeting end)."""
    data = await request.json()
    connection_id = data.get("connection_id")

    if connection_id in connected_clients:
        ws = connected_clients[connection_id]["websocket"]
        end_event = json.dumps({
            "type": "meeting_end",
            "reason": "Meeting ended by host",
            "timestamp": datetime.utcnow().isoformat() + "Z",
        })
        try:
            await ws.send(end_event)
            await ws.close()
        except Exception:
            pass
        return web.json_response({"status": "stopped", "connection_id": connection_id})

    return web.json_response(
        {"error": "not found", "available": list(connected_clients.keys())},
        status=404,
    )


async def start_http_server(http_port: int):
    """Start the HTTP control server."""
    app = web.Application()
    app.router.add_get("/status", http_status)
    app.router.add_post("/send", http_send_message)
    app.router.add_post("/stop", http_stop_stream)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, BIND_HOST, http_port)
    await site.start()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def run(ws_port: int, http_port: int):
    print("=" * 60)
    print("  WebSocket Test Server")
    print("=" * 60)
    print()
    print(f"  Mode:                {SERVER_MODE}")
    print(f"  WebSocket endpoint:  ws://{BIND_HOST}:{ws_port}")
    print(f"  HTTP control:        http://localhost:{http_port}")
    print()
    print("  HTTP Endpoints:")
    print("    GET  /status  - Connected clients and stats")
    print("    POST /send    - Send message: {\"message\": \"...\", \"connection_id\": \"...\"}")
    print("    POST /stop    - End a stream:  {\"connection_id\": \"...\"}")
    print()
    if SERVER_MODE == "transcript":
        print("  Transcript mode: each connection auto-receives a simulated")
        print("  meeting transcript. Use /send for additional manual messages.")
    else:
        print("  Manual mode: connections stay idle until you POST /send.")
    print()
    print("  To test with the fleet:")
    print(f"    curl -X POST <api>/events \\")
    print(f'      -d \'{{"event_type":"START","connection_id":"meeting-1",')
    print(f'           "ws_url":"ws://<this-host>:{ws_port}"}}\'')
    print()
    print("=" * 60)
    print()

    await start_http_server(http_port)

    async with websockets.serve(websocket_handler, BIND_HOST, ws_port):
        await asyncio.Future()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="WebSocket test server")
    parser.add_argument("--mode", choices=["transcript", "manual"], default="transcript",
                        help="transcript: auto-stream meeting data; manual: wait for /send commands")
    parser.add_argument("--port", type=int, default=8765, help="WebSocket port (default: 8765)")
    parser.add_argument("--http-port", type=int, default=8766, help="HTTP control port (default: 8766)")
    parser.add_argument("--host", default="0.0.0.0",  # nosec B104
                        help="Bind host (default: 0.0.0.0; use 127.0.0.1 for local-only)")
    args = parser.parse_args()

    SERVER_MODE = args.mode
    BIND_HOST = args.host

    try:
        asyncio.run(run(args.port, args.http_port))
    except KeyboardInterrupt:
        print("\n\nServer stopped.")
