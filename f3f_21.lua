-- ###############################################################################################
-- # F3F Tool for JETI DC/DS transmitters 
-- #
-- # Copyright (c) 2023, 2024 Frank Schreiber
-- #
-- #    This program is free software: you can redistribute it and/or modify
-- #    it under the terms of the GNU General Public License as published by
-- #    the Free Software Foundation, either version 3 of the License, or
-- #    (at your option) any later version.
-- #    
-- #    This program is distributed in the hope that it will be useful,
-- #    but WITHOUT ANY WARRANTY; without even the implied warranty of
-- #    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- #    GNU General Public License for more details.
-- #    
-- #    You should have received a copy of the GNU General Public License
-- #    along with this program.  If not, see <http://www.gnu.org/licenses/>.
-- #
-- ###############################################################################################
-- ###############################################################################################
-- # General approach
-- #
-- # For course setup 3 points on the course (or A-Line in case of F3B) are scanned by gps.
-- # One point is defined as starting point, the others are used to determine the
-- # course bearing to north.
-- # 
-- # During the flight the distance between ths starting point and the current 
-- # GPS position of the model is permanently calculated. Also based on this position
-- # the angle between the course and the flight position is determined. 
-- # In order to calculate the course rectangle, this angle is used to shorten the
-- # distance by multiplication with it's cosinus, so the resulting value represents
-- # the distance flown directly in course direction.
-- # When this distance meets half of the course length (f3f: 50m) the model hits the
-- # turn line anywhere.
-- #
-- # In order to handle gps- and telemetry latency a speed-related compensation is done.
-- # Depending on the current speed and flight direction a offset is calculated and added
-- # to the flight distance, so the turn signal will be triggered earlier.
-- # The setting for the amount of compensation was determined empirically, so there is no 
-- # theoretical approach for this value. Currently the compensation is simply linear to
-- # the speed.
-- #
-- # To realize this approach for the first course entry it must be turned over, so the
-- # flight distance is shortened to achieve a earlier signal. So there are two offsets
-- # calculated, one for the competition run and one for the first fly in. To give the model 
-- # always a defined inside/outside status the fly-in offset is also used for the first fly-out.
-- # Because this offset works in the opposite direction it increases the distance to the 
-- # fly out line (instead of decreasing, how it should be for fly-out), so the fly-out may
-- # appear 10m or 20m behind the real fly out line, depending on the speed.
-- # This is kind of a messy effect, but necessary to allow a precise detection of the fly in.
-- #
-- ###############################################################################################
-- ###############################################################################################
-- # Further notices:
-- #
-- # Jeti-Gen1 Support
-- # This program version is not suitable for Jeti Gen1-transmitters (with monochrome diaplay)
-- # For F3F / F3B training with an old transmitter you can use Version 1.x of this software.
-- #
-- # ---------------------------------------------------------------------------------------------
-- # F3B-Mode
-- # In F3B-Mode things are almost handled the same, position and angles are calculated
-- # related to the middle of the course. For convience the course-setup can be done
-- # along the A-Lane and the center point is calculated automatically.
-- #
-- # ---------------------------------------------------------------------------------------------
-- # External course modification
-- # There are some variables provided to support changing a course from an external app
-- # (maybe a course database). A corresponding database app is still experimental and
-- # not published.
-- #
-- ###############################################################################################


local appName = "F3F Tool"
local appVersion = "2.1"

local dataDirRel = "f3fTool-21"        -- data dir (relative path)
local dataDir = "Apps/" .. dataDirRel   -- data dir (abs. path)

-- ===============================================================================================
-- ===============================================================================================
-- ========== Global Variables                                                          ==========
-- ===============================================================================================
-- ===============================================================================================

-- global indicator for external course modification, allows to alter the course by an external tool 
f3fTool_extCourseChange = false

local globalVar = {
   direction= { UNDEF=0, LEFT=1, RIGHT=2 },
   errorStatus = 0,                   -- error status: 0: ok
   resource,                          -- multi language support (only audio)
   lng                                -- language (de/en)
}

local errorTable = {
  {"Sensors", "not", "configured"},                        -- 1
  {"Sensors", "not", "active"},                            -- 2
  {"Speedsensor", "not", "active"},                        -- 3
  {"Slope", "not", "configured"},                          -- 4 
  {"waiting", "for", "GPS-ready"},                         -- 5
  {"F3F-Tool V. " .. appVersion , "", "not for Gen1 TX"},  -- 6
  {"No", "Startpoint", "defined"}                          -- 7
}

-- Object pointer
local f3fRun = nil
local gpsSensor = nil
local basicCfg = nil
local transmitter = nil
local slope = nil
local slopeManager = nil
local display = nil

-- ===============================================================================================
-- ===============================================================================================
-- ========== Helper functions                                                          ==========
-- ===============================================================================================
-- ===============================================================================================

local function handleError ( errMsg )
   print ( "ERROR: " .. errMsg )
   system.playBeep (2, 500, 500)
end

--------------------------------------------------------------------------------------------
local function setLanguage()
   globalVar.lng = system.getLocale();
  
   local file = io.readall(dataDir .. "/audio-" ..globalVar.lng.. ".jsn")
   if (not file) then
      print ("language: '" .. globalVar.lng .. "' not supported")
      globalVar.lng = 'en'
      file = io.readall(dataDir .. "/audio-" ..globalVar.lng.. ".jsn")
   end   

   if( file ) then
      globalVar.resource = json.decode(file)
   else
      handleError ("audio config file not found")
   end
end

--------------------------------------------------------------------------------------------
local function writeToFile (dir, file, data, append)
  
  if ( dir ~= "" ) then dir = dir.."/" end
  local fSpec = dir..file
    
  local mode 
  if (append) then mode = "a" else mode = "w" end
  
  local f = io.open ( fSpec, mode )
	   
  if ( not f ) then		  
      io.mkdir (dir)
      f = io.open ( fSpec, mode )
    
      if ( not f) then
        handleError ("error writing file: " .. fSpec)
      end
  end

  if ( f ) then
    io.write(f, data, "\n")
    io.close ( f )
  end
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: f3fRun                                                            ==========
-- ========== contains the necessary logic for the run                                  ==========
-- ===============================================================================================
-- ===============================================================================================

f3fRun = {
  status = { INIT=1, ON_HOLD=2, STARTPHASE=3, TIMEOUT=4, F3F_RUN=5 },

  curPosition = nil,             -- current position of model
  curDist = nil,                 -- current distance from home position
  curBearing = nil,              -- current angle from slope
  curDir = nil,                  -- current position on left/right side from home
  nextTurnDir = nil,             -- side of expected next turn
  curSpeed = nil,                -- current speed (given from sensor)
  curHeading = nil,              -- current heading (flight direction)
  absCosHeading = nil,           -- cosinus heading (abs: always positive)

  -- for calculation of heading and smoothening of cos value
  lastLat = nil,                 -- last position
  lastLon = nil,
  prevCos_1 = nil,               -- last cosinus values
  prevCos_2 = nil,

  -- 'offsets' and 'inside-flags' for launch phase and f3f run.
  -- the values are always calculated independently from the current 
  -- f3f-status. So we know where we are if a status change occurs
  -- (from launch phase to f3f run or in case of reset from f3f run to launch phase)
  -- the values can differ, because the considered offsets work in opposite directions.

  launchPhaseData = { offset=0, insideFlag=0 },
  f3fRunData = { offset=0, insideFlag=0 },
  
  -- other stuff
  curStatus = nil,
  rounds = 0,
  
  launchTime = 0,                 -- time of launch, 30 seconds started
  countdownTime = 0,              -- countdown from launch (F3F) or tow hook release (F3B) to fly in
  remainingCountdown = 0,         -- remaining countdown for start time
  halfDistance = 0,               -- half length of the course, depending on f3f / f3b

  f3fStartTime = 0,               -- start time of f3f-run
  flightTime = 0,
  
  timerStartSpeed = -1,           -- timer for speed-measuring 1,5 sec. after start of f3f-run
}

