# AI agent skill for Withings bathroom scales

![Format](https://img.shields.io/badge/format-Agent%20Skill-blue)
![Bash](https://img.shields.io/badge/bash-%23121011?logo=gnu-bash&logoColor=white)
![License](https://img.shields.io/github/license/andrewbearsley/openclaw-withings)

Monitor body measurements from Withings bathroom scales (Body, Body+, Body Comp, Body Scan) via the [Withings API](https://developer.withings.com/). Built as an [OpenClaw](https://openclaw.ai) skill, but the scripts work fine standalone too.

Tracks weight, body fat %, muscle mass, bone mass, and hydration. Measurements sync from the scale over Wi-Fi to the Withings cloud; the skill queries the API to pull them down.

## Agent quick-start

If you're an AI agent and your user has pointed you at this repo, here's how to install the skill without cloning.

**Requirements:** `curl`, `jq` must be available on the system.

**1. Download the skill and scripts:**

```bash
REPO="https://raw.githubusercontent.com/andrewbearsley/openclaw-withings/main"
SKILL_DIR="$HOME/.openclaw/skills/bathroom-scales"
SCRIPT_DIR="$SKILL_DIR/scripts"

mkdir -p "$SCRIPT_DIR"
curl -fsSL "$REPO/skills/bathroom-scales/SKILL.md" -o "$SKILL_DIR/SKILL.md"
curl -fsSL "$REPO/scripts/withings-auth.sh"         -o "$SCRIPT_DIR/withings-auth.sh"
curl -fsSL "$REPO/scripts/withings-status.sh"       -o "$SCRIPT_DIR/withings-status.sh"
chmod +x "$SCRIPT_DIR"/*.sh
```

**2. Set environment variables:**

The skill requires two environment variables. Ask your user for these if they haven't provided them:

| Variable | Required | What it is | Where to find it |
|----------|----------|-----------|-----------------|
| `WITHINGS_CLIENT_ID` | Yes | OAuth2 client ID | Withings Developer Dashboard > App settings |
| `WITHINGS_CLIENT_SECRET` | Yes | OAuth2 client secret | Withings Developer Dashboard > App settings |
| `WITHINGS_TOKEN_FILE` | No | Path to store tokens (default: `~/.withings-tokens`) | Configurable |

Set them in `~/.openclaw/.env` or in your agent's environment.

**3. Run the OAuth2 setup (one-time, requires user interaction):**

```bash
$SCRIPT_DIR/withings-auth.sh setup
```

The user opens a URL in their browser, authorizes the app, and pastes back the redirect URL.

**4. Verify it works:**

```bash
# Check body measurements
$SCRIPT_DIR/withings-status.sh

# Check JSON output
$SCRIPT_DIR/withings-status.sh --json
```

**5. Read the SKILL.md** for full API reference, alert thresholds, and heartbeat behaviour. Everything the agent needs is in that file.

## What it does

- Latest body measurements (weight, body fat %, muscle mass, bone mass, hydration)
- Historical data over configurable date ranges
- Heartbeat monitoring that stays quiet unless something's noteworthy
- Automatic token refresh (3-hour access tokens, rotated refresh tokens)

## Human setup

You'll need to do these steps before the agent can use the skill.

### 1. Create a Withings developer app

1. Go to [Withings Developer Dashboard](https://developer.withings.com/dashboard/)
2. Create an account or log in
3. Click **Create an Application**
4. Fill in the form:
   - **Application Name:** whatever you like (e.g. "OpenClaw Body Metrics")
   - **Description:** "Personal body measurement monitoring"
   - **Callback URL:** `http://localhost:9876/callback`
   - **Application Permissions:** select at least `User metrics`
5. Note your **Client ID** and **Client Secret**

### 2. Run the OAuth2 authorization

```bash
export WITHINGS_CLIENT_ID=your_client_id
export WITHINGS_CLIENT_SECRET=your_client_secret

./scripts/withings-auth.sh setup
```

Follow the prompts: open the URL, log in, authorize, paste the redirect URL back.

### 3. Give your agent the credentials

Add the environment variables to `~/.openclaw/.env`:

```
WITHINGS_CLIENT_ID=your_client_id
WITHINGS_CLIENT_SECRET=your_client_secret
WITHINGS_TOKEN_FILE=~/.withings-tokens
```

Then point your agent at this repo and ask it to install the skill.

## Usage

### Status

```bash
./scripts/withings-status.sh              # Formatted summary
./scripts/withings-status.sh --raw        # Raw JSON from the API
./scripts/withings-status.sh --json       # Parsed JSON with readable values
./scripts/withings-status.sh --days 30    # Last 30 days of measurements
```

### Token management

```bash
./scripts/withings-auth.sh setup          # One-time OAuth2 authorization
./scripts/withings-auth.sh refresh        # Manually refresh access token
./scripts/withings-auth.sh token          # Get valid access token (auto-refreshes)
```

### Heartbeat

If your agent supports heartbeat checks:

```markdown
- [ ] Check Withings bathroom scales via the bathroom-scales skill. If there's
      a new measurement since the last check, include a brief summary of weight
      and body composition. Alert me if the API is unreachable or tokens have
      expired. Don't message me if there's nothing new.
```

## What it alerts on

| Condition | Severity |
|-----------|----------|
| Token refresh failure | High |
| No measurement in 7 days | Medium |
| Weight change > 2kg from 7-day average | Note |

All thresholds are configurable in `SKILL.md`. The skill stays quiet when everything's normal.

## Troubleshooting

| Problem | What's going on | Fix |
|---------|-----------------|-----|
| "Token file not found" | OAuth setup not completed | Run `withings-auth.sh setup` |
| "Invalid token" on every call | Refresh token was rotated but not saved | Re-run `withings-auth.sh setup` |
| No measurements returned | Scale hasn't synced or wrong account | Check the scale synced recently in the Withings app |
| "Invalid params" error | Missing measurement types | Verify `meastypes=1,5,6,8,76,77,88` in API call |
| Token refresh keeps failing | Refresh token expired (>1 year) | Re-run `withings-auth.sh setup` |

## Rate limits

The Withings API allows 120 requests per minute. Not a concern for this use case.

## Files

| File | Purpose |
|------|---------|
| `skills/bathroom-scales/SKILL.md` | Skill definition: API reference, alert thresholds, agent instructions |
| `scripts/withings-auth.sh` | OAuth2 setup and token management |
| `scripts/withings-status.sh` | Query body measurements |
| `HEARTBEAT.md` | Heartbeat config template |

## License

MIT
