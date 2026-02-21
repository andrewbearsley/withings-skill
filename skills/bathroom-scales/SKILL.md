---
name: bathroom-scales
description: Monitor body measurements from Withings bathroom scales via the Withings API.
version: 1.0.0
homepage: https://github.com/andrewbearsley/openclaw-withings
metadata: {"openclaw": {"requires": {"bins": ["curl", "jq"], "env": ["WITHINGS_CLIENT_ID", "WITHINGS_CLIENT_SECRET", "WITHINGS_TOKEN_FILE"]}, "primaryEnv": "WITHINGS_CLIENT_ID"}}
---

# Bathroom Scales Skill

You can monitor body measurements from Withings bathroom scales (Body, Body+, Body Comp, Body Scan, etc.) via the Withings API. The scales sync measurements to Withings cloud via Wi-Fi; the API lets you query historical data.

**API Base URL:** `https://wbsapi.withings.net`
**Authentication:** OAuth2 Bearer token. Tokens are managed by `withings-auth.sh`. Use `withings-auth.sh token` to get a valid access token (auto-refreshes if expired).

**Important:** Access tokens expire after 3 hours. Refresh tokens expire after 1 year but are rotated on each refresh. The new refresh token MUST be saved immediately or you lose API access until the user re-authorizes.

**All weights are in kilograms. All percentages are 0-100.**

---

## Configuration

These are the default alert thresholds. The user may edit them here to suit their preferences.

**Measurement staleness:**
- No measurement in **7 days**: medium alert

**Weight change:**
- Weight change > **2kg** from 7-day average: note (not alert, just mention it)

**Token health:**
- Token refresh failure: **high alert** (will lose API access if not fixed)

---

## Error Handling

The API can fail in several ways. Handle each:

### API errors

| Error | Handling |
|-------|----------|
| `status: 401` (Invalid token) | Refresh the token via `withings-auth.sh refresh` and retry once. If refresh also fails, alert: "Withings token expired, re-run `withings-auth.sh setup`." |
| `status: 503` (Service unavailable) | Wait 60 seconds and retry once. Do not alert the user. |
| `status: 601` (Too many requests) | Wait 60 seconds and retry once. Do not alert the user. |
| `status: 2554` (Wrong redirect URI) | Alert: "Withings OAuth config error, check WITHINGS_REDIRECT_URI matches the developer app." |
| `status: 2555` (Invalid code) | Alert: "Authorization code invalid or expired, re-run `withings-auth.sh setup`." |
| Connection timeout / network error | Log and skip this check. Alert if it persists across multiple heartbeats. |

### Common setup issues

| Symptom | Cause | Fix |
|---------|-------|-----|
| "Invalid token" on every call | Refresh token was rotated but not saved | Re-run `withings-auth.sh setup` |
| No measurements returned | Scale hasn't synced, or wrong user_id | Check the scale has synced recently in the Withings app |
| "Invalid params" error | Missing or wrong meastypes | Check the API call includes `meastypes=1,5,6,8,76,77,88` |
| Token file not found | OAuth setup not completed | Run `withings-auth.sh setup` |

---

## API Reference

### Measure - Getmeas (`/measure`)

Returns body measurements for the authenticated user.

```bash
ACCESS_TOKEN=$(scripts/withings-auth.sh token)
curl -s -X POST https://wbsapi.withings.net/measure \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -d "action=getmeas&meastypes=1,5,6,8,76,77,88&category=1&lastupdate=$(date -v-7d +%s)"
```

**Parameters:**

| Parameter | Type | Description |
|-----------|------|-------------|
| `action` | string | Must be `getmeas` |
| `meastypes` | string | Comma-separated measurement type IDs |
| `category` | int | 1 = real measurements, 2 = user objectives |
| `lastupdate` | int | Unix timestamp — return measurements since this time |
| `startdate` | int | Unix timestamp — start of date range |
| `enddate` | int | Unix timestamp — end of date range |
| `offset` | int | Pagination offset (from `more` and `offset` in response) |

**Measurement type codes:**

| Code | Type | Unit |
|------|------|------|
| 1 | Weight | kg |
| 5 | Fat-Free Mass | kg |
| 6 | Fat Ratio | % |
| 8 | Fat Mass (Weight) | kg |
| 76 | Muscle Mass | kg |
| 77 | Hydration | kg |
| 88 | Bone Mass | kg |

**Value conversion:** Raw values are returned as `{ value, unit }` pairs. The actual measurement is:

```
actual = value * 10^unit
```

For example: `{ "value": 72345, "unit": -3 }` → `72345 * 10^-3` = **72.345 kg**

**Response structure:**

```json
{
  "status": 0,
  "body": {
    "updatetime": 1700000000,
    "timezone": "Australia/Sydney",
    "measuregrps": [
      {
        "grpid": 123456,
        "date": 1700000000,
        "created": 1700000000,
        "deviceid": "abc123",
        "measures": [
          { "value": 72345, "type": 1, "unit": -3 },
          { "value": 2156, "type": 6, "unit": -2 }
        ]
      }
    ],
    "more": 0,
    "offset": 0
  }
}
```

