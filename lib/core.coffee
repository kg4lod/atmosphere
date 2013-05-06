amqp = require "amqp"
_s = require "underscore.string"
nconf = require "nconf"
elma  = require("elma")(nconf)
uuid = require "node-uuid"
bsync = require "bsync"
domain = require "domain"



########################################
## STATE MANAGEMENT
########################################

url = nconf.get("CLOUDAMQP_URL") or "amqp://guest:guest@localhost:5672//" #default to localhost if no environment variable is set
_urlLogSafe = url.substring url.indexOf("@") #Safe to log this value (strip password out of url)
exports.urlLogSafe = _urlLogSafe

conn = undefined
connectionReady = false

queues = {}
listeners = {}



########################################
## IDENTIFICATION
########################################

_rainID = uuid.v4() #Unique ID of this process/machine
_roleID = undefined
exports.rainID = () ->
  return if _roleID? then _roleID else _rainID

###
  Format machine prefix
###
exports.setRole = (role) ->
  _roleID = _s.humanize role
  _roleID = _roleID.replace " ", "_"
  _roleID = _s.truncate _roleID, 8
  _roleID = _s.truncate _roleID, 7 if _roleID[7] is "_"
  _roleID = _roleID + "-" + _rainID
  return _roleID



########################################
## CONNECT
########################################

###
  Report whether the Job queueing system is ready for use (connected to RabbitMQ backing)
###
exports.ready = () ->
  return connectionReady

###
  Connect to specified RabbitMQ server, callback when done.
  -- This is done automatically at the first module loading
  -- However, this method is exposed in case, you want to explicitly wait it out and confirm valid connection in app start-up sequence
  -- Connection is enforced, so if connection doesn't exist, nothing else will work.
###
exports.connect = (cbConnected) ->
  if not conn?
    elma.info "rabbitConnecting", "Connecting to RabbitMQ..."
    conn = amqp.createConnection {heartbeat: 10, url: url} # create the connection
    conn.on "error", (err) ->
      elma.error "rabbitConnectedError", "RabbitMQ server at #{_urlLogSafe} reports ERROR.", err
    conn.on "ready", (err) ->
      elma.info "rabbitConnected", "Connected to RabbitMQ!"
      if err?
        elma.error "rabbitConnectError", "Connection to RabbitMQ server at #{_urlLogSafe} FAILED.", err
        cbConnected err
        return
      connectionReady = true
      cbConnected undefined
  else
    cbConnected undefined



########################################
## DELETE
########################################

###
  Force delete of a queue (for maintainence/dev use)
###
exports.delete = () ->
  #Unsubscribe any active listener
  if queues[typeResponse]?  
    #Delete Queue
    queues[typeResponse].destroy {ifEmpty: false, ifUnused: false}
    #Update global state
    queues[typeResponse] = undefined
    listeners[typeResponse] = undefined
    cbDone undefined
  else
    cbDone "Not currently aware of #{typeResponse}! You can't blind delete."



########################################
## PUBLISH (SUBMIT)
########################################

###
  Publish (RabbitMQ terminology) a message to the specified queue
  -- Asynchronous, but callback is ignored
###
exports.publish = (queueName, messageObject, headerObject) ->
  conn.publish queueName, JSON.stringify(messageObject), {contentType: "application/json", headers: headerObject} 



########################################
## SUBSCRIBE (LISTEN)
########################################

###
  Implements listening behavior.
  -- Prevents subscribing to a queue multiple times
  -- Records the consumer-tag so you can unsubscribe
###
exports.listen = (type, cbExecute, exclusive, persist, useAcks, cbListening) ->
  if not connectionReady 
    cbListening elma.error "noRabbitError", "Not connected to #{_urlLogSafe} yet!" 
    return
  if not queues[type]?
    queue = conn.queue type, {autoDelete: not persist}, () -> # create a queue (if not exist, sanity check otherwise)
      #save reference so we can send acknowledgements to this queue
      queues[type] = queue 
      # subscribe to the `type`-defined queue and listen for jobs one-at-a-time
      subscribeDomain = domain.create()
      subscribeDomain.on "error", (err) -> 
        cbListening err
      subscribeDomain.run () ->
        queue.subscribe({ack: useAcks, prefetchCount: 1, exclusive: exclusive}, cbExecute).addCallback((ok) -> listeners[type] = ok.consumerTag)
      cbListening undefined
  else
    if not listeners[type]? #already listening?
      queue.subscribe({ack: useAcks, prefetchCount: 1, exclusive: exclusive}, cbExecute).addCallback((ok) -> listeners[type] = ok.consumerTag) # subscribe to the `type`-defined queue and listen for jobs one-at-a-time
    cbListening undefined



########################################
## ACKNOWLEDGE
########################################

###
  Acknowledge the last job received of the specified type
  -- type: type of job you are ack'ing (you get only 1 job of any type at a time, but can subscribe to multiple types)
  -- cbAcknowledged: callback after ack is sent successfully
###
exports.acknowledge = (type, cbAcknowledged) =>
  if not connectionReady 
    cbAcknowledged elma.error "noRabbitError", "Not connected to #{_urlLogSafe} yet!" 
    return
  if not queues[type]?
    cbAcknowledged "Connection to queue for job type #{type} not available! Are you listening to this queue?"
    return
  queues[type].shift()
  cbAcknowledged undefined