function f3fRun:isStatus ( status ) return self.curStatus == status end

--------------------------------------------------------------------------------------------
function f3fRun:init ()
  -- initial status
  self.curStatus = self.status.INIT
  self.curDir = globalVar.direction.UNDEF
  self.nextTurnDir = globalVar.direction.UNDEF
  
  if slope.mode == 2 then                     -- F3B
    self.halfDistance = basicCfg.f3bDistance / 2
	
    if ( basicCfg.f3bMode == 1 ) then             -- speed
      self.countdownTime = 60
    elseif ( basicCfg.f3bMode == 2 ) then         -- distance
      self.countdownTime = 0
    end
	
  else                                             -- F3F
    self.countdownTime = 30   
    self.halfDistance = basicCfg.f3fDistance / 2
  end
end

--------------------------------------------------------------------------------------------
function f3fRun:setNextTurnDir ()

  -- set side of next turn
  if ( self.curDir == globalVar.direction.LEFT ) then
    self.nextTurnDir = globalVar.direction.RIGHT
  elseif ( f3fRun.curDir == globalVar.direction.RIGHT ) then
    self.nextTurnDir = globalVar.direction.LEFT
  end
end

--------------------------------------------------------------------------------------------
-- launch: start button was pressed

function f3fRun:launch ()
  
  -- slope not defined? ?
  if ( globalVar.errorStatus == 4 ) then
     -- cancel - beep
     system.playBeep (2, 1000, 200)
     return
  end
  
  -- check, if sensors are active
  globalVar.errorStatus = 0
  gpsSensor:getCurPosition ()
  if ( globalVar.errorStatus ~= 0 ) then
     -- cancel - beep
     system.playBeep (2, 1000, 200)
     return
  end
  
  -- start launch phase
  self.curStatus = self.status.STARTPHASE
  self.rounds = 0

  self.launchTime = system.getTimeCounter()
  self.remainingCountdown = self.countdownTime

  transmitter:playAudioFile ( globalVar.resource.audioStart, AUDIO_IMMEDIATE )
  
  -- in F3F and F3B-Speed mode announce countdown time
  if ((slope.mode ~= 2) or (basicCfg.f3bMode ~= 2)) then
    system.playNumber (self.remainingCountdown, 0)
    transmitter:playAudioFile ( globalVar.resource.audioSeconds, AUDIO_QUEUE )
  end
end

--------------------------------------------------------------------------------------------
-- start run: A-Base was passed from outside course or timeout occurred

function f3fRun:startRun ( timeout )
  
  -- timeout - late entry ocurred   
  if (timeout) then
     self.curStatus = self.status.TIMEOUT
  else
  -- regular f3f-start 
     self.curStatus = self.status.F3F_RUN
  end
  
  self.f3fStartTime = system.getTimeCounter()
  transmitter:playAudioFile ( globalVar.resource.audioCourse, AUDIO_QUEUE )
  
  -- skip apeed measurement in F3B-Distance mode
  if ((slope.mode == 2) and (basicCfg.f3bMode == 2)) then return end
  
  -- start timer for speed measurement after 1,5 sec.
  if ( basicCfg.speedAnnouncement and self.curSpeed and self:isStatus (self.status.F3F_RUN) ) then
     self.timerStartSpeed = system.getTimeCounter()
  end
end

--------------------------------------------------------------------------------------------
-- distance done: A-Base or B-Base was passed from inside course

function f3fRun:distanceDone ()

-- if we are not in a valid f3f-run - just beep to practise
   if ( not f3fRun:isStatus ( self.status.F3F_RUN )) then
     system.playBeep (0, 700, 300)  
   end
   
   -- in F3B-Distance mode: always count legs and beep
   if ((slope.mode == 2) and (basicCfg.f3bMode == 2)) then
     self.rounds = self.rounds+1
     self:setNextTurnDir ()
     system.playBeep (0, 700, 300)  
     return
   end

   local maxRounds
   if ( slope.mode == 1 ) then
     maxRounds = 10              -- F3F mode
   elseif ( slope.mode == 2 ) then
     maxRounds = 4               -- F3B mode
   end
   
   -- are we in f3f-run ?
   if ( self:isStatus (self.status.F3F_RUN)  ) then
   
      -- one more leg done
      self.rounds = self.rounds+1

      -- perform the appropriate beep
      if (self.rounds <= maxRounds-2 ) then
        system.playBeep  (0, 700, 300)  
      elseif (self.rounds == maxRounds-1 ) then
        system.playBeep  (1, 700, 300)	   
      else	  
        system.playBeep  (2, 850, 200)
      end

      -- from leg 8 make an announcement
      if ( self.rounds > maxRounds-3 and self.rounds < maxRounds ) then
         system.playNumber (self.rounds, 0)	  
      end

      -- all legs done - get flight time, change status
      if ( self.rounds >= maxRounds ) then
  	     local endTime = system.getTimeCounter()
        self.flightTime = endTime-self.f3fStartTime
		  
        transmitter:playAudioFile ( globalVar.resource.audioTime, AUDIO_QUEUE )
        system.playNumber (self.flightTime / 1000, 1)
        transmitter:playAudioFile ( globalVar.resource.audioSeconds, AUDIO_QUEUE )
		   
		-- log result
        if ( basicCfg.logResults ) then
          local mode
		  if (slope.mode == 1) then mode = "F3F" else mode = "F3B" end
          local dt = system.getDateTime()
		  local modelName = system.getProperty ("Model")
          local resultFile = string.format( "%d-%02d-%02d.txt", dt.year, dt.mon, dt.day )
          local text = string.format( "%d:%02d  %s-Time:  %.2f   (%s)", dt.hour, dt.min, mode, self.flightTime / 1000, modelName)
          writeToFile (dataDir.."/results", resultFile, text, true )   
		end
		   
		-- status change   
        self.curStatus = self.status.ON_HOLD
      end
   end
   
   -- set side of next turn
   self:setNextTurnDir ()

end

--------------------------------------------------------------------------------------------
-- calc remaining time for launch phase and give some announcements

