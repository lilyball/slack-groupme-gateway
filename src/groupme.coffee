GroupMe = require 'groupme'
{EventEmitter} = require 'events'
Util = require 'util'

class Client extends EventEmitter
  # GroupMe client.
  #
  # Events:
  #   'connected': []
  #   'pending': []
  #   'disconnected': []
  #   'message': [message: Message]
  #   'unknown': [type: String, data: Object]
  #   'error': [error: Error]
  #   'status': [...] Debug messages
  #
  # Arguments:
  #   access_token: (String)
  #   userid: (String)
  constructor: (access_token, userid) ->
    @_client = new GroupMe.IncomingStream(access_token, userid)

    ['connected', 'disconnected', 'pending', 'status'].forEach (event) =>
      @_client.on event, =>
        @emit event, arguments...

    @_client.on 'error', (err, payload) =>
      @emit 'error', new Error(err, payload)

    @_client.on 'message', (data) =>
      @handleMessage data

  connect: ->
    @_client.connect()

  disconnect: ->
    @_client.disconnect()

  handleMessage: (msg) ->
    { channel, data } = msg
    return unless channel == "/user/#{@_client.userid}"
    return @emit 'error', new Error("Malformed message", msg) if not channel? or not data?
    switch data.type
      when "ping" then # I don't know what these are for
      when "typing" then # ignore these
      when "line.create"
        { user_id, group_id, name, text, system } = data.subject
        return if system # don't emit system messages
        # ensure it has all the expected fields
        return @emit 'error', new Error("Malformed message", msg) if not (user_id? and group_id? and name? and text?)

        @emit 'message', new Message(channel, data.subject)
      else
        @emit 'unknown', data.type, msg

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
