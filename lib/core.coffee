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

exports.init = (role, url, @serverToken, cbInitialized) =>
  @firebaseServerURL = if url? then url else "https://atmosphere.firebaseio-demo.com/"  
  @firebaseServerURL += "/" if not _s.endsWith @firebaseServerURL, "/"
  @setRole role
  @connect cbInitialized

exports.refs = () =>
  return @_ref

exports.initReferences = () =>
  @_ref = 
    rainDropsRef: new Firebase "#{@firebaseServerURL}atmosphere/rainDrops/"
    rainCloudsRef: new Firebase "#{@firebaseServerURL}atmosphere/rainClouds/"
    rainMakersRef: new Firebase "#{@firebaseServerURL}atmosphere/rainMakers/"

exports.urlLogSafe = @url

connectionReady = false

queues = {}
listeners = {}



########################################
## IDENTIFICATION
########################################

_rainID = uuid.v4() #Unique ID of this process/machine
_roleID = undefined

###
  ID of this machine
###
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
  _roleID = _roleID.replace "...", ""
  _roleID = _roleID + "-" + _rainID
  return _roleID



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
exports.connect = (cbConnected) =>
  if connectionReady
    #--Already connected
    cbConnected undefined
    return
  dataRef = new Firebase @firebaseServerURL  
  
  #--Authentication is not required for dev mode
  if @firebaseServerURL.toLowerCase().indexOf("-demo") isnt -1 #Skip authenication if using Firebase demo mode
    console.log "[atmosphere]", "NOAUTH", "Running in demo mode (skipping authenication)"
    connectionReady = true
    @initReferences()
    cbConnected undefined
    return

  #--Authenticate in production mode
  firebaseServerToken = @generateServerToken()
  dataRef.auth firebaseServerToken, (error) =>
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
###
exports.generateServerToken = () =>
  return @serverToken



########################################
## DELETE
########################################

###
  Force delete of a queue (for maintainence/dev use)
###
exports.delete = (queueName) ->
  @rainDropsRef.child(queueName).remove()



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
    newRainDropRef = @_ref.rainDropsRef.child "#{queueName}/#{headerObject.job.id}"
  else
    # Generate a reference to a new location with push
    newRainDropID = @makeID queueName, headerObject.job.name
    newRainDropRef = @_ref.rainDropsRef.child("#{queueName}/#{newRainDropID}")
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

exports.makeID = (queueName, jobName) ->
  candidate = "#{_s.dasherize queueName}_#{jobName}"
  candidate = candidate.toLowerCase()
  return candidate
