-- ###############################################################################################
-- # F3F Tool for JETI DC/DS transmitters 
-- # Module: slopeMgrForm
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
-- # 
-- # The bearing of a slope or a F3B-Course can be either given by direct input 
-- # (F3F: wind direction / F3B: Flight course dir.) or by scan of two points (left / right)
-- # at the slope (F3F) or A-Line (F3B).
-- # Additionally th starting point must be scanned.
-- # 
-- ###############################################################################################

-- ===============================================================================================
-- ===============================================================================================
-- ========== Object: slopeMgrForm                                                      ==========
-- ========== contains form and functions for slope / course setup                      ==========
-- ===============================================================================================
-- ===============================================================================================

local slopeMgrForm = {
  -- referenced objects, set from outside
  dataDir = nil,
  globalVar = nil,
  slope = nil,
  gpsSens = nil,
  errorTable = nil,
  f3bDist = nil,
  handleErr = nil,

  -- internal stuff
  displayName = "",
  action = "",               -- display information
  checkBoxSlope = nil,       -- checkBox components
  checkBoxBearingL = nil,
  checkBoxBearingR = nil,
  intBoxBearing = nil,       -- direct input course-bearinf / wind direction
  
  gpsNewHome = nil,          -- new Center point
  gpsBearLeft = nil,         -- left bearing point
  gpsBearRight = nil,        -- right bearing point
  bearing = nil,             -- new bearing
  valueBearingDirect = nil,  -- direct bearing input value
  
  -- enabled-flags
  leftRightScanEnabled = true,
  courseTypeToggleEnabled = true,
  
  -- component pointer for bearing (left/right) scan
  bearScan = {},
  
  mode = nil                 -- 1: F3F  /  2: F3B
}

--------------------------------------------------------------------------------------------
  -- Section Form Setup
--------------------------------------------------------------------------------------------
function slopeMgrForm:enableLeftRightScan ( enable )

  if ( enable ) then
    form.setButton(2,"Left", ENABLED)
    form.setButton(3,"Right", ENABLED)
  else
    form.setButton(2,"Left", DISABLED)
    form.setButton(3,"Right", DISABLED)
  end
  
  self.leftRightScanEnabled = enable
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:enableCourseToggle ( enable )

  local buttonText
  if ( self.mode == 1 ) then buttonText = "F3B"
  elseif ( self.mode == 2 ) then buttonText = "F3F"	end
	
  if ( enable ) then
    form.setButton(4, buttonText, ENABLED)
  else
    form.setButton(4, buttonText, DISABLED)
  end
  
  self.courseTypeToggleEnabled = enable
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:hideBearingScanLine ( hide )

  for _i, comp in ipairs ( self.bearScan ) do 
    form.setProperties ( comp, { visible = not hide } )
  end
  form.setProperties ( self.checkBoxBearingL, { visible = not hide } )
  form.setProperties ( self.checkBoxBearingR, { visible = not hide } )
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:cycleDegreeBox (value)

  -- make the box cycle
  if ( value == -2 ) then
    value = 359
  elseif ( value == 360 ) then
    value = -1
  end

  form.setValue( self.intBoxBearing, value)
  return value
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:bearingChanged ( value )

  -- make the box cycle
  value = self:cycleDegreeBox ( value )

  -- save value
  self.valueBearingDirect = value

  -- in case of f3f-slope the wind direction is given, so the bearing is 90 deg higher
  if ( self.mode == 1 ) then
    self.valueBearingDirect = self.valueBearingDirect + 90
	if ( self.valueBearingDirect > 359) then
	  self.valueBearingDirect = self.valueBearingDirect - 360
	end
  end

  -- directInput active?  ( -1 means scan is used )
  local directInput = (  value ~= -1 )

  if ( directInput ) then
    -- direct bearing input is used
    self.displayName = ""  	
  else
    -- scan is used
	self.valueBearingDirect = nil
	self.action = ""
  end
  
  -- make bearing scan line invisible in case of direct input 
  self:hideBearingScanLine ( directInput )
	
  -- if direct input is active disable buttons
  self:enableLeftRightScan ( not directInput )
  self:enableCourseToggle ( not directInput )

  -- display slope / course  
  if ( directInput ) then
    local courseType, dir

    if ( self.mode == 1 ) then
      courseType = "Slope"
	    dir = self:getWindDir (self.valueBearingDirect )
    elseif ( self.mode == 2 ) then 
	    courseType = "F3B-course"
	    dir = self.valueBearingDirect
	  end
	
	  self.action = string.format("%s: %s (%.0f%s)", courseType, self:getDirDesc(dir), dir, utf8.char (176) )

    form.setButton(5, "Ok", ENABLED)
  end  	
end

