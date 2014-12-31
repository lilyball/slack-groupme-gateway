Log = require 'log'
GroupMe = require './groupme'
{EventEmitter} = require 'events'

class Bot extends EventEmitter
  # The Bot.
  #
  # Arguments:
  #   logger: (Log, Optional) The logger to use.
  constructor: (@logger)->
    @logger ||= new Log(process.env.BOT_LOG_LEVEL || Log.INFO)

  emitError: (err, args...) ->
    @logger.error err, args...
    @emit 'error', new Error(Util.format(err, args...))
    @emit 'error', err, args...

  run: ->
    return if @groupme # we can only run once

    @options = {}
    for key, value of process.env
      if /^GROUPME_/.test(key) or /^SLACK_/.test(key)
        @options[key] = value

    for key in ["GROUPME_ACCESS_TOKEN", "GROUPME_USER_ID"]
      if not @options[key]
        @emit new ConfigError(key)
        return false

    @groupme = new GroupMe.Client(@options.GROUPME_ACCESS_TOKEN, @options.GROUPME_USER_ID)

    @groupme.on 'error', (err) =>
      if err.stack
        @logger.error err.stack
      else
        @logger.error "GroupMe error: #{err.message}"

    @groupme.on 'connected', =>
      @logger.info "GroupMe connected"

    @groupme.on 'disconnected', =>
      @logger.info "GroupMe disconnected."

    @groupme.on 'message', (msg) =>
      @logger.debug 'Received GroupMe message', msg

    @groupme.on 'unknown', (type, channel, msg) =>
      @logger.warning 'Unknown GroupMe message %j:', type, msg

    @groupme.connect()

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
