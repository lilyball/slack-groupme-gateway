Log = require 'log'
Url = require 'url'
Q = require 'q'
Redis = require 'redis'
GroupMe = require './groupme'
{EventEmitter} = require 'events'

class Bot extends EventEmitter
  # The Bot.
  #
  # Arguments:
  #   logger: (Log, Optional) The logger to use.
  constructor: (@logger)->
    @logger ||= new Log(process.env.BOT_LOG_LEVEL || Log.INFO)

  run: ->
    return if @groupme # we can only run once

    @options = {}
    for key, value of process.env
      if /^GROUPME_/.test(key) or /^SLACK_/.test(key) or key in ["REDISCLOUD_URL"]
        @options[key] = value

    for key in ["GROUPME_ACCESS_TOKEN", "GROUPME_USER_ID", "GROUPME_GROUP_ID", "GROUPME_BOT_ID", "GROUPME_BOT_USER_ID"]
      if not @options[key]
        @emit 'error', new ConfigError(key)
        return false

    if @options.REDISCLOUD_URL
      redisURL = Url.parse @options.REDISCLOUD_URL
      @redis = Redis.createClient(redisURL.port, redisURL.hostname, {no_ready_check: true})
      @redis.on 'error', (err) =>
        @emit 'error', "Redis error", err
      @redis.auth redisURL.auth.split(':')[1]

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

    @groupme.on 'unknown', (type, channel, msg) =>
      @logger.warning 'Unknown GroupMe message %j:', type, msg

    @groupme.connect()

  # Stop returns a Promise
  stop: ->
    results = []
    results.push @groupme.disconnect()
    # results.push @slack.disconnect()
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