- `status: 0` means success. Any other value is an error.
- `measuregrps` are grouped by measurement session (one weigh-in = one group).
- `more: 1` means there are more pages — use `offset` in the next request.

### OAuth2 Token Refresh (`/v2/oauth2`)

```bash
curl -s -X POST https://wbsapi.withings.net/v2/oauth2 \
  -d "action=requesttoken&grant_type=refresh_token&client_id=$WITHINGS_CLIENT_ID&client_secret=$WITHINGS_CLIENT_SECRET&refresh_token=$REFRESH_TOKEN"
```

**Response:**

```json
{
  "status": 0,
  "body": {
    "userid": "123456",
    "access_token": "new_access_token",
    "refresh_token": "new_refresh_token",
    "expires_in": 10800
  }
}
```

**Critical:** The response contains a NEW `refresh_token`. Save it immediately. The old one is invalidated. If you lose the new one, the user has to re-authorize.

---

## Heartbeat Behaviour

When this skill is invoked during a heartbeat check, follow this procedure:

### 1. Get a valid token

```bash
ACCESS_TOKEN=$(scripts/withings-auth.sh token)
```

This auto-refreshes if expired. If it fails, alert immediately.

### 2. Query recent measurements

```bash
scripts/withings-status.sh --json --days 7
```

### 3. Check for errors

If the response indicates an error:
- **Token expired and refresh failed:** Alert the user: "Withings token expired. Re-run `withings-auth.sh setup`."
- **API unavailable / rate limited:** Skip silently, retry next heartbeat.
- **No measurements returned:** Check if anything exists at all. If the last measurement is older than 7 days, flag as medium alert.

### 4. Parse and evaluate

From the most recent measurement group, extract:
- **Weight** (type 1) — in kg
- **Body Fat %** (type 6) — as percentage
- **Fat Mass** (type 8) — in kg
- **Fat-Free Mass** (type 5) — in kg
- **Muscle Mass** (type 76) — in kg
- **Bone Mass** (type 88) — in kg
- **Hydration** (type 77) — in kg

Calculate the 7-day average weight if multiple measurements are available.

### 5. Alert conditions

| Condition | Severity | Message |
|-----------|----------|---------|
| Token refresh failed | High | Withings token expired — re-run `withings-auth.sh setup` |
| No measurement in 7 days | Medium | No Withings measurement in the last 7 days |
| Weight change > 2kg from 7-day average | Note | Weight is {weight}kg — {change}kg from 7-day average of {avg}kg |
| API error (non-transient) | Medium | Withings API error: {status} |

### 6. Reporting

- **New measurement since last heartbeat:** Include a brief summary with weight, body fat %, and any notable changes.
- **Nothing new:** Do NOT send a message. No noisy "no update" messages.
- **Alert condition detected:** Send the alert regardless of whether there's a new measurement.

---

## Responding to User Queries

When the user asks about their weight or body composition (e.g. "what's my weight?", "show me my body fat trend"):

### Status queries

1. Run `scripts/withings-status.sh` for a formatted summary
2. For trends, use `scripts/withings-status.sh --days 30` (or whatever period makes sense)
3. Format a clear summary:

```
Latest Measurement (2026-02-22 07:30):
  Weight:        72.3 kg
  Body Fat:      21.6%
  Fat Mass:      15.6 kg
  Fat-Free Mass: 56.7 kg
  Muscle Mass:   43.2 kg
  Bone Mass:     3.1 kg
  Hydration:     39.8 kg

7-Day Average:
  Weight:        72.1 kg (range: 71.8 - 72.5 kg)
```

### Trend queries

For questions like "how has my weight changed this month?":
1. Fetch a wider date range with `--days N`
2. Calculate min, max, average, and trend direction
3. Present concisely — don't dump raw data

### Convenience scripts

Two helper scripts in the skill's parent project:

- **`scripts/withings-auth.sh`** OAuth2 setup, token refresh, and token retrieval. Run with `setup`, `refresh`, or `token`.
- **`scripts/withings-status.sh`** Formatted body measurements. Run with `--raw`, `--json`, or `--days N`.

---

## Tips

- The Withings API rate limit is 120 requests per minute, so not a concern for normal use.
- Measurements sync from the scale to Withings cloud via Wi-Fi. There may be a delay of a few minutes after stepping on the scale.
- The `category=1` parameter filters for real measurements only (excludes user-set objectives).
- If `more: 1` in the response, there are additional pages. Use the `offset` value in subsequent requests.
- Measurement groups (`measuregrps`) contain all measurements from a single weigh-in session. One step on the scale produces one group with multiple measure types.
- The token file is at the path specified by `WITHINGS_TOKEN_FILE` (default: `~/.withings-tokens`). It's chmod 600 for security.