-------------------------------------------------------------------------------------------
function slopeMgrForm:initSlopeForm (formID)

  local formTitle, directInputText, scanText, toggleButtonText

  -- clear memory for new challenge
  collectgarbage("collect") 

  -- set initial F3F/F3B mode from slope object
  if ( not self.mode) then
     self.mode = self.slope.mode
  end	 
  
  -- reset display action
  self.displayName = ""
  self.action = ""

  -- display texts for F3F / F3B
  if ( self.mode == 1 ) then
    formTitle = "Setup F3F-Slope"
	directInputText = "direct input wind direction:"
	scanText = "Slope"
	toggleButtonText = "F3B"
  elseif ( self.mode == 2 ) then
    formTitle = "Setup F3B-Course"
	directInputText = "direct input course bearing:"
	scanText = "A-Line"
	toggleButtonText = "F3F"
  end

  form.setTitle ( formTitle )
  
  -- direct input of wind direction
  form.addRow(2)
  form.addLabel({label = directInputText, width = 240}) -- 120
  self.intBoxBearing = form.addIntbox (-1, -2, 360, -1, 0, 1, function (value) self:bearingChanged (value) end, {enabled=true, visible = true, width = 65, label = utf8.char (176)})
  form.addSpacer (150, 2)
  form.addLabel({label="-------------------------------------------------------------------------------------------------", font=FONT_MINI})
  form.addSpacer (150, 2)
  
  -- scan section
  form.addRow(4)
  form.addLabel({label = "Scan", width = 140, font=FONT_BOLD})
  form.addLabel({label="Start:", width=50, font=FONT_NORMAL})
  self.checkBoxSlope = form.addCheckbox( false, nil, {enabled=false, width = 30})
  form.addLabel({label = " ", width = 10, font=FONT_NORMAL})

  form.addRow(6)
  self.bearScan[1] = form.addLabel({label = scanText .. ":", width=75, font=FONT_BOLD})
  self.bearScan[2] = form.addLabel({label="Left:", width=45, font=FONT_NORMAL})
  self.checkBoxBearingL = form.addCheckbox( false, nil, {enabled=false, width = 30})

  self.bearScan[3] = form.addLabel({label="----------", width=70, font=FONT_NORMAL})
  self.bearScan[4] = form.addLabel({label="Right:", width=53, font=FONT_NORMAL})
  self.checkBoxBearingR = form.addCheckbox( false, nil, {enabled=false, width = 30})

  -- setup buttons
  form.setButton(1, "Start", ENABLED)
  form.setButton(2, "Left", ENABLED)
  form.setButton(3, "Right", ENABLED)
  form.setButton(4, toggleButtonText, ENABLED)
  
  -- course already defined - and matches current selected course type?  
  if ( self.slope:isDefined () and ( self.slope.mode == self.mode )) then
    self.displayName = self.slope.name
	
    -- display it
    local courseType, dir

    if ( self.mode == 1 ) then
      courseType = "Slope"
      dir = self:getWindDir (self.slope.bearing )
    elseif ( self.mode == 2 ) then 
	  courseType = "F3B-course"
      dir = self.slope.bearing
	  end
	  self.action = string.format("%s: %s (%.0f%s)", courseType, self:getDirDesc(dir), dir, utf8.char (176) )

    if ( not self.gpsSens:isValidPosition (self.slope.gpsHome) ) then
      self.action = self.action .. " - no SP"
    end  
  end  
  
  -- show a cancel button, until data is complete
  form.setButton(5, "Cancel", ENABLED)

  -- local freeMem = collectgarbage("count");
  -- print("GC Count after slopemgr init : " .. freeMem .. " kB");
end

--------------------------------------------------------------------------------------------
  -- Section Key Handling
--------------------------------------------------------------------------------------------
function slopeMgrForm:scanGpsPoint ( checkBox, successMsg )

-- get GPS-position from Sensor
  local gpsPoint
  gpsPoint = self.gpsSens:getCurPosition ()  
	
  if (self.globalVar.errorStatus >0) then
     self.action = self.errorTable [self.globalVar.errorStatus][1].." "
                 ..self.errorTable [self.globalVar.errorStatus][2].." "
                 ..self.errorTable [self.globalVar.errorStatus][3]
  end

  if (  gpsPoint ) then                                        
     -- set status information   
     if ( checkBox ) then form.setValue(checkBox, true ) end
     if ( successMsg ) then self.action = successMsg end
  end 

  return gpsPoint
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:checkDataComplete()

  local complete = false
  
  -- .. case of direct bearing input   
  if ( self.valueBearingDirect ) then      -- allow without Home Position
    self.bearing = self.valueBearingDirect
	  complete = true

   -- .. case of slope / A-Line - scan
  elseif ( self.gpsNewHome and self.gpsBearLeft and self.gpsBearRight ) then
    self.bearing = gps.getBearing ( self.gpsBearLeft, self.gpsBearRight )

    -- in case of A-Line scan (F3B) flight course is -90 deg. from scanned A-Line
    if ( self.mode == 2 ) then
      self.bearing = self.bearing - 90
      if self.bearing < 0 then self.bearing = self.bearing + 360 end
    end

	  complete = true
  end

  -- display wind direction (F3F) and enable 'ok'
  if ( complete and self.mode == 1 ) then
    local dir = self:getWindDir (self.bearing) 	
    self.action = string.format("%s: %s (%.0f%s)", "Slope", self:getDirDesc(dir), dir, utf8.char (176) )
    form.setButton(5, "Ok", ENABLED)

  -- display course (F3B) and enable 'ok'
  elseif ( complete and self.mode == 2 ) then
    self.action = string.format("%s: %s (%.0f%s)", "F3B-course", self:getDirDesc(self.bearing), self.bearing, utf8.char (176) )
    form.setButton(5, "Ok", ENABLED)
  end   