function f3fRun:countdown ()

  -- skip countdown for F3B-Distance mode
  if ((slope.mode == 2) and (basicCfg.f3bMode == 2)) then
     return
  end	 

  local prevValue = self.remainingCountdown
  local curTime = system.getTimeCounter()     
  self.remainingCountdown = math.floor (self.countdownTime - (curTime-self.launchTime)/1000)

  if (self.remainingCountdown ~= prevValue) then

     -- Announcement
     if ( (self.remainingCountdown >= 30 and self.remainingCountdown % 10 == 0) or 
          (self.remainingCountdown  < 30 and self.remainingCountdown %  5 == 0) or 
          (self.remainingCountdown <= 10) )  then
		
        system.playNumber (self.remainingCountdown, 0)
     end
  end  
    
  -- Timeout: start F3F run / cancel F3B run 
  if ( self.remainingCountdown == 0 ) then
	   
     if ( slope.mode == 1 ) then        -- F3F
        self:startRun ( true ) 
     elseif ( slope.mode == 2 ) then    -- F3B
        system.playBeep (2, 500, 400)  
        self:init ()
     end	 
  end
end

--------------------------------------------------------------------------------------------
-- update current position, distance and bearing data

function f3fRun:updatePositionData ( point )

  if ( not point ) then return end
  self.curPosition = point
  
  ------ calc current distance
  if (slope.gpsHome) then
     self.curDist = gps.getDistance (slope.gpsHome, self.curPosition)
  end

  ------ calc current flight angle to slope
  if ( slope.gpsHome and slope.bearing ) then 
     
     -- current flight angle from north
     self.curBearing = gps.getBearing (slope.gpsHome, self.curPosition)

     -- current flight angle to slope
     self.curBearing = slope.bearing - self.curBearing
     if (self.curBearing < 0) then 
        self.curBearing = self.curBearing + 360
     end
	 
     -- determine, on which side of home position the model is located
     -- curBearing always meant clockwise from flight line to slope
	 
     if (self.curBearing <= 90 or self.curBearing > 270) then     -- 0-90 deg, 270-360 deg
        self.curDir = globalVar.direction.RIGHT
     else                             
        self.curDir = globalVar.direction.LEFT                    -- 90-270 deg
     end

  end
end

--------------------------------------------------------------------------------------------
-- update current speed from sensor, calculate optimization offsets
-- the whole magic of GPS and latency optimization

function f3fRun:updateSpeedAndOptimizationData ( speed, heading )

  -- Speed  

  self.curSpeed = speed
  if ( self.curSpeed ) then

     -- offset determination
     -- generally speed/6 is taken as 100% offset (max), what means 25m at speed of 150 km/h.
     -- this value can be reduced by a configurable speed faktor, which is taken as a percentage value (/100)
     self.f3fRunData.offset = self.curSpeed/6 * (basicCfg.speedFaktorF3F/100)

     -- *(-1): in launch phase the offset works in the opposite direction to optimize the first fly in
     --        also add a static offset, this brought better results in flying tests, can't explain why
     self.launchPhaseData.offset =  (-1) * ((self.curSpeed/6 * (basicCfg.speedFaktorLaunchPhase/100)) + basicCfg.statOffsetLaunchPhase)
  end

  -- Heading

  local absHeading = heading   -- heading to north

  if ( absHeading ) then
    -- heading related to slope edge
    self.curHeading = slope.bearing - absHeading
    if (self.curHeading < 0) then 
      self.curHeading = self.curHeading + 360
    end

    -- store cosinus for later offset determination
    self.absCosHeading = math.abs (math.cos (math.rad ( self.curHeading )))

  -- if heading is not provided from sensor we calculate it from position data
  else  
    local lat, lon = gps.getValue (self.curPosition)

    -- first occurance
    if ( not (self.lastLat and self.lastLon) ) then
      self.lastLat = lat
      self.lastLon = lon

    -- check if new position 
    -- LAT and LON must have changed to avoid jump between 0, 90, 180, 270 deg.
    elseif ( lat ~= self.lastLat and lon ~= self.lastLon ) then
  
      -- calc heading to north from last to current position
      absHeading = gps.getBearing (gps.newPoint (self.lastLat, self.lastLon), self.curPosition)
     
      -- heading related to slope edge    
      self.curHeading = slope.bearing - absHeading
      if ( self.curHeading < 0 ) then 
        self.curHeading = self.curHeading + 360
      end

      -- get cosinus and smoothen curve
      -- it is easier to smoothen than the original heading curve
      -- because cosinus has no 0/360 deg. jumps
      local cosHead = math.abs (math.cos (math.rad ( self.curHeading )))

      -- smoothen
      if ( self.prevCos_1 and self.prevCos_2) then
        self.absCosHeading = (4*cosHead + 2*self.prevCos_1 + self.prevCos_2) / 7
      end
      self.prevCos_2 = self.prevCos_1
      self.prevCos_1 = cosHead

      -- save for next use
      self.lastLat = lat
      self.lastLon = lon
    end
  end

end

--------------------------------------------------------------------------------------------
-- returns true if position is in the half the flight direction is:
--   - to right while we should hit the left line next (heading differs more than 100 deg. from 180°)
--   - to left while we should hit the right line next (heading differs more than 100 deg. from 360°)
--   - AND we are already in the half of the course where the next line hit should occur

function f3fRun:flyingAwayFromLine ()

  -- not in the right half facing the line?
  if ( self.curDir ~= self.nextTurnDir ) then return false end

  -- flying to right while left line is next
  if (( self.nextTurnDir == globalVar.direction.LEFT ) and
     (( math.abs ( self.curHeading - 360 ) < 80 ) or (self.curHeading < 80) )) then 
    return true                                               -- heading > 280° or < 80°
	   
  -- flying to left while right line is next
  elseif (( self.nextTurnDir == globalVar.direction.RIGHT ) and
         ( math.abs ( self.curHeading - 180 ) < 80 )) then    -- heading > 100 and < 260
    return true
  end	
	   
  return false
end

--------------------------------------------------------------------------------------------
-- check, if a fly out occurred, consider the calculated offsets and the turn line calculation
-- based on the cosinus

function f3fRun:checkFlyOut ( trackData )

  if ( trackData.insideFlag ) then
    local dist = self.curDist * math.abs ( math.cos (math.rad ( self.curBearing )))

    local offset = 0
	
	-- use optimization offset only if we are flying towards the line. Otherwise the
    -- increasing cosinus could lead to a wrong beep on the 'way back'
    if ( not self:flyingAwayFromLine () ) then
      offset = trackData.offset
      if ( self.absCosHeading ) then
        offset = offset * self.absCosHeading 
      end
    end
	
    if ( dist + offset > self.halfDistance) then
      trackData.insideFlag = false  
      return true
    end
  end

  return false  
end

--------------------------------------------------------------------------------------------
-- check, if a fly in occurred, consider the calculated offsets and the turn line calculation
-- based on the cosinus

function f3fRun:checkFlyIn ( trackData )

  if ( not trackData.insideFlag ) then
    local dist = self.curDist * math.abs ( math.cos (math.rad ( self.curBearing )))
  
    local offset = trackData.offset
    if ( self.absCosHeading ) then
      offset = offset * self.absCosHeading 
    end  
 
    if ( dist + offset < self.halfDistance) then
      trackData.insideFlag = true
      return true
    end
  end

  return false  
end

--------------------------------------------------------------------------------------------
-- check, if second turn in a f3b-run was done without reaching the turn distance
-- this is allowed, because the pilot standing at the a-base can fly this turn very precise
-- by eye.
-- the turn is recognized if the heading differs 100° from the expected flight direction to course
-- (to left: 180° / to right: 0°)

