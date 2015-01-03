{EventEmitter} = require 'events'
Util = require 'util'
Q = require 'q'
ScopedClient = require 'scoped-http-client'
Slack = require 'slack-client'
SlackMessage = require 'slack-client/src/message'

class Client extends EventEmitter
  API_URL: "https://slack.com/api"

  # Slack client.
  #
  # Events:
  #   'connected': []
  #   'disconnected': []
  #   'error': [...]
  #   'message': [Slack.Message]
  #   'backfill: [group: String] Emitted when backfill is complete for a given group
  #
  # Arguments:
  #   api_token: (String) The Slack API token
  #   groups: (Array<String>; Optional) Group names to backfill
  #   redis: (Redis.Client; Optional)
  #   logger: (Log; Optional)
  constructor: (@api_token, @groups, @redis, @logger) ->
    @_http = ScopedClient.create @API_URL
                         .header 'Accept', 'application/json'
                         .query 'token', @api_token

  connect: ->
    return if @_slack
    @_stopped = false

    autoReconnect = false # we'll handle that ourselves
    autoMark = false
    @_slack = new Slack(@api_token, autoReconnect, autoMark)
    @_handlers = {}

    if @redis
      @_slack.once 'loggedIn', @_handlers['loggedIn'] = =>
        @_debug 'loggedIn'
        if Util.isArray(@groups) and @groups.length > 0
          @_backfill()
        else
          @_debug 'Skipping backfill; no groups configured'
    else
      @_debug 'Skipping backfill; no Redis configured'

    @_slack.on 'open', @_handlers['open'] = =>
      @emit 'connected'

    @_slack.on 'close', @_handlers['close'] = =>
      @_slack = null
      @emit 'disconnected'

    @_slack.on 'error', @_handlers['error'] = (args...) =>
      @emit 'error', args...
      stopped = @_stopped
      @disconnect()
      @_stopped = stopped
      setImmediate =>
        @connect() unless @_stopped

    @_slack.on 'message', @_handlers['message'] = (message) =>
      @_handleMessage message

    @_slack.login()

  # Shuts down the connection and returns a Promise.
  disconnect: ->
    @_stopped = true
    promise = if @_slack
      @_slack.removeListener key, f for key, f of @_handlers
      @_handlers = {}
      deferred = Q.defer()
      @_slack.once 'close', ->
        deferred.resolve()
      @_slack.once 'error', ->
        # can't distinguish between websocket errors and other errors, but I don't see a choice
        deferred.reject()
      if not @_slack.disconnect()
        # it wasn't connected anyway
        deferred.resolve()
      @_slack = null
      deferred.promise
    else
      Q()
    promise.finally =>
      @emit 'disconnected'

  # Returns a Promise.
  sendMessage: (webhook_url, group, username, text, avatar_url) ->
    http = ScopedClient.create webhook_url
    data = {
      text: text,
      parse: 'full'
    }
    data.channel = group if group
    data.username = username if username
    data.icon_url = avatar_url if avatar_url
    data = JSON.stringify data
    deferred = Q.defer()
    http.header 'Content-Type', 'application/json'
        .post(data) (err, resp, body) =>
      return deferred.reject err if err
      unless 200 <= resp.statusCode <= 299
        return deferred.reject new Error("Slack chat.postMessage code #{resp.statusCode}")
      deferred.resolve()
    deferred.promise

  # expose utility functions
  ['getUserByID', 'getUserByName', 'getChannelByID', 'getChannelByName'].forEach (key) =>
    @::[key] = (args...) ->
      @_slack[key](args...)

  _handleMessage: (message) ->
    if buffer = @_buffer?[message.channel]
      return buffer.push message
    setImmediate =>
      @emit 'message', message
      if @redis
        Q.ninvoke(@redis, 'set', @_redisGroupKey(message.channel), message.ts).catch (reason) =>
          @emit 'error', reason

  _backfill: () ->
    @_debug 'Backfilling for groups', @groups
    @_buffer = {}
    groups = (@_slack.getChannelByName(name) for name in @groups)
    @_buffer[group.id] = [] for group in groups
    Q.npost(@redis, 'mget', @_redisGroupKey(group.id) for group in groups).done (last_reads) =>
      @_debug 'Redis MGET:', last_reads
      http = @_http.scope 'channels.history'
      groups.forEach (group, i) =>
        last_read = last_reads[i]
        unless last_read
          @_debug "Skipping backfill for ##{group.name}, no last_read found"
          return @_drainBuffer group.id
        buffer = @_buffer[group.id]
        deferred = Q.defer()
        http.query 'channel', group.id
            .query 'count', 20
            .get() (err, resp, body) =>
          return deferred.reject(err) if err
          try
            data = JSON.parse(body)
          catch e
            return deferred.reject(e)
          return deferred.reject data.error unless data.ok
          deferred.resolve data
        deferred.promise.then (data) =>
          @_debug "Backfill for ##{group.name} fetched #{data.messages.length} messages"
          for msg in data.messages
            continue if msg.ts <= last_read
            msg.channel = group.id
            msg.backfill = true
            buffer.push new SlackMessage(@_slack, msg)
        , (reason) =>
          @emit 'error', reason
        .finally =>
          @_drainBuffer group.id
        .done()
    , (reason) =>
      @emit 'error', reason
      @_drainBuffer group.id for group in groups

  _drainBuffer: (groupid) ->
    buffer = @_buffer[groupid]
    @_debug "Draining buffer for #{groupid}: #{buffer.length} messages"
    delete @_buffer[groupid]
    buffer.sort (a, b) ->
      switch
        when a < b then -1
        when a > b then 1
        else 0
    last_ts = ""
    for msg in buffer
      continue if msg.ts == last_ts
      last_ts = msg.ts
      setImmediate (msg) =>
        @emit 'message', msg
      , msg
    if last_ts and @redis
      setImmediate =>
        Q.ninvoke(@redis, 'set', @_redisGroupKey(groupid), last_ts).catch (reason) =>
          @emit 'error', reason
    setImmediate =>
      @emit 'backfill', groupid

  _redisGroupKey: (groupid) ->
    "slack:channel:#{groupid}:last_read_ts"

  _debug: (message, args...) ->
    return unless @logger
    @logger.debug '[Slack]', Util.format(message, args...)

module.exports = { Client }
