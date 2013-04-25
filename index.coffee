_s = require "underscore.string"
amqp = require "amqp"
nconf = require "nconf"
elma  = require("elma")(nconf)
uuid = require "node-uuid"
bsync = require "bsync"
domain = require "domain"

url = nconf.get("CLOUDAMQP_URL") or "amqp://guest:guest@localhost:5672//" #default to localhost if no environment variable is set
urlLogSafe = url.substring url.indexOf("@") #Safe to log this value (strip password out of url)
conn = undefined
connectionReady = false

queues = {}
listeners = {}
jobs = {}
jobWorkers = {}
rpcWorkers = {} #When using the simple router, stores the actual worker functions the router should invoke

rainID = uuid.v4() #Unique ID of this process/machine

currentJob = {}

perfMon =
  complete: 0
  running: 0
  startTime: undefined #time stamp exited initialization
  idleAt: undefined #last job completed at (timestamp)


#Set ENV var CLOUD_ID on atmosphere.raincloud servers

###
1. worker functions in rain cloud apps get called like this:
  your_function(ticket, jobData)
2. When done, call thunder and give the ticket back along with any response data (must serialize to JSON)...
  atmosphere.thunder ticket, responseData
###

########################################
## SETUP / INITIALIZATION
########################################

###
  Format machine prefix
###
getRole = (role) ->
  role = _s.humanize role
  role = role.replace " ", "_"
  role = _s.truncate role, 8
  role = _s.truncate role, 7 if role[7] is "_"
  role = role + "-"
  return role

###
  Jobs system initialization
  --role: String. 8 character (max) description of this rainMaker (example: "app", "eda", "worker", etc...)
###
rainMaker = (role, cbDone) =>
  rainID = getRole(role) + rainID
  @_connect (err) =>
    if err?
      cbDone err
      return
    foreman() #start job supervisor (runs asynchronously at 1sec intervals)
    @listenFor rainID, mailman, cbDone 

###
  jobTypes -- object with jobType values and worker function callbacks as keys; { jobType1: cbDoJobType1, jobType2: .. }
  -- Safe to call this function multiple times. It adds additional job types. If exists, jobType is ignored during update.
  --role: String. 8 character (max) description of this rainCloud (example: "app", "eda", "worker", etc...)
###
rainCloud = (role, jobTypes, cbDone) =>
  #[0.] Initialize
  rainID = getRole(role) + rainID
  #[1.] Connect to message server
  @_connect (err) =>
    if err?
      cbDone err
      return
    #[2.] Publish all jobs we can handle (listen to all queues for these jobs)
    workerFunctions = []    
    for jobType of jobTypes
      if not jobWorkers[jobType]?
        jobWorkers[jobType] = jobTypes[jobType]
        workerFunctions.push bsync.apply @listenTo, jobType, lightning
    bsync.parallel workerFunctions, (allErrors, allResults) =>
      if allErrors?
        cbDone allErrors
        return
      #Allow clouds to issue jobs to other clouds
      foreman() #start job supervisor (runs asynchronously at 1sec intervals)
      perfMon.startTime = new Date().getTime() #log boot time
      @listenFor rainID, mailman, cbDone        

exports.init = {rainMaker: rainMaker, rainCloud: rainCloud}

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
exports._connect = (cbConnected) ->
  if not conn?
    elma.info "rabbitConnecting", "Connecting to RabbitMQ..."
    conn = amqp.createConnection {heartbeat: 10, url: url} # create the connection
    conn.on "error", (err) ->
      elma.error "rabbitConnectedError", "RabbitMQ server at #{urlLogSafe} reports ERROR.", err
    conn.on "ready", (err) ->
      elma.info "rabbitConnected", "Connected to RabbitMQ!"
      if err?
        elma.error "rabbitConnectError", "Connection to RabbitMQ server at #{urlLogSafe} FAILED.", err
        cbConnected err
        return
      connectionReady = true
      cbConnected undefined
  else
    cbConnected undefined


########################################
## RAINMAKER JOBS (submit jobs)
########################################

###
  Assigns incoming messages to jobs awaiting a response
###
mailman = (message, headers, deliveryInfo) ->
  if not jobs["#{headers.type}-#{headers.job.name}"]?
    elma.warning "noSuchJobError","Message received for job #{headers.type}-#{headers.job.name}, but job doesn't exist."
    return  
  if not jobs["#{headers.type}-#{headers.job.name}"].id is headers.job.id
    elma.warning "expiredJobError", "Received response for expired job #{headers.type}-#{headers.job.name} #{headers.job.id}."
    return    
  callback = jobs["#{headers.type}-#{headers.job.name}"].cb #cache function pointer
  delete jobs["#{headers.type}-#{headers.job.name}"] #mark job as completed
  process.nextTick () -> #release stack frames/memory
    callback message.errors, message.data

