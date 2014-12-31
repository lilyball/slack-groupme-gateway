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
