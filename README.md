# slack-groupme-gateway

This is a really hacky gateway between GroupMe and Slack. It currently relies on Incoming/Outgoing web hooks on the Slack side.

## Configuration:

The config file is stored in `~/.config/slack-groupme-gateway/config.toml` and should look like the following:

```toml
# GroupMe configuration
[groupme]

  [[groupme.groups]]
  group_id = "1234"
  name = "Group name" # not currently used
  bot_id = "1234abcd"
  user_id = "1234" # the user id that corresponds to the bot

# Slack configuration
[slack]
webhook_url = "https://hooks.slack.com/services/..." # Incoming Web Hook URL
token = "1234abcd"
user_id = "USLACKBOT" # user id for the bot

  [[slack.channels]]
  name = "gateway-channel"

# Gateways
[[gateways]]
groupme = "1234" # group id of the configured GroupMe group
sack = "gateway-channel" # name of the configured Slack channel
```
