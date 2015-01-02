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
    autoMark = true
    @_slack = new Slack(@api_token, autoReconnect, autoMark)
    @_handlers = {}

    @_slack.once 'loggedIn', @_handlers['loggedIn'] = =>
      return unless Util.isArray @groups
      @_last_read = @_slack.getChannelByName(name)?.last_read for name in @groups
      @_backfill()

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
    if @_slack
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

  # Returns a Promise.
  sendMessage: (groupid, username, text, avatar_url) ->
    http = @_http.scope 'chat.postMessage'
                 .query 'channel', groupid
                 .query 'text', text
                 .query 'parse', 'full'
    http.query 'username', username if username
    http.query 'icon_url', avatar_url if avatar_url
    deferred = Q.defer()
    http.get() (err, resp, body) =>
      return deferred.reject err if err
      unless 200 <= resp.statusCode <= 299
        return deferred.reject new Error("Slack chat.postMessage code #{resp.statusCode}")
      try
        data = JSON.parse(body)
      catch e
        return deferred.reject e
      return deferred.reject data.error unless data.ok
      deferred.resolve data
    deferred.promise

  # expose utility functions
  ['getUserByID', 'getUserByName', 'getChannelByID', 'getChannelByName'].forEach (key) =>
    @::[key] = (args...) ->
      @_slack[key](args...)

  _handleMessage: (message) ->
    if @_buffer?[message.channel]
      return @_buffer.push message
    setImmediate =>
      @emit 'message', message

  _backfill: () ->
    @_buffer = {}
    http = @_http.scope 'channels.history'
    @groups.forEach (group, i) =>
      last_read = @_last_read[i]
      unless last_read
        return @emit 'backfill', group
      group = @_slack.getChannelByName(group)
      @_buffer[group.id] = buffer = []
      deferred = Q.defer()
      http.query 'channel', group.id
          .get() (err, resp, body) =>
        return deferred.reject(err) if err
        try
          data = JSON.parse(body)
        catch e
          return deferred.reject(e)
        return deferred.reject data.error unless data.ok
        deferred.resolve data
      deferred.promise.then (data) =>
        for msg in data.messages
          continue if msg.ts <= last_read
          msg.channel = group.id
          msg.backfill = true
          buffer.push new SlackMessage(@_slack, msg)
      , (reason) =>
        @emit 'error', reason
      .finally =>
        delete @_buffer[group.id]
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
        setImmediate (id) =>
          @emit 'backfill', id
        , group.id
        if last_ts
          group.mark last_ts
      .done()

module.exports = { Client }
