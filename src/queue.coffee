{EventEmitter} = require 'events'
Q = require 'q'

class Queue extends EventEmitter
  # Queues up functions that return promises and runs each
  # function when the previous one finishes.
  #
  # Emits 'error' if any promise fails.
  constructor: ->
    @queue = []

  run: (f) ->
    @queue.push f
    if @queue.length == 1
      setImmediate =>
        @_runNext()

  _runNext: ->
    promise = Q @queue[0]()
    promise.catch (reason) =>
      @emit 'error', reason
    .finally =>
      @queue.shift()
      @_runNext() if @queue.length > 0
    .done()

module.exports = Queue
