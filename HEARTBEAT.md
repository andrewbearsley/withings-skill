# Heartbeat - Bathroom Scales

Add the following checklist item to the agent's workspace `HEARTBEAT.md` to enable
automatic body measurement monitoring on the heartbeat cycle:

```markdown
- [ ] Check Withings bathroom scales via the bathroom-scales skill. If there's
      a new measurement since the last check, include a brief summary of weight
      and body composition. Alert me if the API is unreachable or tokens have
      expired. Don't message me if there's nothing new.
```

## What the agent will do on each heartbeat

1. Get a valid access token (auto-refreshes if expired)
2. Query recent measurements via the Withings API
3. Parse weight, body fat %, muscle mass, and other body composition data
4. Check for alert conditions (token failure, stale data)
5. **Only notify the user if there's a new measurement or something is wrong** — silent otherwise

## Alert thresholds

| Condition | Action |
|-----------|--------|
| Token refresh failed | Alert immediately — will lose API access |
| No measurement in 7 days | Medium alert — scale may not be syncing |
| Weight change > 2kg from 7-day average | Note — include in summary, not an alert |
| API error (non-transient) | Alert with error details |