###
  Implements timeouts for jobs-in-progress
###
foreman = () ->
  for job of jobs    
    jobs[job].timeout = jobs[job].timeout - 1
    if jobs[job].timeout <= 0
      callback = jobs[job].cb #necessary to prevent loss of function pointer
      delete jobs[job] #mark job as completed
      process.nextTick () -> #release stack frames/memory
        callback elma.error "jobTimeout", "A response to job #{job} was not received in time."
  setTimeout(foreman, 1000)

###
  Submit a job to the queue, but anticipate a response
  -- type: type of job (name of job queue)
  -- job: must be in this format {name: "jobName", data: {}, timeout: 30 } the job details (message body) <-- timeout (in seconds) is optional defaults to 30 seconds
  -- cbJobDone: callback when response received (error, data) format
###
exports.submitFor = (type, job, cbJobDone) =>
  if not connectionReady 
    cbJobDone elma.error "noRabbitError", "Not connected to #{urlLogSafe} yet!" 
    return
  #[1.] Inform Foreman Job Expected
  if jobs["#{type}-#{job.name}"]?
    cbJobDone elma.error "jobAlreadyExistsError", "Job #{type}-#{job.name} Already Pending"
    return
  job.timeout ?= 60
  job.id = uuid.v4()
  jobs["#{type}-#{job.name}"] = {id: job.id, cb: cbJobDone, timeout: job.timeout}
  #[2.] Submit Job
  job.data ?= {} #default value if unspecified
  conn.publish type, JSON.stringify(job.data), {
                            contentType: "application/json", 
                            headers: {
                              job: {name: job.name, id: job.id}
                              returnQueue: rainID
                            }
                          }

###
  Subscribe to incoming jobs in the queue (exclusively -- block others from listening)
  >> Used for private response queues (responses to submitted jobs)
  -- type: type of jobs to listen for (name of job queue)
  -- cbExecute: function to execute when a job is assigned --> function (message, headers, deliveryInfo)
  -- cbListening: callback after listening to queue has started --> function (err) 
###
exports.listenFor = (type, cbExecute, cbListening) =>
  _listen type, cbExecute, true, false, false, cbListening

###
  The number of active jobs (submitted, but not timed-out or returned yet)
###
exports.countFor = () ->
  return Object.keys(jobs).length


########################################
## BUCKET JOBS (receive and log)
########################################

###
  Listen for messages
  -- Queue persists
  -- Non-exclusive access
  -- Auto-ack (e.g. stream) incoming messages
###
exports.listenWith = (type, cbExecute, cbListening) =>
  _listen type, cbExecute, false, true, false, cbListening

###
  Submit a task (status message) to the queue (no response)
  -- type: type of task (name of task queue)
  -- ticket: Job Ticket. Must be in this format {job: {name: "taskName", id:"uuid"}, type: "taskQueueName"} 
  -- task: Message and data. Format: {message: "", level: "warning", data: {} }
  -- cbSubmitted: callback when submission complete (err, data) format
###
exports.submitWith = (type, ticket, task, cbSubmitted) =>
  if not connectionReady 
    cbSubmitted [elma.error("noRabbitError", "Not connected to #{urlLogSafe} yet!")]
    return
  #[1.] Submit Task Message
  conn.publish type, JSON.stringify(task), {
                            contentType: "application/json"
                            headers: 
                              task: ticket
                              fromID: rainID
                            }
  cbSubmitted()



########################################
## CLOUD JOBS (receive and do jobs)
########################################

###
  Receives work to do messages on cloud and dispatches
  Messages are dispatched to the callback function this way:
    function(ticket, data) ->
###
lightning = (message, headers, deliveryInfo) =>
  if currentJob[deliveryInfo.queue]?
    #PANIC! BAD STATE! We got a new job, but haven't completed previous job yet!
    elma.error "duplicateJobAssigned", "Two jobs were assigned to atmosphere.cloud server at once! SHOULD NOT HAPPEN.", currentJob, deliveryInfo, headers, message
    return
  currentJob[deliveryInfo.queue] = {
    type: deliveryInfo.queue
    job: headers.job # job = {name:, id:}
    data: message
    returnQueue: headers.returnQueue
  }
  jobWorkers[deliveryInfo.queue]({type: deliveryInfo.queue, job: headers.job}, currentJob[deliveryInfo.queue].data)

