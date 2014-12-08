# slack-groupme-gateway

This is a really hacky gateway between GroupMe and Slack. It currently relies on Incoming/Outgoing web hooks on the Slack side.

## Configuration:

The config file is stored in `~/.config/slack-groupme-gateway/config.toml` and should look like the following:

```toml
# Server configuration
server_name = "my.server.com" # used for display only
#port = 5287

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

## Slack

To set this up with a Slack team, configure both an Incoming and an Outgoing web hook. The Outgoing web hook should be pointed at `http://server/slack`, and the Incoming web hook URL should be put in the config. The `user_id` for the incoming web hook needs to be determined and placed into the config, so the outgoing web hook can ignore it.

## GroupMe

To set this up with GroupMe, a bot needs to be created and the `group_id` and `bot_id` should be placed into the config. The `user_id` for the bot needs to be determined and placed into the config, so the gateway can ignore its own messages.
