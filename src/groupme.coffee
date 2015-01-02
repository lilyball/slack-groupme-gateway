{EventEmitter} = require 'events'
Faye = require 'faye'
Util = require 'util'
Q = require 'q'
ScopedClient = require 'scoped-http-client'

class Client extends EventEmitter
  FAYE_URL: "https://push.groupme.com/faye"

  # states
  DISCONNECTED: 'disconnected'
  PENDING: 'pending'
  CONNECTED: 'connected'

  # GroupMe client.
  #
  # Events:
  #   'connected': []
  #   'disconnected': []
  #   'message': [message: Message]
  #   'unknown': [type: String, channel: String, data: Object]
  #   'error': [error: Error]
  #   'transport:up': [] Faye transport is online; informational only
  #   'transport:down': [] Faye transport is offline; informational only
  #   'backfill': [groupid: String] Emitted when the backfill for a given group is complete.
  #
  # Properties:
  #   @state: (String) 'disconnected', 'pending', or 'connected'
  #
  # Arguments:
  #   access_token: (String) Access token
  #   userid: (String) User ID to subscribe to
  #   groupids: (Array<String>) Group IDs to backfill
  #   redis: (Redis.Client; Optional) A Redis client object
  #   logger: (Log; Optional) A Log instance
  constructor: (@access_token, @userid, @groupids, @redis, @logger) ->
    @state = @DISCONNECTED
    @_http = ScopedClient.create 'https://api.groupme.com/v3'
                         .header 'Accept', 'application/json'
                         .header 'Content-Type', 'application/json'
                         .query 'token', @access_token

  # Connects to GroupMe and subscribes to the user channel.
  #
  # If the client is already pending or connected, nothing happens.
  # The state moves to @PENDING immediately.
  # When the connection succeeds, the state moves to @CONNECTED
  # and the user channel is subscribed.
  # If the subscription fails, the client disconnects, the state moves
  # to @DISCONNECTED, the 'error' event is emitted with the failure reason,
  # and the 'disconnected' event is emitted.
  #
  # Any group IDs provided to Client are backfilled using the last known message
  # stored in Redis. If Redis has no data for the group ID, nothing is backfilled.
  connect: ->
    return if @state != @DISCONNECTED
    @state = @PENDING

    # GroupMe appears to send pings every 30 seconds, so a 120 second timeout should be safe
    @_client = client = new Faye.Client(@FAYE_URL, {timeout: 120})
    @_client.then =>
      return unless @_client == client
      @state = @CONNECTED
      @emit 'connected'
    # Faye.Client doesn't ever get rejected.
    ['up', 'down'].forEach (status) =>
      event = "transport:#{status}"
      (client = @_client).on event, handler = =>
        if client != @_client
          client.removeListener event, handler
        else
          @emit event
    # it seems we need to add the 'ext' field ourselves in an extension
    # and catch any authentication errors on the handshake
    @_client.addExtension
      outgoing: (message, callback) =>
        # it seems we only want to use our access token on subscribe requests
        if message.channel == "/meta/subscribe"
          message.ext ||= {}
          message.ext.access_token = @access_token
          message.ext.timestamp = Math.floor(Date.now() / 1000)
        callback message
      incoming: (message, callback) =>
        if message.successful == false
          if message.error == "access token authentication failed"
            # this appears to be an authentication error. Make sure we don't retry.
            # note: I don't know if there are other error strings we need to handle
            message.advice = { reconnect: 'none' }
            # Faye doesn't seem to surface this error so we need to trigger a disconnect ourselves
            process.nextTick =>
              @state = @DISCONNECTED
              # don't bother trying to disconnect @_client, it will never finish connecting
              @_client = null
              @emit 'error', new Error(message.error)
              @emit 'disconnected'
        callback message

    @_client.on 'transport:up', =>
      @emit 'transport:up'
    @_client.on 'transport:down', =>
      @emit 'transport:down'

    @_client.subscribe(channel = "/user/#{@userid}", @_messageHandler(channel), @).then null, (reason) =>
      return unless @_client == client
      @_client.disconnect().then null, (reason) =>
        @emit 'error', reason
      @_client = null
      @state = @DISCONNECTED
      @emit 'error', reason
      @emit 'disconnected'

    # Backfill groups
    # We may receive messages from Faye before our backfill is complete.
    # We need to buffer them so the backfilled messages are emitted first.
    @_buffer = {}
    if @redis and Util.isArray(@groupids)
      @_buffer[groupid] = [] for groupid in @groupids
      Q.npost(@redis, 'mget', @_redisGroupKey(id) for id in @groupids).done (last_message_ids) =>
        @_debug "Redis MGET:", last_message_ids
        @groupids.forEach (groupid, i) =>
          messageid = last_message_ids[i]
          if messageid
            @_debug "Backfilling group", groupid
            deferred = Q.defer()
            @_http.scope("groups/#{groupid}/messages").query('since_id', messageid).get() (err, resp, body) =>
              if err then deferred.reject err
              else deferred.resolve [resp, body]
            promise = deferred.promise.then ([resp, body]) =>
              if resp.statusCode == 304
                return @_debug "Backfill for #{groupid} found no messages"
              try
                data = JSON.parse body
              catch e
                @emit 'error', new Error("GET /groups/#{groupid}/messages JSON error", e)
              if data.meta?.code == 304
                return @_debug "Backfill for #{groupid} found no messages"
              if Util.isArray(data.response?.messages)
                messages = data.response.messages
                @_debug "Backfill for #{groupid} found #{messages.length} messages"
                buffer = @_buffer[groupid]
                for msg in messages
                  try
                    message = new Message(channel, msg)
                  catch
                    @emit 'error', new Error("Malformed message", msg)
                    continue
                  message.backfill = true
                  buffer.push message
              else
                @_debug "Backfill for #{groupid} got malformed data:", data
            , (reason) =>
                @emit 'error', new Error("GET /groups/#{groupid}/messages error", reason)
          else
            @_debug "Skipping backfill for #{groupid}; no saved message id"
            promise = Q()
          promise.finally =>
            @_drainBuffer groupid
          .done()
      , (reason) =>
        @emit 'error', new Error("Redis MGET error", reason)
        @_drainBuffer groupid for groupid in @groupids
    else
      @_debug "Skipping backfill"

  # Disconnects from GroupMe.
  #
  # If the client is not currently connected, nothing happens.
  # Otherwise, the client disconnects, the state moves to @DISCONNECTED,
  # and the 'disconnected' event is emitted.
  # If the disconnect fails inside Faye, the 'error' event is emitted.
  #
  # Returns a promise. The promise is only resolved when Faye finishes the
  # disconnect, even though the receiver will have already emitted the
  # 'disconnected' event.
  disconnect: ->
    unless @_client
      return Q()
    # When it's connecting, we can't just call disconnect on @_client, Faye
    # seems to ignore that. Instead, we'll disconnect when the connection
    # succeeds, but otherwise throw away @_client immediately.
    unless promise = @_client.disconnect()
      client = @_client
      promise = client.then ->
        client.disconnect()
    promise.then null, (reason) =>
      @emit 'error', reason
    @_client = null
    @state = @DISCONNECTED
    @emit 'disconnected'
    Q promise

  # Sends a message to GroupMe.
  #
  # bot_id: (String, Required) The bot ID to post as.
  # text: (String, Required) The text to post.
  #
  # Returns a Promise.
  sendMessage: (bot_id, text) ->
    deferred = Q.defer()
    @_http.scope 'bots/post'
          .post(JSON.stringify {
            bot_id
            text
    }) (err, resp, body) =>
      return deferred.reject(err) if err
      # GroupMe documents this call as returning 201, but we should accept any 2xx
      return deferred.reject(new Error("Post http error", resp.statusCode)) unless 200 <= resp.statusCode <= 299
      deferred.resolve({response: resp, body})
    deferred.promise

  _messageHandler: (channel) -> (msg) ->
    switch msg.type
      when 'ping' then # ignore this
      when 'typing' then # why are we getting typing?
      when 'line.create'
        @emit 'error', new Error("Malformed message", msg) unless msg.subject
        try
          message = new Message(channel, msg.subject)
        catch
          return @emit 'error', new Error("Malformed message", msg)
        if buffer = @_buffer?[msg.subject.group_id]
          # We're still backfilling, queue up the message
          return buffer.push message
        @emit 'message', message
        if @redis
          Q.ninvoke(@redis, 'set', @_redisGroupKey(message.group_id), message.id).catch (reason) =>
            @emit 'error', new Error("Redis SET error", reason)
      else
        @emit 'unknown', msg.type, channel, msg

  _drainBuffer: (groupid) ->
    return unless @_buffer?[groupid]
    messages = @_buffer[groupid]
    @_debug "Draining buffer for group #{groupid}: #{messages.length} messages"
    delete @_buffer[groupid]
    messages.sort (a, b) ->
      switch
        when a.id < b.id then -1
        when a.id > b.id then 1
        else 0
    last_id = null
    for msg in messages
      if last_id == msg.id
        # duplicate message
        continue
      last_id = msg.id
      setImmediate (msg) =>
        @emit 'message', msg
      , msg
    setImmediate =>
      @emit 'backfill', groupid
    if last_id and @redis
      Q.ninvoke(@redis, 'set', @_redisGroupKey(groupid), last_id).catch (reason) =>
        @emit 'error', new Error("Redis SET error", reason)

  _debug: (message, args...) ->
    if @logger
      @logger.debug "[GroupMe]", Util.format(message, args...)

  _redisGroupKey: (groupid) ->
    "groupme:group:#{groupid}:messageid"

class Message
  # GroupMe message.
  #
  # channel: (String) The channel the message was sent to. Expected to be /user/<userid>
  # message: (Object) The message object from the API. All fields are copied into Message.
  #
  # Throws an exception if required fields are missing:
  # - @id
  # - @group_id
  # - @text
  # - unless @system is true:
  #   - @user_id
  #   - @name
  constructor: (channel, message) ->
    for own key, value of message
      @[key] = value
    @channel = channel
    required_keys = ['id', 'group_id', 'name']
    required_keys.concat ['name', 'user_id'] unless @system
    for key in required_keys
      throw new Error("Malformed Message", "Missing key #{key}") if not @[key]?

class Error extends global.Error
  # GroupMe error.
  #
  # @type: (String) Error type
  # @data: (Any, Optional) Extra data
  constructor: (@type, @data) ->
    @message = Util.format("[%s]", @type)
    if @data?
      if Util.isError(@data)
        @message += " #{@data.message}"
      else
        @message += " #{Util.inspect(@data)}"
    super @message
    Error.captureStackTrace @, @constructor

  @::name = "GroupMeError"

module.exports = { Client, Message, Error }
