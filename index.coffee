amqp = require "amqp"
nconf = require "nconf"
elma  = require("elma")(nconf)
domain = require "domain"
uuid = require "node-uuid"
bsync = require "bsync"

url = nconf.get("CLOUDAMQP_URL") or "amqp://brkoacph:UNIBQBLE1E-_t-6fFapavZaMN68sdRVU@tiger.cloudamqp.com/brkoacph" # default to circuithub-staging
conn = undefined
connectionReady = false

queues = {}
listeners = {}
jobs = {}
rainID = uuid.v4()





########################################
## SETUP / INITIALIZATION
########################################

###
  Jobs system initialization
###
rainmaker = (cbDone) =>
  @_connect (err) =>
    if err?
      cbDone err
      return
    foreman() #start job supervisor (runs asynchronously at 1sec intervals)
    @listenFor rainID, mailman, cbDone 

###
  jobTypes -- array of jobType; [{name:"conversion", worker: callback}, {..}]
###
cloud = (jobTypes, cbDone) =>
  #[1.] Connect to message server
  @_connect (err) =>
    if err?
      cbDone err
      return
    #[2.] Publish all jobs we can handle (listen to all queues for these jobs)
    workerFunctions = []
    for jobType in jobTypes
      workerFunctions.push bsync.parallel.apply listenTo jobType.name, jobType.worker
    bsync.parallel workerFunctions, (allErrors, allResults) =>
      if allErrors?
        cbDone allErrors
        return
      cbDone()

exports.init = {rainmaker: rainmaker, cloud: cloud}

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
  elma.info "rabbitConnecting", "Connecting to RabbitMQ..."
  conn = amqp.createConnection {heartbeat: 10, url: url} # create the connection
  conn.on "error", (err) ->
    elma.error "rabbitConnectedError", "RabbitMQ server at #{url} reports ERROR.", err
  conn.on "ready", (err) ->
    elma.info "rabbitConnected", "Connected to RabbitMQ!"
    if err?
      elma.error "rabbitConnectError", "Connection to RabbitMQ server at #{url} FAILED.", err
      cbConnected err
      return
    connectionReady = true
    cbConnected undefined



########################################
## RAINMAKER JOBS API (submit jobs)
########################################

###
  Assigns incoming messages to jobs awaiting a response
###
mailman = (message, headers, deliveryInfo) ->
  if not jobs[headers.job]?
    elma.warning "noSuchJobError","Message received for job #{}, but job doesn't exist."
    return  
  jobs[headers.job].cb undefined, message
  delete jobs[headers.job]

###
  Implements timeouts for jobs-in-progress
###
foreman = () ->
  for job of jobs    
    jobs[job].timeout = jobs[job].timeout - 1
    if jobs[job].timeout <= 0
      jobs[job].cb elma.error "jobTimeout", "A response to job #{job} was not received in time."
      delete jobs[job]
  process.setTimeout(foreman, 1000)

###
  Submit a job to the queue, but anticipate a response
  -- type: type of job (name of job queue)
  -- job: must be in this format {name: "jobName", data: {}, timeout: 30 } the job details (message body) <-- timeout (in seconds) is optional defaults to 30 seconds
  -- cbJobDone: callback when response received (error, data) format
###
exports.submitFor = (type, job, cbJobDone) =>
  if not connectionReady 
    cbJobDone elma.error "noRabbitError", "Not connected to #{url} yet!" 
    return
  #[1.] Inform Foreman Job Expected
  if jobs[job.name]?
    cbJobDone elma.error "jobAlreadyExistsError", "Job #{job.name} Already Pending"
    return
  job.timeout ?= 60
  jobs[job.name] = {cb: cbJobDone, timeout: job.timeout}
  #[2.] Submit Job
  conn.publish type, job, {
                            contentType: "application/json", 
                            headers: {
                              job: job.name, 
                              returnQueue: rainID
                            }
                          }

###
  Subscribe to incoming jobs in the queue (exclusively -- block others from listening)
  -- type: type of jobs to listen for (name of job queue)
  -- cbExecute: function to execute when a job is assigned --> function (message, headers, deliveryInfo)
  -- cbListening: callback after listening to queue has started --> function (err) 
###
exports.listenFor = (type, cbExecute, cbListening) =>
  _listen type, cbExecute, true, true, cbListening



########################################
## CLOUD JOBS API (receive and do jobs)
########################################

###
  Acknowledge the last job received of the specified type
  -- type: type of job you are ack'ing (you get only 1 job of any type at a time, but can subscribe to multiple types)
  -- cbAcknowledged: callback after ack is sent successfully
###
exports.acknowledge = (type, cbAcknowledged) =>
  if not connectionReady 
    cbAcknowledged elma.error "noRabbitError", "Not connected to #{url} yet!" 
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
  _listen type, cbExecute, false, false, cbListening
  
###
  Submit a job to the queue 
  (if the queue doesn't exist the job is lost silently)
  (Note: Synchronous Function)
  -- type: type of job (name of job queue)
  -- data: the job details (message body)
###
exports.submit = (type, data) =>
  if not connectionReady 
    cbSubmitted "Connection to #{url} not ready yet!" 
    return
  job = {
          typeResponse: undefined
          data: JSON.stringify(data)
        }
  conn.publish type, job, {contentType: "application/json", headers:{job: "job name", returnQueue: "testing1234"}} 



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
  _listen type, cbExecute, false, true, cbListening

###
  Implements listening behavior.
  -- Prevents subscribing to a queue multiple times
  -- Records the consumer-tag so you can unsubscribe
###
_listen = (type, cbExecute, exclusive, persist, cbListening) =>
  if not connectionReady 
    cbListening elma.error "noRabbitError", "Not connected to #{url} yet!" 
    return
  if not queues[type]?
    queue = conn.queue type, {autoDelete: persist}, () -> # create a queue (if not exist, sanity check otherwise)
      #save reference so we can send acknowledgements to this queue
      queues[type] = queue 
      # subscribe to the `type`-defined queue and listen for jobs one-at-a-time
      subscribeDomain = domain.create()
      subscribeDomain.on "error", (err) -> 
        cbListening err
      subscribeDomain.run () ->
        queue.subscribe({ack: true, prefetchCount: 1, exclusive: exclusive}, cbExecute).addCallback((ok) -> listeners[type] = ok.consumerTag)
      cbListening undefined
  else
    if not listeners[type]? #already listening?
      queue.subscribe({ack: true, prefetchCount: 1, exclusive: exclusive}, cbExecute).addCallback((ok) -> listeners[type] = ok.consumerTag) # subscribe to the `type`-defined queue and listen for jobs one-at-a-time
    cbListening undefined