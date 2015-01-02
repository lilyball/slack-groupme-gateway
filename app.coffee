{Bot} = require './src/bot'
Faye = require 'faye'
Log = require 'log'

do ->
  if level = process.env.FAYE_LOG_LEVEL
    logger = new Log(level)
    Faye.logger =
      fatal: (msg) => logger.critical msg
      error: (msg) => logger.error msg
      warn:  (msg) => logger.warning msg
      info:  (msg) => logger.info msg
      debug: (msg) => logger.debug msg

bot = new Bot
bot.run()

terminate = (reason) ->
  console.log 'Closing [%s]...', reason
  bot.stop().timeout(5000).then ->
    process.exit()
  , (reason) ->
    console.log reason
    process.exit 1
sigint = ->
  process.removeListener 'SIGTERM', sigterm
  terminate 'SIGINT'
sigterm = ->
  process.removeListener 'SIGINT', sigint
  terminate 'SIGTERM'
process.once 'SIGINT', sigint
process.once 'SIGTERM', sigterm
