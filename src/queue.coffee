{EventEmitter} = require 'events'
Q = require 'q'

class Queue extends EventEmitter
  # Queues up functions that return promises and runs each
  # function when the previous one finishes.
  #
  # Emits 'error' if any promise fails.
  constructor: ->
    @queue = []

  throttle: (num, ms) ->
    if num > 0 && ms > 0
      @throttle_num = num
      @throttle_ms = ms
      @throttle_history = []
    else
      @throttle_num = @throttle_ms = @throttle_history = null

  run: (f) ->
    @queue.push f
    if @queue.length == 1
      setImmediate =>
        @_runNext()

  _runNext: ->
    if @throttle_history
      now = Date.now()
      cutoff = now - @throttle_ms
      @throttle_history = @throttle_history.filter (ms) ->
        ms > cutoff
      if @throttle_history.length >= @throttle_num
        oldest = @throttle_history[0]
        setTimeout oldest - cutoff, =>
          @_invokeNext()
      else
        @_invokeNext()
    else
      @_invokeNext()

  _invokeNext: ->
    if @throttle_history
      @throttle_history.push Date.now()
    promise = Q @queue[0]()
    promise.catch (reason) =>
      @emit 'error', reason
    .finally =>
      @queue.shift()
      @_runNext() if @queue.length > 0
    .done()

module.exports = Queue