function f3fRun:checkF3bSecondTurnByHeading ()

  if ( (slope.mode == 2) and (basicCfg.f3bMode == 1) and     -- are we in f3b speed mode
       self:isStatus ( self.status.F3F_RUN ) and             -- are we in a competition run
       (self.rounds == 1) ) then                             -- second turn expected

    -- trigger turn if flight dierection is away from next line to hit
    if ( self:flyingAwayFromLine () ) then   
      system.playBeep  (1, 700, 200)        -- double beep
      self:setNextTurnDir ()
      self.rounds = self.rounds+1
    end
  end
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: gpsSensor                                                         ==========
-- ===============================================================================================
-- ===============================================================================================

gpsSensor = {
   lat   = {desc="latSensor", id=nil, param=nil},
   lon   = {desc="lonSensor", id=nil, param=nil},    
   speed = {desc="speedSensor", id=nil, param=nil},
   heading = {desc="headingSensor", id=nil, param=nil}
}

--------------------------------------------------------------------------------------------
function gpsSensor:init ()

  self.lat.id = system.pLoad ( self.lat.desc )
  self.lat.param = system.pLoad ( self.lat.desc .. "Param" )
  
  self.lon.id = system.pLoad ( self.lon.desc )
  self.lon.param = system.pLoad ( self.lon.desc .. "Param" )
  
  self.speed.id = system.pLoad ( self.speed.desc )
  self.speed.param = system.pLoad ( self.speed.desc .. "Param" )

  self.heading.id = system.pLoad ( self.heading.desc )
  self.heading.param = system.pLoad ( self.heading.desc .. "Param" )

end
    
--------------------------------------------------------------------------------------------
function gpsSensor:setSensorValue (sensorType, sensorValue)

   -- empty sensor
   if ( sensorValue.id == -1 and sensorValue.param == -1 ) then
    sensorType.id = nil
    sensorType.param = nil

  -- sensor configured 
  else
    sensorType.id = sensorValue.id
    sensorType.param = sensorValue.param
  end

   -- save in model json
   system.pSave( sensorType.desc, sensorValue.id )
   system.pSave( sensorType.desc .. "Param", sensorValue.param)
end
 
--------------------------------------------------------------------------------------------
function gpsSensor:getCurPosition ()

  local curPosition 
  if ( self.lat.id and self.lat.param and self.lon.param ) then
     curPosition = gps.getPosition ( self.lat.id, self.lat.param, self.lon.param )
  else
     -- GPS not configured
     globalVar.errorStatus = 1
     return nil
  end 

  -- check if GPS is active
  if ( not curPosition ) then
     globalVar.errorStatus = 2
     return nil
  end

  -- check if GPS is ready
  local lat, lon = gps.getValue ( curPosition )
  if ( lat == 0  and  lon == 0 ) then
 	 globalVar.errorStatus = 5
	 return nil
  end
  
  return curPosition
end

--------------------------------------------------------------------------------------------
function gpsSensor:getCurSpeed ()

   local sensorData
   local sensorvalue = 0

   if ( self.speed.id and self.speed.param ) then
     sensorData = system.getSensorByID ( self.speed.id, self.speed.param )
   end  
   if(sensorData and sensorData.valid) then
     sensorvalue =  sensorData.value

     -- we need km/h
     if ( sensorData.unit == "m/s" ) then
       sensorvalue = sensorvalue * 3.6
     end
		
     return sensorvalue
   else
     globalVar.errorStatus = 3
     return 0
   end  
end

--------------------------------------------------------------------------------------------
function gpsSensor:getCurHeading ()

  local sensorData
  local sensorvalue = 0

  if ( self.heading.id and self.heading.param ) then
    sensorData = system.getSensorByID ( self.heading.id, self.heading.param )
  end  
  if(sensorData and sensorData.valid) then
    sensorvalue =  sensorData.value
 
    return sensorvalue
  else
    return nil
  end  
end

--------------------------------------------------------------------------------------------
function gpsSensor:isValidPosition ( pos )
  if ( not pos ) then return false end

  local lat, lon = gps.getValue ( pos )
  return ( not (lat == 0 and lon == 0 ) )
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: basicCfg                                                          ==========
-- ===============================================================================================
-- ===============================================================================================

basicCfg = {
  switch,                         -- multifunction push button
  f3fDistance,                    -- distance of f3f course (default: 100m)
  f3bDistance,                    -- distance of f3b course (default: 150m)  
  ctrlCenterShift,                -- Control: adjust center to left / right
  f3bMode,                        -- F3B: Speed:1  /  Distance: 2
  
  formModuleName = dataDirRel .. "/module/basicCfgForm",  -- load basicCfgform module only when
  formModule = nil,                                       --   needed during configuration

-- values for adjustment of latency
-- currently not configured, but can be put on potis for adjustment
  speedFaktorF3F = 58,           -- faktor for speed effect on offset during f3f run
  speedFaktorLaunchPhase = 62,   -- faktor for speed effect on offset during launch phase
  statOffsetLaunchPhase = 6,     -- static offset for launch phase 

-- further settings
  speedAnnouncement, 
  logResults
}

--------------------------------------------------------------------------------------------
function basicCfg:init ()

  -- get configuration values from model json
  self.switch = system.pLoad("switch")
  self.f3fDistance = system.pLoad("f3fDistance", 100)
  self.f3bDistance = system.pLoad("f3bDistance", 150)
  self.ctrlCenterShift = system.pLoad("ctrlCenterShift")
  self.f3bMode = system.pLoad("f3bMode", 1)
  self.speedAnnouncement = (system.pLoad("speedAnnouncement", 1) == 1 ) -- default: true
  self.logResults = (system.pLoad("logResults", 0) == 1 )               -- default: false
end

--------------------------------------------------------------------------------------------
function basicCfg:initForm(formID)

  self.formModule = require ( self.formModuleName )

  -- set needed objects and values  
  self.formModule.cfgData = self
  self.formModule.gpsSensor = gpsSensor
  self.formModule.dataDir = dataDir
  self.formModule.handleErr = handleError

  -- init form
  self.formModule:initForm (formID)

end  

function basicCfg:closeForm()

  if ( self.formModule ) then self.formModule:closeForm () end  

  -- cleanup and reload f3fRun - Module
  self.formModule = nil
  package.loaded [ self.formModuleName ] = nil
  collectgarbage("collect")   

  -- print("CloseCfg/GC Count after reload : " .. collectgarbage("count") .. " kB");

end  

function basicCfg:toggleF3bMode()
  if ( self.f3bMode == 1 ) then 
    self.f3bMode = 2
    transmitter:playAudioFile (globalVar.resource.audioF3bDistance, AUDIO_QUEUE)
  else 
    self.f3bMode = 1
    transmitter:playAudioFile (globalVar.resource.audioF3bSpeed, AUDIO_QUEUE)  	
  end
  system.pSave( "f3bMode", self.f3bMode )
  f3fRun:init ()
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: transmitter                                                       ==========
-- ===============================================================================================
-- ===============================================================================================