end

--------------------------------------------------------------------------------------------
-- observe keys of scan page
function slopeMgrForm:slopeScanKeyPressed(key)

   -- start button
   if(key==KEY_1) then
     self.gpsNewHome = self:scanGpsPoint ( self.checkBoxSlope, "Starting position set" )
     self:checkDataComplete ()

   -- button bearing left 
   elseif(key==KEY_2 and self.leftRightScanEnabled) then
     self.gpsBearLeft = self:scanGpsPoint ( self.checkBoxBearingL, "Left bearing point set" )
     self:checkDataComplete ()

   -- button bearing right
   elseif(key==KEY_3 and self.leftRightScanEnabled) then
     self.gpsBearRight = self:scanGpsPoint ( self.checkBoxBearingR, "Right bearing point set" )
     self:checkDataComplete ()

   -- toggle F3F/F3B-mode
   elseif(key==KEY_4 and self.courseTypeToggleEnabled) then
       if ( self.mode == 1) then self.mode = 2
       elseif ( self.mode == 2) then self.mode = 1 end
       form.reinit (1)
   end
   
   -- disable F3F/F3B toggle button and hide course name if scan is started
   if ( self.gpsNewHome or self.gpsBearLeft or self.gpsBearRight ) then
     self:enableCourseToggle ( false )
     self.displayName = ""   
   end

   -- button OK	/ Cancel 
   if(key==KEY_5) then
   
     -- data complete ?
     if ( self.valueBearingDirect ) then
       self.bearing = self.valueBearingDirect
     end

     if ( self.bearing ) then

       -- home not set - save anyway ?  
       if ( not self.gpsNewHome ) then   
         local answer = form.question ( "Save Course bearing ?", "No Starting point set", "Must be defined later", 0, false, 500 )

         -- 'YES' pressed
         if ( answer == 1 ) then
           self.gpsNewHome = gps.newPoint ( 0, 0 )   -- somewhere in the golf on guinea - we use this as invalid position

         else 
           -- play cancel beep and return
           system.playBeep (2, 1000, 200)
           return
         end   
       end

       -- F3B: calc home position, half distance away from scanned start (if home defined)
       --      and set A-Base always to left
       if (self.mode == 2) then
         if ( self.gpsSens:isValidPosition (self.gpsNewHome) ) then   
           self.gpsNewHome = gps.getDestination ( self.gpsNewHome, self.f3bDist / 2, self.bearing )
         end

         self.slope.aBase = self.globalVar.direction.LEFT
       end

       -- set values to slope object and save
       self.slope.gpsHome = self.gpsNewHome
       self.slope.bearing = self.bearing
       self.slope.mode = self.mode
       self.slope.name = nil           -- new course scan has no name yet
       self.slope:persist ()

       -- ok - beep
       system.playBeep (0, 700, 300)  
     else
       -- cancel - beep
       system.playBeep (2, 1000, 200)
     end
   end
end  

--------------------------------------------------------------------------------------------
  -- Section Display
--------------------------------------------------------------------------------------------
-- calculate wind direction
function slopeMgrForm:getWindDir ( bearing )

  -- get wind direction from slope bearing
  local windDir
  if bearing < 90 then windDir = bearing + 270 else windDir = bearing - 90 end
 
  return windDir
end
 
--------------------------------------------------------------------------------------------
-- get Description
function slopeMgrForm:getDirDesc ( dir )

  local dirDesc = "undefined"
  local angle, low, high
	  
 -- read direction descriptions from file
 local filespec = self.dataDir .. "/direct-" ..self.globalVar.lng.. ".jsn"	  
 local desc
 local file = io.readall( filespec )

  if( file ) then
     desc = json.decode(file)
  else
     self.handleErr ("can not open file: '" ..filespec .."'")	  
  end

  -- find 
  for i = 0, 15, 1 do
     angle = i * 22.5

     -- calculate range for direction
     low = angle - 11.25
     if low < 0 then low = low+360 end
     local high = angle + 11.25
     if high > 360 then high = high -360 end

     -- inside ?
     local inside = false
	 if ( i==0 and ( dir > low or dir < high ) ) then
	 inside = true	 
     elseif ( dir > low and dir < high) then 
	 inside = true 
	 end	
	 if ( inside ) then
        if (desc) then dirDesc = desc [i+1] end
        break
     end
  end
  return dirDesc
end

--------------------------------------------------------------------------------------------
function slopeMgrForm:printSlopeForm()
   if ( self.displayName and self.displayName ~= "" ) then
      lcd.drawText(20,90, self.displayName .. ":", FONT_BIG)   
   end
   lcd.drawText(20,115, self.action, FONT_BIG)   
end  

--------------------------------------------------------------------------------------------
return slopeMgrForm
