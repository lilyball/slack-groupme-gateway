{EventEmitter} = require 'events'
Log = require 'log'
Url = require 'url'
Q = require 'q'
Redis = require 'redis'
Queue = require './queue'
GroupMe = require './groupme'
Slack = require './slack'

class Bot extends EventEmitter
  # The Bot.
  #
  # Arguments:
  #   logger: (Log, Optional) The logger to use.
  constructor: (@logger)->
    @logger ||= new Log(process.env.BOT_LOG_LEVEL || Log.INFO)
    @groupme_queue = new Queue()
    @groupme_queue.on 'error', (err) =>
      if err.stack
        @logger.error "GroupMe Queue error: #{err.stack}"
      else
        @logger.error "GroupMe Queue error:", err
    @groupme_queue.throttle 10, 10000
    @slack_queue = new Queue()
    @slack_queue.on 'error', (err) =>
      if err.stack
        @logger.error "Slack Queue error: #{err.stack}"
      else
        @logger.error "Slack Queue error:", err
    @slack_queue.throttle 10, 10000

  run: ->
    return if @running # we can only run once
    @running = true

    @options = {}
    for key, value of process.env
      if /^GROUPME_/.test(key) or /^SLACK_/.test(key) or key in ["REDISCLOUD_URL"]
        @options[key] = value

    groupmeInit = @_groupmeInit()
    slackInit = @_slackInit()

    if @options.REDISCLOUD_URL
      redisURL = Url.parse @options.REDISCLOUD_URL
      @redis = Redis.createClient(redisURL.port, redisURL.hostname, {no_ready_check: true})
      @redis.on 'error', (err) =>
        @emit 'error', "Redis error", err
      @redis.auth redisURL.auth.split(':')[1]

    groupmeInit()
    slackInit()

  _groupmeInit: ->
    for key in ["GROUPME_ACCESS_TOKEN", "GROUPME_USER_ID", "GROUPME_GROUP_ID", "GROUPME_BOT_ID", "GROUPME_BOT_USER_ID"]
      if not @options[key]
        @emit 'error', new ConfigError(key)
        return (->)
    =>
      @groupme = new GroupMe.Client(@options.GROUPME_ACCESS_TOKEN, @options.GROUPME_USER_ID, [@options.GROUPME_GROUP_ID], @redis, @logger)

      @groupme.on 'error', (err) =>
        if err.stack
          @logger.error err.stack
        else
          @logger.error "GroupMe error: #{err.message}"

      @groupme.on 'connected', =>
        @logger.info "GroupMe connected"

      @groupme.on 'disconnected', =>
        @logger.info "GroupMe disconnected."

      @groupme.on 'backfill', (groupid) =>
        @logger.info "GroupMe backfill for group #{groupid} complete"

      @groupme.on 'message', (msg) =>
        return unless msg.group_id == @options.GROUPME_GROUP_ID
        return if msg.user_id == @options.GROUPME_BOT_USER_ID
        if msg.backfill
          if @logger.level >= Log.DEBUG
            @logger.debug 'Received backfilled GroupMe message', msg
          else
            @logger.info 'GroupMe (backfill): [%s] %s', msg.name, msg.text
        else
          if @logger.level >= Log.DEBUG
            @logger.debug 'Received GroupMe message', msg
          else
            @logger.info 'GroupMe: [%s] %s', msg.name, msg.text
        @slack_queue.run =>
          groupid = @slack.getChannelByName(@options.SLACK_GROUP_NAME).id
          @slack.sendMessage groupid, msg.name, msg.text, msg.avatar_url

      @groupme.on 'unknown', (type, channel, msg) =>
        @logger.warning 'Unknown GroupMe message %j:', type, msg

      @groupme.connect()

  _slackInit: ->
    for key in ["SLACK_API_TOKEN", "SLACK_GROUP_NAME", "SLACK_BOT_ID"]
      if not @options[key]
        @emit 'error', new ConfigError(key)
        return (->)
    =>
      @slack = new Slack.Client(@options.SLACK_API_TOKEN, [@options.SLACK_GROUP_NAME], @redis, @logger)

      @slack.on 'error', (err) =>
        if err.stack
          @logger.error err.stack
        else
          @logger.error "Slack error: #{err.message}"

      @slack.on 'connected', =>
        @logger.info "Slack connected"

      @slack.on 'disconnected', =>
        @logger.info "Slack disconnected"

      @slack.on 'backfill', (groupid) =>
        group = @slack.getChannelByID(groupid)
        @logger.info "Slack backfill for channel ##{group.name} complete"

      @slack.on 'message', (msg) =>
        return unless @slack.getChannelByID(msg.channel).name == @options.SLACK_GROUP_NAME
        return if msg.bot_id == @options.SLACK_BOT_ID
        body = msg.getBody()
        if @logger.level >= Log.DEBUG
          # we don't want to log the _client key
          debugMsg = {}
          for own key, value of msg
            debugMsg[key] = value unless key == "_client"
          if msg.backfill
            @logger.debug "Received backfilled Slack message", debugMsg
          else
            @logger.debug "Received Slack message", debugMsg
        else if @logger.level >= Log.INFO
          text = ""
          user = @slack.getUserByID msg.user
          if user
            text += "[#{user.name}] "
          else if msg.username
            if msg.subtype == "bot_message"
              text += "[bot] "
            text += "[#{msg.username}] "
          text += body if body
          if msg.backfill
            @logger.info 'Slack (backfill):', text
          else
            @logger.info 'Slack:', text
        if body
          @groupme_queue.run =>
            user = @slack.getUserByID msg.user
            text = ""
            if user
              text = "[#{user.name}] "
            else if msg.username
              text = "[#{msg.username}] "
            text += body
            @groupme.sendMessage @options.GROUPME_BOT_ID, text

      @slack.connect()

  # Stop returns a Promise
  stop: ->
    results = []
    results.push @groupme.disconnect()
    results.push @slack.disconnect()
    Q.all(results).finally =>
      Q.ninvoke @redis, 'quit'

class ConfigError extends Error
  # Bot config error.
  #
  # @key: (String) Bad configuration key.
  constructor: (@key) ->
    @message = "Missing or invalid configuration #{@key}"
    super @message
    Error.captureStackTrace @, @constructor

  @::name = "ConfigError"

module.exports = { Bot, ConfigError }
