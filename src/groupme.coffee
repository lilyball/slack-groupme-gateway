{EventEmitter} = require 'events'
Faye = require 'faye'
Util = require 'util'

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
  #
  # Properties:
  #   @state: (String) 'disconnected', 'pending', or 'connected'
  #
  # Arguments:
  #   access_token: (String) Access token
  #   userid: (String) User ID to subscribe to
  constructor: (@access_token, @userid) ->
    @state = @DISCONNECTED

  # Connects to GroupMe and subscribes to the user channel.
  #
  # If the client is already pending or connected, nothing happens.
  # The state moves to @PENDING immediately.
  # When the connection succeeds, the state moves to @CONNECTED
  # and the user channel is subscribed.
  # If the subscription fails, the client disconnects, the state moves
  # to @DISCONNECTED, the 'error' event is emitted with the failure reason,
  # and the 'disconnected' event is emitted.
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

  # Disconnects from GroupMe.
  #
  # If the client is not currently connected, nothing happens.
  # Otherwise, the client disconnects, the state moves to @DISCONNECTED,
  # and the 'disconnected' event is emitted.
  # If the disconnect fails inside Faye, the 'error' event is emitted.
  disconnect: ->
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

  _messageHandler: (channel) -> (msg) ->
    switch msg.type
      when 'ping' then # ignore this
      when 'typing' then # why are we getting typing?
      when 'line.create'
        { user_id, group_id, name, text, system } = subject = msg.subject
        return if system # don't emit system messages (what are these?)
        # ensure it has all the expected fields
        return @emit 'error', new Error("Malformed message", msg) if not (user_id? and group_id? and name? and text?)

        @emit 'message', new Message(channel, subject)
      else
        @emit 'unknown', msg.type, channel, msg

class Message
  # GroupMe message.
  #
  # @channel: (String) The channel the message was sent to. Expected to be /user/<userid>
  # @user_id: (String) The user_id that sent the message.
  # @group_id: (String) The group_id the message was sent to.
  # @name: (String) The name of the user that sent the message.
  # @text: (String) The text of the message.
  # @avatar_url: (String, Optional) The URL of the sender's avatar.
  # @picture_url: (Optional) Unknown.
  # @attachments: (Optional) Unknown.
  constructor: (@channel, { @user_id, @group_id, @name, @text, @avatar_url, @picture_url, @attachments }) ->

class Error extends global.Error
  # GroupMe error.
  #
  # @type: (String) Error type
  # @data: (Any, Optional) Extra data
  constructor: (@type, @data) ->
    @message = Util.format("[%s]", @type)
    @message += " #{Util.inspect(@data)}" if @data?
    super @message
    Error.captureStackTrace @, @constructor

  @::name = "GroupMeError"

module.exports = { Client, Message, Error }
