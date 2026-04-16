# Clawk iOS

Personal iOS app for chatting with IronClaw-backed agents. Built with SwiftUI, powered by Tailscale + Railway.

## Architecture

```
┌─────────────┐     Tailscale      ┌──────────────┐
│   iPhone    │◄──────────────────►│   Railway    │
│  (Clawk)    │   (WireGuard VPN)  │   (Relay)    │
└─────────────┘                    └──────────────┘
                                          │
                                          ▼
                                   ┌──────────────┐
                                   │  IronClaw    │
                                   │   Service    │
                                   └──────────────┘
```

## Structure

```
├── backend/           # Node.js relay (deploy to Railway)
│   ├── server.js
│   └── package.json
├── Clawk/             # SwiftUI iOS app
│   └── ...
└── README.md
```

## Setup

### 1. Backend (Railway)

```bash
cd backend
railway login
railway init
railway up
```

Get your public URL: `railway domain`

### 2. iOS App

Open `Clawk/Clawk.xcodeproj` in Xcode.

Update `Config.swift` with your Railway URL.

### 3. Pair Device

On first launch, the app shows a QR code. Scan with any device to pair.

Or manually POST to `/pair`:

```bash
curl -X POST https://your-app.railway.app/pair \
  -H "Content-Type: application/json" \
  -d '{"deviceToken": "your-device-token", "deviceName": "Kish iPhone"}'
```

### 4. Send Messages

From your backend service (or any HTTP client):

```bash
curl -X POST https://your-app.railway.app/message \
  -H "Content-Type: application/json" \
  -H "x-device-token: your-device-token" \
  -d '{
    "message": "Approve this clip for upload?",
    "actions": ["Approve", "Reject", "Later"]
  }'
```

## Message Types

### Card (default)
```json
{
  "type": "card",
  "message": "Your message here",
  "actions": ["Button 1", "Button 2"]
}
```

### Input
```json
{
  "type": "input",
  "message": "What's your ETA?",
  "inputType": "text"
}
```

### List
```json
{
  "type": "list",
  "message": "Choose a clip:",
  "actions": ["Clip 1", "Clip 2", "Clip 3"]
}
```

## Local Development

### Backend
```bash
cd backend
npm install
npm start
```

### iOS App
Open in Xcode, run on device or simulator.

## Tailscale Notes

- Install Tailscale on your iPhone
- Install Tailscale on Railway (use Tailscale SSH or subnet routes)
- Or: Keep Railway public but use token auth (what we do here)

For fully private setup:
1. Run relay on your Tailscale network (home machine or VPS with Tailscale)
2. Point iOS app to Tailscale IP
3. No public internet needed