###
  Reports completed job on a Rain Cloud
  -- ticket: {type: "", job: {name: "", id: "uuid"} }
  -- message: the job response data (message body)
###
exports.doneWith = (ticket, errors, data) =>
  if not connectionReady 
    #TODO: HANDLE THIS BETTER
    elma.error "noRabbitError", "Not connected to #{urlLogSafe} yet!" 
    return
  if not currentJob[ticket.type]?
    #TODO: HANDLE THIS BETTER
    elma.error "noTicketWaiting", "Ticket for #{ticket.type} has no current job pending!" 
    return
  header = {job: currentJob[ticket.type].job, type: currentJob[ticket.type].type, rainCloudID: rainID}
  message = 
    errors: errors
    data: data
  conn.publish currentJob[ticket.type].returnQueue, JSON.stringify(message), {contentType: "application/json", headers: header} 
  theJob = currentJob[ticket.type]
  delete currentJob[ticket.type] #done with current job, update state
  process.nextTick () ->
    exports.acknowledge theJob.type, (err) ->
      if err?
        #TODO: HANDLE THIS BETTER
        elma.error "cantAckError", "Could not send ACK", theJob, err 
        return
      perfMon.complete++
      perfMon.idleAt = new Date().getTime()

###
  report RainCloud performance statistics
###
exports.count = () ->
  stats = 
    running: Object.keys(currentJob).length
    complete: perfMon.complete
    uptime: ((new Date().getTime() - perfMon.startTime)/1000/60).toFixed(2) #in minutes
    idleTime: new Date().getTime() - perfMon.idleAt #milliseconds since last job completed
  return stats

###
  Simple direct jobs router. Fastest/easiest way to get RPC running in your app.
  --Takes in job list and wraps your function in (ticket, data) -> doneWith(..) behavior
###
exports.router = (taskName, functionName) ->
  rpcWorkers[taskName] = functionName #save work function
  return _router

_router = (ticket, data) ->
  elma.info "[JOB] #{ticket.type}-#{ticket.job.name}-#{ticket.step}"
  ticket.data = data if data? #add job data to ticket
  #Execute (invoke work function)
  rpcWorkers[ticket.type] ticket, (errors, results) ->
    # Release lower stack frames
    process.nextTick () ->
      exports.doneWith ticket, errors, results




###
  Acknowledge the last job received of the specified type
  -- type: type of job you are ack'ing (you get only 1 job of any type at a time, but can subscribe to multiple types)
  -- cbAcknowledged: callback after ack is sent successfully
###
exports.acknowledge = (type, cbAcknowledged) =>
  if not connectionReady 
    cbAcknowledged elma.error "noRabbitError", "Not connected to #{urlLogSafe} yet!" 
    return
  if not queues[type]?
    cbAcknowledged "Connection to queue for job type #{type} not available! Are you listening to this queue?"
    return
  queues[type].shift()
  cbAcknowledged undefined

###
  Subscribe to persistent incoming jobs in the queue (non-exclusively)
  (Queue will continue to exist even if no-one is listening)
  -- type: type of jobs to listen for (name of job queue)
  -- cbExecute: function to execute when a job is assigned --> function (message, headers, deliveryInfo)
  -- cbListening: callback after listening to queue has started --> function (err)  
###
exports.listenTo = (type, cbExecute, cbListening) =>
  _listen type, cbExecute, false, true, true, cbListening



########################################
## INTERNAL / UTILITY
########################################

###
  Force delete of a queue (for maintainence/dev future use)
###
_delete = () =>
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

###
  Subscribe to incoming jobs in the queue (non-exclusively)
  (Queue dies if no one listening)
  -- type: type of jobs to listen for (name of job queue)
  -- cbExecute: function to execute when a job is assigned --> function (message, headers, deliveryInfo)
  -- cbListening: callback after listening to queue has started --> function (err) 
###
exports.listen = (type, cbExecute, cbListening) =>
  _listen type, cbExecute, false, false, true, cbListening

###
  Implements listening behavior.
  -- Prevents subscribing to a queue multiple times
  -- Records the consumer-tag so you can unsubscribe
###
_listen = (type, cbExecute, exclusive, persist, useAcks, cbListening) =>
  if not connectionReady 
    cbListening elma.error "noRabbitError", "Not connected to #{urlLogSafe} yet!" 
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
