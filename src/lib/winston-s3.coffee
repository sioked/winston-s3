knox = require 'knox'
winston = require 'winston'
fs = require 'fs'
uuid = require 'node-uuid'
findit = require 'findit'
path = require 'path'
temp = require 'temp'
fork = require('child_process').fork
MAXSHIP = 5
TempFile = (logFilePath, tempFlag) ->
  if tempFlag
    return temp.createWriteStream()
  return fs.createWriteStream path.join logFilePath, 's3logger_' + new Date().toISOString()
module.exports =
class winston.transports.S3 extends winston.Transport
  name: 's3'

  constructor: (opts={}) ->
    super

    @client = knox.createClient {
      key: opts.key
      secret: opts.secret
      bucket: opts.bucket
      region: opts.region or "us-east-1"
    }
    @bufferSize = 0
    @maxSize = opts.maxSize || 20 * 1024 * 1024
    @_id = opts.id || (require 'os').hostname()
    @_nested = opts.nested || false
    @_path = opts.path || path.resolve __dirname, 's3logs'
    @_temp = opts.temp || false
    @_debug = opts.debug || false
    @_headers = opts.headers || {}

    unless @_temp
      fs.mkdir path.resolve(@_path), 0o0770, (err) =>
        return if err.code == 'EEXIST' if err?
        console.log('Error creating temp dir', err) if err

  log: (level, msg='', meta, cb) ->
    cb null, true if @silent
    item = {}
    if @_nested
      item.meta = meta if meta?
    else
      item = meta if meta?
    item.s3_msg = msg
    item.s3_level = level
    item.s3_time = new Date().toISOString()
    item.s3_id = @_id

    item = JSON.stringify(item) + '\n'

    @open (newFileRequired) =>
      @bufferSize += item.length
      @_stream.write item
      this.emit "logged"
      cb null, true

  timeForNewLog: ->
    (@maxSize and @bufferSize >= @maxSize) and
      (@maxTime and @openedAt and new Date - @openedAt > @maxTime)

  open: (cb) ->
    if @opening
      cb true
    else if (!@_stream or @maxSize and @bufferSize >= @maxSize)
      @_createStream(cb)
      cb true
    else
      cb()

  shipIt: (logFilePath) ->
    @queueIt logFilePath

  queueIt: (logFilePath) ->
    @shipQueue = {} if @shipQueue == undefined
    return if @shipQueue[logFilePath]?
    @shipQueue[logFilePath] = logFilePath
    console.log "@shipQueue is #{JSON.stringify @shipQueue}" if @_debug
    @_shipNow()

  _shipNow: ->
    @shipping = 0 if !@shipping?
    return if @shipping >= MAXSHIP
    keys = Object.keys @shipQueue
    return if keys.length < 1
    @shipping++
    logFilePath = keys[0]
    delete @shipQueue[logFilePath]
    @client.putFile logFilePath, @_s3Path(), @_headers, (err, res) =>
      @shipping--
      @_shipNow()
      if err?
        @shipQueue[logFilePath] = logFilePath unless err.code is 'ENOENT'
        return console.log 'Error shipping file', err
      if res.statusCode != 200
        @shipQueue[logFilePath] = logFilePath
        return console.log "S3 error, code #{res.statusCode}"
      console.log res if @_debug
      fs.unlink logFilePath, (err) ->
        return console.log('Error unlinking file', err) if err

  _s3Path: ->
    d = new Date
    "/year=#{d.getUTCFullYear()}/month=#{d.getUTCMonth() + 1}/day=#{d.getUTCDate()}/#{d.toISOString()}_#{@_id}_#{uuid.v4().slice(0,8)}.json"

  checkUnshipped: ->
    unshippedFiles = findit.find path.resolve @_path
    unshippedFiles.on 'file', (logFilePath) =>
      do (logFilePath) =>
        return unless logFilePath.match 's3logger.+Z'
        console.log "Matched on #{logFilePath}" if @_debug
        if @_stream
          return if path.resolve(logFilePath) == path.resolve(@_stream.path)
        @shipIt logFilePath

  _createStream: ->
    @opening = true
    if @_stream
      stream = @_stream
      stream.end()
      stream.on 'close', =>
        @shipIt(stream.path)
      stream.on 'drain', ->
      stream.destroySoon()

    @bufferSize = 0
    @_stream = new TempFile @_path, @_temp
    @_path = path.dirname @_stream.path
    console.log "@_path is #{@_path}" if @_debug
    @checkUnshipped()
    @opening = false
    #
    # We need to listen for drain events when
    # write() returns false. This can make node
    # mad at times.
    #
    @_stream.setMaxListeners Infinity
    #
    # When the current stream has finished flushing
    # then we can be sure we have finished opening
    # and thus can emit the `open` event.
    #
    @once "flush", ->
      @opening = false
      @emit "open", @_stream.path

    #
    # Remark: It is possible that in the time it has taken to find the
    # next logfile to be written more data than `maxsize` has been buffered,
    # but for sensible limits (10s - 100s of MB) this seems unlikely in less
    # than one second.
    #
      @flush()
