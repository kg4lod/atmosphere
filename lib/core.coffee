_s                     = require "underscore.string"
uuid                   = require "node-uuid"
bsync                  = require "bsync"
domain                 = require "domain"
types                  = require "./types"

Firebase               = require "firebase"
FirebaseTokenGenerator = require "firebase-token-generator"

########################################
## STATE MANAGEMENT
########################################

exports.init = (role, roleType, _firebaseServerURL, _firebaseServerToken, cbInitialized) =>
  @setRole role, roleType
  @connect _firebaseServerURL, _firebaseServerToken, cbInitialized

exports.setFirebaseURL = (url) =>
  @firebaseServerURL = if url? then url else "https://atmosphere.firebaseio-demo.com/"
  @firebaseServerURL += "/" if not _s.endsWith @firebaseServerURL, "/"

exports.urlLogSafe = () =>
  @firebaseServerURL

exports.refs = () =>
  return @_ref

exports.initReferences = () =>
  @_ref = 
    rainDropsRef: new Firebase "#{@firebaseServerURL}atmosphere/rainDrops/"
    rainCloudsRef: new Firebase "#{@firebaseServerURL}atmosphere/rainClouds/"
    rainMakersRef: new Firebase "#{@firebaseServerURL}atmosphere/rainMakers/"
    rainGaugeRef: new Firebase "#{@firebaseServerURL}atmosphere/rainGauge/"
    skyRef: new Firebase "#{@firebaseServerURL}atmosphere/sky/"
    weatherRef: new Firebase "#{@firebaseServerURL}atmosphere/weatherPattern/"
    connectedRef: new Firebase "#{@firebaseServerURL}/.info/connected"
  switch exports.rainType()
    when "rainMaker"
      @_ref.thisTypeRef = @_ref.rainMakersRef
    when "rainCloud"
      @_ref.thisTypeRef = @_ref.rainCloudsRef
    else
      @_ref.thisTypeRef = @_ref.rainCloudsRef



connectionReady = false

queues = {}
listeners = {}



########################################
## IDENTIFICATION
########################################

_rainID   = uuid.v4() #Unique ID of this process/machine
_roleID   = undefined
_roleType = undefined #rainMaker or rainCloud

###
  ID of this machine
###
exports.rainID = () ->
  return if _roleID? then _roleID else _rainID

###
  Atmosphere role type of this machine
  -- "rainMaker", "rainCloud"
###
exports.rainType = () ->
  return if _roleType? then _roleType else "rainCloud"

###
  Format machine prefix
###
exports.setRole = (role, type) ->
  _roleType = type
  _roleID = _s.humanize role
  _roleID = _roleID.replace " ", "_"
  _roleID = _s.truncate _roleID, 8
  _roleID = _s.truncate _roleID, 7 if _roleID[7] is "_"
  _roleID = _roleID.replace "...", ""
  _roleID = _roleID + "-" + _rainID
  return _roleID

###
  Escape illegal Firebase characters from names
###
exports.escape = (input) ->
  return input.replace /[ .$\[\]#/]/g, "-"

exports.makeID = (queueName, jobName) =>
  queueName = @escape queueName
  jobName = @escape jobName
  candidate = "#{_s.dasherize queueName}_#{jobName}_#{uuid.v4()}"
  candidate = candidate.toLowerCase()
  return candidate

###
  Extracts rainBucket from rainDropID
  -- fallback when not specified
###
exports.getBucket = (rainDropID) ->
  candidate = rainDropID.match(/^[A-Za-z0-9-]+_/)?[0]
  if candidate?
    candidate = _s.dasherize(candidate[0...candidate.length-1]).toLowerCase()
  return candidate



########################################
## CONNECT
########################################

###
  Report whether the Job queueing system is ready for use
###
exports.ready = () ->
  return connectionReady

###
  Connect to specified Firebase
  -- Also handles re-connection and re-authentication (expired token)
  -- Connection is enforced, so if connection doesn't exist, nothing else will work.
###
exports.connect = (_firebaseServerURL, @firebaseServerToken, cbConnected) =>
  @setFirebaseURL _firebaseServerURL
  if connectionReady
    #--Already connected
    cbConnected undefined
    return

  console.log "[atmosphere]", "ICONNECT", "Connecting to Firebase at #{@firebaseServerURL}..."
  dataRef = new Firebase @firebaseServerURL  

  #--Authentication is not required for dev mode
  if @firebaseServerURL.toLowerCase().indexOf("-demo") isnt -1 #Skip authenication if using Firebase demo mode
    console.log "[atmosphere]", "NOAUTH", "Running in demo mode (skipping authenication)"
    connectionReady = true
    @initReferences()
    cbConnected undefined
    return

  #--Authenticate in production mode
  @firebaseServerToken = @generateServerToken()
  dataRef.auth @firebaseServerToken, (error) =>
    if error?
      connectionReady = false
      if error.code is "EXPIRED_TOKEN"
        console.log "[atmosphere]", "ETOKEN", "Expired Token. This should never happen..."
        #TODO: Reconnect on loss of authentication -- logic goes here
      else
        console.log "[atmosphere]", "EAUTH", "Login failed!", error
    else
      connectionReady = true 
      @initReferences()
      console.log "[atmosphere]", "SCONNECT", "Connected to Firebase!"      
    cbConnected error

###
  Generate Access Token for Server
  -- Full access! Be careful!
  -- For future work (idle code path)
###
exports.generateServerToken = () =>
  return @firebaseServerToken



########################################
## PUBLISH (SUBMIT)
########################################

###
  Publish (RabbitMQ terminology) a message to the specified queue
  -- Asynchronous, but callback is ignored
  -- If the jobID (rainDropID) is defined in headerObject, it will be used, otherwise new jobID will be created
###
exports.publish = (queueName, messageObject, headerObject) =>
  rainDrop = 
    job: headerObject.job
    data: messageObject.data
    next: 
      callback: headerObject.callback
      callbackTo: headerObject.returnQueue         
      chain: messageObject.next
  newRainDropRef = undefined
  if headerObject.job.id?
    # If chain mode, then we already have the rainDropID
    newRainDropRef = @_ref.rainDropsRef.child "todo/#{queueName}/#{headerObject.job.id}"
  else
    # Generate a reference to a new location with push
    newRainDropID = @makeID queueName, headerObject.job.name
    newRainDropRef = @_ref.rainDropsRef.child("todo/#{queueName}/#{newRainDropID}")
  # Set some data to the generated location
  newRainDropRef.set rainDrop, (error) ->
    if error?
      console.log "[atmosphere]", "ESUBMIT", "Error occured during submit:", error, rainDrop
      return
  # Get the name generated by push (e.g. new job ID)
  return newRainDropRef.name()

###
  Submit a job
  -- Enforces job structure to make future refactor work safer  
###
exports.submit = types.fn (-> [ 
  @String()
  @Object {data: @Object(), next: @Array()}
  @Object {job: @Object({name: @String(), type: @String()}), returnQueue: @String(), callback: @Boolean()}
  ]),  
  (type, payload, headers) => 
    return exports.publish type, payload, headers



########################################
## LOG
########################################

###
  Instruct Firebase to insert the server's timestamp
  -- Use as a value into .set, .update Firebase commands
###
exports.now = () ->
  return Firebase.ServerValue.TIMESTAMP 

###
  Generate log format object
###
exports.log = (rainDropID, event, where) =>
  logEntry = 
    what: event
    when: @now()
    who: @rainID()    
    where: if where? then where else null
  @_ref.rainDropsRef.child("#{rainDropID}/log").push logEntry
  delete logEntry.what
  return logEntry