transmitter = {

--  state = { IDLE=0, ACTIV_1=1, RELEASED_1=2, ACTIV_2=3 },   -- needs too much memory :( 
                                                              -- use values directly   
  -- variables for multi-button observation
  switchState = 0,
  timerStartSwitch,                -- timer for detection of long- / double- / long click

  -- variables for center shift observation
  centerShiftState = 0,             -- <=0: released / 1: first shift / 2: 1 ore more shifts trigged by timer 
  timerCenterShift,                 -- timer for holding center shift control
  shiftDir = globalVar.direction.UNDEF,
  shiftCount = 0                    -- >0: shift right / <0: shift left
}

--------------------------------------------------------------------------------------------
-- observe multifunction button
-- return 1: single click / 2: double click / 3: long click 

function transmitter:observeSwitch ()

  local sVal
  
  sVal = system.getInputsVal( basicCfg.switch)
  if (not sVal) then return 0 end
  
  local pressed = sVal and sVal>0
  local released = sVal and sVal<=0

  if (self.switchState == 0 and pressed) then            -- status 0: idle
     self.switchState = 1
     self.timerStartSwitch = system.getTimeCounter()     -- wait for long click

  elseif (self.switchState == 1 and pressed) then        --  status 1: first pressed
     -- check timer: long click if expired
     if ( (system.getTimeCounter() - self.timerStartSwitch) > 2000 ) then
       self.switchState = 3
       return 3  -- long click
     end
 
  elseif (self.switchState == 1 and released) then       --  status 1: first pressed
     self.switchState = 2
     self.timerStartSwitch = system.getTimeCounter()     -- wait for double click

  elseif (self.switchState == 2 and released) then       -- status 2: first released
     -- check timer: single click if expired
     if ( (system.getTimeCounter() - self.timerStartSwitch) > 250 ) then
        self.switchState = 0
     return 1  -- single click
     end

  elseif (self.switchState == 2 and pressed) then   
     self.switchState = 3
     return 2  -- double click

  elseif (self.switchState == 3 and released) then       -- status 3: second pressed
     self.switchState = 0
  end

  return 0
end

--------------------------------------------------------------------------------------------
function transmitter:incrShiftCount ( dir )
  if ( dir == globalVar.direction.RIGHT ) then
    self.shiftCount = self.shiftCount + 1
  elseif ( dir == globalVar.direction.LEFT ) then
    self.shiftCount = self.shiftCount - 1
  end
end

--------------------------------------------------------------------------------------------
-- observe control for center adjustment

function transmitter:observeCenterShift ()

  -- get control state
  local sVal
  sVal = system.getInputsVal( basicCfg.ctrlCenterShift)
  if ( not sVal ) then return globalVar.direction.UNDEF end

  -- state <0: right or left pressed from idle state ?
  if ( self.centerShiftState <= 0 ) then
    if ( sVal > 0.3 ) then
      self.shiftDir = globalVar.direction.RIGHT  -- adjust to right
      self.centerShiftState = 1
    elseif ( sVal < -0.3 ) then
      self.shiftDir = globalVar.direction.LEFT  -- adjust to left
      self.centerShiftState = 1
    end
	
    if ( self.centerShiftState == 1 ) then
      self.timerCenterShift = system.getTimeCounter()
      self:incrShiftCount ( self.shiftDir )        
      return self.shiftDir
    end  
	
  -- control released: start timer to wait some ms, migt be pressed again (State -1)
  elseif ( sVal > -0.3 and sVal < 0.3 ) then
    self.centerShiftState = -1
    self.timerCenterShift = system.getTimeCounter()
    self.shiftDir = globalVar.direction.UNDEF
  end
    
  -- control was released and timer expired    
  if ( self.centerShiftState == -1 and (system.getTimeCounter() - self.timerCenterShift) > 400 ) then         
        
    -- announce number of shifted meters
    if ( self.shiftCount > 0 ) then
      transmitter:playAudioFile (globalVar.resource.audioRight, AUDIO_QUEUE)	
      system.playNumber ( self.shiftCount, 0, "m")
    elseif ( self.shiftCount < 0 ) then
      transmitter:playAudioFile (globalVar.resource.audioLeft, AUDIO_QUEUE)	
      system.playNumber ( self.shiftCount*-1, 0, "m")
    end
    self.centerShiftState = 0
    self.shiftCount = 0	  
  end

  -- control is held (left or right)
  if ( self.centerShiftState == 1 and  (system.getTimeCounter() - self.timerCenterShift) > 400 ) then
      self.centerShiftState = 2
      self.timerCenterShift = system.getTimeCounter()
      self:incrShiftCount ( self.shiftDir )        
      return self.shiftDir
  
  elseif (self.centerShiftState == 2 and  (system.getTimeCounter() - self.timerCenterShift) > 150 ) then 
      self.timerCenterShift = system.getTimeCounter()
      self:incrShiftCount ( self.shiftDir )        
      return self.shiftDir
  end

  return globalVar.direction.UNDEF
end

--------------------------------------------------------------------------------------------
-- play audio file

function transmitter:playAudioFile ( resourceString, playbackType )

  -- input string may contain placeholder for data directory
  local res = string.gsub (resourceString, "$dataDir", dataDirRel)
  system.playFile ( res, playbackType )
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: slope                                                             ==========
-- ========== ( maybe also a F3B Course )                                               ==========
-- ===============================================================================================
-- ===============================================================================================

slope = {
  gpsHome = nil,                     -- home: center point / starting position
  bearing = nil,                     -- calculated slope bearing (from north)  
  aBase = globalVar.direction.LEFT,  -- A-Base initial left
  mode = 1,                          -- 1: F3F  /  2: F3B
  name = nil                         -- shown only when set by external course database app
}

--------------------------------------------------------------------------------------------
function slope:init ()
  local file = io.readall(dataDir .. "/slopeData.jsn")
  if ( file ) then
    local slopeData = json.decode(file)

    self.gpsHome = gps.newPoint ( slopeData.homeLat, slopeData.homeLon ) 
    if (slopeData.aBase) then self.aBase = slopeData.aBase end 
    if (slopeData.bearing) then self.bearing = slopeData.bearing end
    if (slopeData.mode) then self.mode = slopeData.mode end
	  
    -- name - may be set by Database - App
    if (slopeData.name) then 
      self.name = slopeData.name
    else 
      self.name = ""
    end	  

  end
end

--------------------------------------------------------------------------------------------
function slope:jsonData ()
  local latHome, lonHome = gps.getValue ( self.gpsHome )
  return {homeLat=latHome, homeLon=lonHome, bearing=self.bearing,
          aBase = self.aBase, mode = self.mode, name = self.name}
end
  
--------------------------------------------------------------------------------------------
function slope:isDefined () return ( self.gpsHome and self.bearing ) end

--------------------------------------------------------------------------------------------
function slope:persist ()
  if ( self:isDefined () ) then
    --- save slope-data in JSON independently from model storage
    local jsonStr = json.encode ( self:jsonData () )
    writeToFile (dataDir, "slopeData.jsn", jsonStr, false )   
  end    
end

--------------------------------------------------------------------------------------------
function slope:toggleABase ()
  if ( self.aBase == globalVar.direction.LEFT ) then 
    self.aBase = globalVar.direction.RIGHT 
    transmitter:playAudioFile (globalVar.resource.audioARight, AUDIO_QUEUE)
  else
    self.aBase = globalVar.direction.LEFT
    transmitter:playAudioFile (globalVar.resource.audioALeft, AUDIO_QUEUE)
  end

  self:persist ()	
end

--------------------------------------------------------------------------------------------
-- definition of new center point (home)

function slope:defineNewCenter ()

   globalVar.errorStatus = 0
   
   -- new home from current GPS-position
   local newHome = gpsSensor:getCurPosition ()  
   if ( globalVar.errorStatus ~= 0 ) then system.playBeep (2, 1000, 200) return end	  
   
   -- F3B-mode: move center from left turn half distance to right turn
   if ( slope.mode == 2 ) then
      newHome = gps.getDestination ( newHome, basicCfg.f3bDistance / 2, self.bearing  )
      transmitter:playAudioFile (globalVar.resource.audioStartPoint, AUDIO_QUEUE)	  
   else
      transmitter:playAudioFile (globalVar.resource.audioCenter, AUDIO_QUEUE)	  
   end
   
   self.gpsHome = newHome
   self:persist ( nil )
end

--------------------------------------------------------------------------------------------
-- adjustment of center point ( 1 meter ) 
-- useful for compensation of GPS-drift effects

function slope:moveCenter ( dir )

   -- check, if slope is defined
   if ( not self:isDefined () ) then
     globalVar.errorStatus = 4
     system.playBeep (2, 1000, 200)
     return
   end	

   local bear = self.bearing
   if ( dir == globalVar.direction.LEFT ) then 
      -- adjustment to left: use reverse bearing 
      bear = (bear + 180) % 360
      system.playBeep (0, 600, 100)
   else
      system.playBeep (0, 1000, 100)  
   end
  
   -- move it
   self.gpsHome = gps.getDestination ( self.gpsHome, 1, bear )
   self:persist ()
end

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: slopeManager                                                      ==========
-- ===============================================================================================
-- ===============================================================================================

slopeManager = { 
   formModuleName = dataDirRel .. "/module/slopeMgrForm",  -- load form module only when
   formModule = nil                                        --   needed during course setup
}

--------------------------------------------------------------------------------------------
-- Form anzeigen 
function slopeManager:initSlopeForm (formID)

  -- load Module
  self.formModule = require ( self.formModuleName )
  
  -- set needed objects and values  
  self.formModule.dataDir = dataDir
  self.formModule.globalVar = globalVar
  self.formModule.slope = slope
  self.formModule.gpsSens = gpsSensor
  self.formModule.errorTable = errorTable
  self.formModule.f3bDist = basicCfg.f3bDistance
  self.formModule.handleErr = handleError
  
  -- init form
  self.formModule:initSlopeForm (formID)
end
     
--------------------------------------------------------------------------------------------
-- observe keys of scan page
function slopeManager:slopeScanKeyPressed(key)
  self.formModule:slopeScanKeyPressed(key)
end  

--------------------------------------------------------------------------------------------
function slopeManager:printSlopeForm()
   self.formModule:printSlopeForm()  
end  

--------------------------------------------------------------------------------------------
function slopeManager:closeSlopeForm()

  -- unload form module
  self.formModule = nil
  package.loaded [ self.formModuleName ] = nil

  -- reinit current run on new course
  f3fRun:init ()

  -- clear up
  collectgarbage("collect")
 
  -- print("Slope/GC Count after load f3fRun : " .. collectgarbage("count") .. " kB")
end 

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: Display                                                           ==========
-- ===============================================================================================
-- ===============================================================================================

display = { 
  resolution = nil,      -- nil: undefined / 1: old display 320 * 240 px 
                         --                  2: new display 480 * 480 px (DC/DS 24 II)
  yTop = 0,
  yBottom = 0,
  yCounter = 0
}

--------------------------------------------------------------------------------------------
function display:setColor()
   local r, g, b = lcd.getBgColor()

   -- use left or white letters depending from backgrond
   if ((r + g + b) / 3 < 128) then
     r, g, b = 255, 255, 255
   else
     r, g, b = 0, 0, 0
   end
   lcd.setColor(r, g, b)
end

--------------------------------------------------------------------------------------------
function display:showSplashScreen ()

  if ( self.resolution == 1 ) then
    lcd.drawText(10,-1, "F3F",FONT_MAXI)  
    lcd.drawText(10,32, "Tool",FONT_BIG)  
    lcd.drawText(10,53, "Version " .. appVersion, FONT_MINI)  	   

  elseif ( self.resolution == 2 ) then
    lcd.drawText(11,3, "F3F",FONT_MAXI)  
    lcd.drawText(6,34, "Tool",FONT_MAXI)  
    lcd.drawText(8,73, "Version " .. appVersion, FONT_NORMAL)  
  end
  
  -- on error show message on splash screen
  if (globalVar.errorStatus > 0) then
    lcd.drawText(80,5, errorTable [globalVar.errorStatus][1],FONT_MINI)  
    lcd.drawText(80,18, errorTable [globalVar.errorStatus][2],FONT_MINI)  
    lcd.drawText(80,31, errorTable [globalVar.errorStatus][3],FONT_MINI)  
  end
end

--------------------------------------------------------------------------------------------
-- graphic display of position inside / outside,

function display:showInsideStatus ( inside_status )

  if ( f3fRun.curDir == globalVar.direction.UNDEF ) then return end

  -- yPositions, dependent from screen resolution
  local y1 = self.yTop + 13
  local y2 = self.yTop + 19
  local y3 = self.yTop + 26
  
  -- draw turn lines
  lcd.drawLine ( 111, y1, 111, y3)
  lcd.drawLine ( 112, y1, 112, y3)

  lcd.drawLine ( 134, y1, 134, y3)
  lcd.drawLine ( 135, y1, 135, y3)

  -- draw model position
  --  "  |  --|  "
  if (inside_status and f3fRun.curDir == globalVar.direction.RIGHT) then
    lcd.drawLine ( 124, y2, 132, y2)
    lcd.drawLine ( 124, y2+1, 132, y2+1)

  -- "  |--  |  "
  elseif (inside_status and f3fRun.curDir == globalVar.direction.LEFT) then
    lcd.drawLine ( 114, y2, 122, y2)
    lcd.drawLine ( 114, y2+1, 122, y2+1)

  -- "  |    |--"
  elseif ( f3fRun.curDir == globalVar.direction.RIGHT ) then
    lcd.drawLine ( 137, y2, 145, y2)
    lcd.drawLine ( 137, y2+1, 145, y2+1)

  -- "--|    |  "
  elseif ( f3fRun.curDir == globalVar.direction.LEFT ) then
    lcd.drawLine ( 101, y2, 109, y2)
    lcd.drawLine ( 101, y2+1, 109, y2+1)
  end
 
  -- A-Base anzeigen
  local aPos = 108
  if ( slope.aBase == globalVar.direction.RIGHT ) then
     aPos = aPos + 23
  end	 
  lcd.drawText( aPos, self.yTop, "A", FONT_MINI)  
end

--------------------------------------------------------------------------------------------
-- helps to find starting position, if it is not marked on the slope

function display:showDistanceToStart ()

  -- F3F: use GPSHome from system, middle of the course+
  local distToStart
  if ( slope.mode == 1 ) then
    distToStart = f3fRun.curDist
	
  -- F3B: recalc distance to startpoint at A-Line	
  elseif ( slope.mode == 2 and slope:isDefined () and f3fRun.curPosition ) then
	local f3bStart = gps.getDestination ( slope.gpsHome, (-1) * basicCfg.f3bDistance / 2, slope.bearing )
	distToStart = gps.getDistance (f3bStart, f3fRun.curPosition)
  end

  if ( distToStart ) then
    local text = ""
    if ( distToStart > 1000 ) then  
      text = ">1000"
    else
      text = string.format( "%.1f", distToStart )
    end
    lcd.drawText(132 - lcd.getTextWidth(FONT_BOLD,text), self.yBottom, text, FONT_BOLD)  
    lcd.drawText(135, self.yBottom + 5, "m", FONT_MINI)  
    lcd.drawText(106, self.yBottom + 18, "to Start", FONT_MINI)  

  end
end

--------------------------------------------------------------------------------------------
function display:showAdditionalInfo ()

  -- for F3F: show graphical 'inside-status' in upper right corner
  if ( slope.mode == 1 ) then

    -- use 'run-Data' during and after f3f-run ( coming from inside the course )     
	if ( f3fRun:isStatus ( f3fRun.status.F3F_RUN ) or
	     f3fRun:isStatus ( f3fRun.status.ON_HOLD ) ) then
	  self:showInsideStatus(f3fRun.f3fRunData.insideFlag)

    -- use 'launchPhase-Data' before run ( coming from outside the course )     
	-- Status: INIT, STARTPHASE, TIMEOUT  
    else 
  	  self:showInsideStatus(f3fRun.launchPhaseData.insideFlag)
    end
  --------------------------------------------------------------------
  -- for F3B: show 'F3B Speed' / 'F3B Distance' in upper right corner
  elseif ( slope.mode == 2 ) then
    lcd.drawText(103, self.yTop + 1, "F3B", FONT_NORMAL)
    if (basicCfg.f3bMode == 1) then
      lcd.drawText(103, self.yTop + 18, "Speed", FONT_MINI)
    elseif (basicCfg.f3bMode == 2) then
      lcd.drawText(103, self.yTop + 18, "Distance", FONT_MINI)
    end
  end
  
  --------------------------------------------------------------------
  -- show 'distance to start' before launch ( INIT ) and after run ( ON_HOLD )
  -- ( lower right corner )
  if ( f3fRun:isStatus ( f3fRun.status.INIT ) or
	   f3fRun:isStatus ( f3fRun.status.ON_HOLD ) ) then
    display:showDistanceToStart ()
  end
end

--------------------------------------------------------------------------------------------
function display:printLegCount ()

  -- show legs (rounds)
  if(f3fRun.rounds) then
    lcd.drawText(10, self.yTop+4, "Legs:", FONT_BOLD)
    local text = string.format("%.0f", f3fRun.rounds)
    lcd.drawText(80 - lcd.getTextWidth(FONT_MAXI,text), self.yCounter, text, FONT_MAXI)
  end

  -- and a little time display	
  local curFlightTime = system.getTimeCounter() - f3fRun.f3fStartTime
  local text = string.format("%.0f%s",curFlightTime / 1000,"")
  lcd.drawText(120, self.yBottom + 10, text,FONT_BOLD)  
end

--------------------------------------------------------------------------------------------
-- display all the interesting infos like countdown, legs, time ...

function display:printFlightInfo (width, height)
 
   -- initialize color
   self:setColor ()

  -- initilize resolution
  if ( not self.resolution ) then

    -- DC 24 II, larger display: 480 * 480 px.
    if (height > 80) then
      self.resolution = 2
      self.yTop = 8
      self.yBottom = 60
      self.yCounter = 33
	  
    -- 'old' display: 320 * 240 px.  
	else
      self.resolution = 1
      self.yTop = 1
      self.yBottom = 35
      self.yCounter = 23
	end 
  end	

  -- draw separator line on high resolution screen
  if ( self.resolution == 2 ) then
    lcd.drawLine(0,0,157, 0)  
  end  

  -- prior to first run: show splash screen and course information
  if ( f3fRun and f3fRun:isStatus ( f3fRun.status.INIT )) then
    self:showSplashScreen ()

  -- error after INIT: show in large letters
  elseif ( globalVar.errorStatus > 0) then
    lcd.drawText(5,5, errorTable [globalVar.errorStatus][1].." "..errorTable [globalVar.errorStatus][2],FONT_BIG)  
    lcd.drawText(5,30, errorTable [globalVar.errorStatus][3],FONT_BIG)

  -- start phase: show countdown
  elseif ( f3fRun:isStatus (f3fRun.status.STARTPHASE) ) then
    lcd.drawText(10, self.yTop+4, "Launch:", FONT_BOLD)
    local text = string.format("%.0f%s", f3fRun.remainingCountdown,"")
    lcd.drawText(85 - lcd.getTextWidth(FONT_MAXI,text), self.yCounter, text, FONT_MAXI)

  -- during run: show leg count and a little timer
  elseif ( f3fRun:isStatus (f3fRun.status.TIMEOUT) or
           f3fRun:isStatus (f3fRun.status.F3F_RUN) ) then
    self:printLegCount () 

  -- after the run: show Flight time
  elseif ( f3fRun:isStatus (f3fRun.status.ON_HOLD) ) then
    lcd.drawText(10, self.yTop + 4, "Time:", FONT_BOLD)
    local text = string.format("%.2f%s",f3fRun.flightTime / 1000,"")
    lcd.drawText(10, self.yCounter,text,FONT_MAXI) 
  end
  
  -- display some additional features if there is no error display
  if (globalVar.errorStatus == 0) then
    self:showAdditionalInfo ()
  end
end

-- ==========================================================================================================================
-- ==========================================================================================================================
-- ==========                                     Section Initialization                                           ==========
-- ==========================================================================================================================
-- ==========================================================================================================================

local function init()

  -- cleanup
  collectgarbage("collect") 

  -- register display first ( maybe needed for error message)
  system.registerTelemetry(1, appName, 2,
      function ( width, height ) display:printFlightInfo ( width, height ) end )

   -- check device type, this Version does not run on generation 1 hardware (monochrome display)
   local monoDev = {"JETI DC-16", "JETI DS-16", "JETI DC-14", "JETI DS-14"}
   local dev = system.getDeviceType()
   for _,v in ipairs(monoDev) do
      if dev == v then    
        globalVar.errorStatus = 6
	    print("GC Count (device error): " .. collectgarbage("count") .. " kB");
        return
      end
   end

  -- intialize objects
  slope:init ()        -- the slope
  gpsSensor:init ()    -- the gps sensor
  basicCfg:init ()     -- the basic configuration
  f3fRun:init ()       -- the f3fRun module

  -- register forms
  -- Hint: the functions from 'basicCfg' and 'slopeManager' cannot be passed directly 
  --       as callback functions to 'registerForm', because we need the 'self'-parameter 
  --       and therefore need to use the function call by ':'. This does not work for 
  --       a direct callback, thats why the functions are capsuled.
    
  system.registerForm(1, MENU_APPS, appName .. " - Configuration",
      function ( formId ) basicCfg:initForm ( formId ) end, nil, nil,
      function () basicCfg:closeForm () end )
	  
  system.registerForm(2,MENU_APPS, appName .. " - Course Setup",
      function ( formId ) slopeManager:initSlopeForm ( formId ) end,
      function ( key ) slopeManager:slopeScanKeyPressed ( key ) end,
      function () slopeManager:printSlopeForm () end,
      function () slopeManager:closeSlopeForm () end )

  -- register log variables (via external module if available)      
  local logModuleName = dataDirRel .. "/module/logModule"
  local loadSuccess, logModule = pcall ( require, logModuleName )
--  local logModule = require ( logModuleName )

  -- provide necessary information and register
  if ( loadSuccess ) then
    logModule.globalVar = globalVar
    logModule.f3fRun = f3fRun
    logModule:registerLogVariables ()
  end

  -- DEBUG
  -- print("GC Count : " .. collectgarbage("count") .. " kB");

  collectgarbage("collect") 
  -- print("GC Count after init: " .. collectgarbage("count") .. " kB");
end

-- ==========================================================================================================================
-- ==========================================================================================================================
-- ==========                                     Section LOOP                                                     ==========
-- ==========================================================================================================================
-- ==========================================================================================================================

local function loop() 

  -- check: device error -> skip loop
  if ( globalVar.errorStatus == 6 ) then return end

  -- check if course was changed by external app (F3FTool Database)
  -- indicated by a global variable
  if ( f3fTool_extCourseChange ) then
     slope:init ()   -- read new course data from file   
     f3fRun:init ()  
     f3fTool_extCourseChange = false
  end

  -- need an adjustment of home position ?
  local shift = transmitter:observeCenterShift ()
  if ( shift ~= globalVar.direction.UNDEF ) then
    slope:moveCenter ( shift )
  end
    
  -- observe multifunction button
  -- single click: launch
  local cmd = transmitter:observeSwitch ()
  if ( cmd == 1 ) then
    system.playBeep (0, 1200, 200)  
    f3fRun:launch ()
	
  -- double click: toggle A-Base (F3F)  or toggle Speeed/Distance  (F3B)
  elseif ( cmd == 2 ) then
    system.playBeep (0, 1200, 200)     
    if (slope.mode == 1) then
       slope:toggleABase ()
    elseif (slope.mode == 2) then
       basicCfg:toggleF3bMode()
    end
	
  -- long click: define new home position	
  elseif ( cmd == 3 ) then
    system.playBeep (0, 1200, 200)  
    slope:defineNewCenter ()
  end
	
  -----------------------------------------------------------------------------  
  -- check sensors, if not active then cancel (re-init f3fRun)
  -- otherwise get current position from sensor
  globalVar.errorStatus = 0
  local gpsPos = gpsSensor:getCurPosition ()
  if ( globalVar.errorStatus > 0) then f3fRun:init () return end
	
  -----------------------------------------------------------------------------  
  -- check, if slope is defined and valid
  if ( not slope:isDefined () ) then
    globalVar.errorStatus = 4
    return
  end	

  if ( not gpsSensor:isValidPosition (slope.gpsHome) ) then
    globalVar.errorStatus = 7
    return
  end	

  -----------------------------------------------------------------------------    
  -- recalculate angle and distance
  f3fRun:updatePositionData ( gpsPos )
    
  -----------------------------------------------------------------------------  
  -- update optimizaton values from speed and heading
  local curSpeed = gpsSensor:getCurSpeed ()
  local curHeading = gpsSensor:getCurHeading ()
  f3fRun:updateSpeedAndOptimizationData ( curSpeed, curHeading )
  
  -----------------------------------------------------------------------------
  -- check for second turn in a f3b speed run - is recognized by special rules

  f3fRun:checkF3bSecondTurnByHeading ()

  -----------------------------------------------------------------------------
  -- was a Base passed in f3f-Run (using the optimization offsets INSIDE the course)
  -- fly-out
  if ( f3fRun:checkFlyOut ( f3fRun.f3fRunData ) ) then    -- 5: status f3fRun.F3F_RUN

    -- this event is not valid for launch phase and timeout status -> use launch phase fly-out
     if ( not f3fRun:isStatus ( f3fRun.status.STARTPHASE ) and 
          not f3fRun:isStatus ( f3fRun.status.TIMEOUT )) then 
        if ( f3fRun.curDir == f3fRun.nextTurnDir ) then
           f3fRun:distanceDone()
        end
     end
	 
  -- fly-in	  
  else
     f3fRun:checkFlyIn ( f3fRun.f3fRunData )               -- 5: status f3fRun.F3F_RUN
  end

-----------------------------------------------------------------------------  
  -- was a Base passed in launch phase (using the optimization offsets OUTSIDE the course)

  -- fly-out
  if ( f3fRun:checkFlyOut ( f3fRun.launchPhaseData ) and
     ( f3fRun.curDir == slope.aBase ) ) then                 -- only valid on A-BAse
     -- event only valid for launch Phase and timeout 
     if ( f3fRun:isStatus (f3fRun.status.STARTPHASE) or 
          f3fRun:isStatus (f3fRun.status.TIMEOUT)) then
        system.playBeep  (0, 700, 300)  -- fly-out beep
     end
  end

  -- fly-in
  if ( f3fRun:checkFlyIn ( f3fRun.launchPhaseData ) and
     ( f3fRun.curDir == slope.aBase ) ) then                 -- only valid on A-BAse
     if ( f3fRun:isStatus (f3fRun.status.STARTPHASE) or 
          f3fRun:isStatus (f3fRun.status.TIMEOUT) ) then
       system.playBeep  (0, 700, 300)  -- fly-in beep
       f3fRun:setNextTurnDir ()        -- next expected turn side
     end  

     -- in launch phase, the f3f run starts here
     if ( f3fRun:isStatus (f3fRun.status.STARTPHASE) ) then
       f3fRun:startRun ( false )
	 
       -- if already a timeout occcurred, the time is running, just update status
     elseif ( f3fRun:isStatus (f3fRun.status.TIMEOUT) ) then
       f3fRun.curStatus = f3fRun.status.F3F_RUN
       transmitter:playAudioFile ( globalVar.resource.audioLateEntry, AUDIO_QUEUE )
       
       -- Timer for speed measurement
       if ( basicCfg.speedAnnouncement ) then
          f3fRun.timerStartSpeed = system.getTimeCounter()
       end
	   end
  end

-----------------------------------------------------------------------------  
  -- Launch Phase: update countdown
  if ( f3fRun:isStatus (f3fRun.status.STARTPHASE) ) then
    f3fRun:countdown ()     
  end 

-----------------------------------------------------------------------------  
  -- the speed is measured and announced 1,5 seconda after first fly-in
  -- should be a quality metric for the launch phase.
  if ( f3fRun.timerStartSpeed > -1 ) then
     if (system.getTimeCounter() - f3fRun.timerStartSpeed >= 1500 ) then
        transmitter:playAudioFile (globalVar.resource.audioSpeed, AUDIO_QUEUE)  
        system.playNumber ( f3fRun.curSpeed , 0)
        f3fRun.timerStartSpeed = -1
     end
  end
  	
end
 
--------------------------------------------------------------------
setLanguage()
return { init=init, loop=loop, author="Frank Schreiber", version=appVersion, name=appName}