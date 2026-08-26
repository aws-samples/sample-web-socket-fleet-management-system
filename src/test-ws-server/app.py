#!/usr/bin/env python3
"""
Meeting transcript WebSocket server — deployed as an ECS Fargate task.

Accepts WebSocket connections from fleet workers and streams a simulated
real-time meeting transcript. Also exposes an HTTP control API on port 8766.

Workers connect to ws://<task-ip>:8765 and receive transcript messages.
"""
import asyncio
import json
import os
import random
import time
from datetime import datetime, timedelta

import websockets
from aiohttp import web

WS_PORT = int(os.environ.get("WS_PORT", "8765"))
HTTP_PORT = int(os.environ.get("HTTP_PORT", "8766"))
# Bind host is configurable. In ECS Fargate (awsvpc) the task has its own ENI,
# so binding to all interfaces is required for service discovery to reach it.
# Override with BIND_HOST for more restrictive local setups.
BIND_HOST = os.environ.get("BIND_HOST", "0.0.0.0")  # nosec B104

# ---------------------------------------------------------------------------
# Transcript data
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
# State
# ---------------------------------------------------------------------------

connected_clients: dict = {}
server_stats = {"total_connections": 0, "messages_sent": 0}

# ---------------------------------------------------------------------------
# Transcript streaming
# ---------------------------------------------------------------------------


async def stream_transcript(websocket, connection_id: str):
    """Stream simulated meeting transcript to a connected worker."""
    seq = 0
    meeting_start = datetime.utcnow()

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

    # Continue with generated content indefinitely
    print(f"  [{connection_id}] Main transcript done, continuing with filler...")
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
    """Handle incoming WebSocket connection from a fleet worker."""
    client_addr = websocket.remote_address
    server_stats["total_connections"] += 1

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
        await stream_transcript(websocket, connection_id)
    except websockets.exceptions.ConnectionClosed:
        pass
    finally:
        connected_clients.pop(connection_id, None)
        print(f"[DISCONNECT] {connection_id}")


# ---------------------------------------------------------------------------
# HTTP control API
# ---------------------------------------------------------------------------


async def http_status(request):
    """GET /status"""
    return web.json_response({
        "status": "running",
        "connected_clients": len(connected_clients),
        "connection_ids": list(connected_clients.keys()),
        "total_connections": server_stats["total_connections"],
        "total_messages_sent": server_stats["messages_sent"],
    })


async def http_send_message(request):
    """POST /send - push a manual message to one or all clients."""
    data = await request.json()
    message = data.get("message", "Manual test message")
    connection_id = data.get("connection_id")

    if connection_id:
        if connection_id in connected_clients:
            ws = connected_clients[connection_id]["websocket"]
            payload = json.dumps({"data": message, "timestamp": time.time()})
            await ws.send(payload)
            server_stats["messages_sent"] += 1
            return web.json_response({"status": "sent", "connection_id": connection_id})
        else:
            return web.json_response(
                {"error": "not found", "available": list(connected_clients.keys())},
                status=404,
            )
    else:
        count = 0
        for client in list(connected_clients.values()):
            try:
                payload = json.dumps({"data": message, "timestamp": time.time()})
                await client["websocket"].send(payload)
                count += 1
                server_stats["messages_sent"] += 1
            except Exception:
                pass
        return web.json_response({"status": "broadcast", "sent_to": count})


async def http_stop(request):
    """POST /stop - disconnect a client."""
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


async def start_http_server():
    app = web.Application()
    app.router.add_get("/status", http_status)
    app.router.add_post("/send", http_send_message)
    app.router.add_post("/stop", http_stop)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, BIND_HOST, HTTP_PORT)
    await site.start()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def main():
    print(f"[START] Transcript WS Server")
    print(f"  WebSocket: ws://{BIND_HOST}:{WS_PORT}")
    print(f"  HTTP:      http://{BIND_HOST}:{HTTP_PORT}")
    print()

    await start_http_server()

    async with websockets.serve(websocket_handler, BIND_HOST, WS_PORT):
        await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(main())
