-- MiOS "Smart Switch" Plugin
--
-- Copyright (C) 2014  Hugh Eaves
--
-- This program is free software: you can redistribute it and/or modify
-- it under the terms of the GNU General Public License as published by
-- the Free Software Foundation, either version 3 of the License, or
-- (at your option) any later version.
--
-- This program is distributed in the hope that it will be useful,
-- but WITHOUT ANY WARRANTY; without even the implied warranty of
-- MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
-- GNU General Public License for more details.
--
-- You should have received a copy of the GNU General Public License
-- along with this program.  If not, see <http://www.gnu.org/licenses/>.


-- IMPORT GLOBALS
local luup = luup
local string = string
local require = require
local math = math
local log = require("L_" .. g_pluginName .. "_" .. "log")
local util = require("L_" .. g_pluginName .. "_" .. "util")
local json = require("L_" .. g_pluginName .. "_" .. "dkjson")

-- CONSTANTS

-- Plug-in version
local PLUGIN_VERSION = "1.2"
local LOG_PREFIX = "SmartSwitch"
local DATE_FORMAT = "%m/%d/%y %H:%M:%S"

-- value assigned to timeout when there is no timeout
local FAR_FUTURE_TIME = 2147483647

-- current "mode" of smart switch
local MODE = {
  OFF = "Off",
  AUTO = "Auto",
  MANUAL = "Manual"
}

local PRE_TIMEOUT_POLL_DELAY = 5

-- TASK status stolen from mios_vista-alarm-panel
local TASK = {
  ERROR = 2,
  ERROR_PERM = -2,
  SUCCESS = 4,
  BUSY = 1
}

local SID = {
  SWITCH = "urn:upnp-org:serviceId:SwitchPower1",
  DIMMER = "urn:upnp-org:serviceId:Dimming1",
  SMART_SWITCH = "urn:hugheaves-com:serviceId:SmartSwitch1",
  SMART_SWITCH_CONTROLLER = "urn:hugheaves-com:serviceId:SmartSwitchController1",
  SECURITY_SENSOR = "urn:micasaverde-com:serviceId:SecuritySensor1",
  ZWAVE_DEVICE = "urn:micasaverde-com:serviceId:ZWaveDevice1",
  HA_DEVICE = "urn:micasaverde-com:serviceId:HaDevice1"
}

local DID_SMART_SWITCH_CONTROLLER = "urn:schemas-hugheaves-com:device:SmartSwitchController:1"

local DEFAULT_LOG_CONFIG = {
  ["version"] = 1,
  ["files"] = {
    ["./*L_SmartSwith_log.lua$"] = {
      ["level"] = log.LOG_LEVEL_DEBUG,
      ["functions"] = {
      }
    },
    ["./*L_SmartSwitch_util.lua$"] = {
      ["level"] = log.LOG_LEVEL_DEBUG,
      ["functions"] = {
      }
    },
  }
}

local logConfig = DEFAULT_LOG_CONFIG

-- GLOBALS

-- Maps switch devices to smart switch ids, and a list of sensors for that switch
g_switches = {
  -- smartSwitchId
  -- sensors
  }

-- Maps sensor device ids to switches that use that sensor
g_sensors = {
  -- switches
  }

-- Maps a smart switch id to a switch id
g_smartSwitches = {
  -- switchId
  }

-- Holds a stack of currently scheduled checkSwitches calls
g_scheduledCalls = {}

g_deviceId = nil
g_taskHandle = -1

----------------------------------------------------
-- FUNCTIONS
----------------------------------------------------

-- Set light level on target switch
local function setSwitchLevel(switchId, level)
  log.infoValues ("Setting Switch Level", "switchId", switchId, "level", level)

  local lul_settings = {}
  local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments

  local smartSwitchId = g_switches[tonumber(switchId)].smartSwitchId

  -- If the target device is a dimmer
  if (luup.device_supports_service(SID.DIMMER, tonumber(switchId))) then
    lul_settings.newLoadlevelTarget = level

    util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", level, smartSwitchId)

    lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.DIMMER,
      "SetLoadLevelTarget", lul_settings, tonumber(switchId))

    -- else, if the target device is a binary switch
  elseif (luup.device_supports_service(SID.SWITCH, tonumber(switchId))) then
    if (level == 0) then
      lul_settings.newTargetValue = 0
      util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", "0", smartSwitchId)
    else
      lul_settings.newTargetValue = 1
      util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", "100", smartSwitchId)
    end

    local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.SWITCH,
      "SetTarget", lul_settings, tonumber(switchId))
  end

  log.debug("Returning")
end

local function turnOffSwitch(smartSwitchId)
  -- get the device id for this smart switch
  local switchId = g_smartSwitches[smartSwitchId].switchId

  log.infoValues ("Turning off switch", "switchId", switchId, "currentMode",
    util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", smartSwitchId, util.T_STRING))
  setSwitchLevel(switchId, util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", smartSwitchId, util.T_NUMBER))
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.OFF, smartSwitchId)
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", FAR_FUTURE_TIME, smartSwitchId)
end


-- Sets the light level of the switch to match the current OnLevel/OffLevel
local function updateSwitchLevel(smartSwitchId)
  log.info ("Updating Switch Level: smartSwitchId = ", smartSwitchId)

  local currentMode = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", smartSwitchId, util.T_STRING)
  local switchId = g_smartSwitches[smartSwitchId].switchId

  if (currentMode == MODE.AUTO) then
    setSwitchLevel(switchId, util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OnLevel", smartSwitchId, util.T_NUMBER))
  elseif (currentMode == MODE.OFF) then
    setSwitchLevel(switchId, util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", smartSwitchId, util.T_NUMBER))
  end
end

----------------------------------------------
------ TIMEOUT SCHEDULING / HANDLING ---------
----------------------------------------------
--
local function checkSwitch(currentTime, smartSwitchId)
  local switchId = g_smartSwitches[smartSwitchId].switchId
  local timeout = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", smartSwitchId, util.T_NUMBER)
  local nextWakeup = timeout

  log.debugValues ("Current switch timeout", "smartSwitchId",smartSwitchId, "timeout", os.date(DATE_FORMAT, timeout))

  -- if the timeout has expired for this switch (i.e. timeout is before currentTime), then turn it off
  if (timeout <= currentTime) then

    log.infoValues("Timeout has expired, turning off switch", "smartSwitchId", smartSwitchId, "switchId", switchId)

    turnOffSwitch(smartSwitchId)

  elseif (timeout ~= FAR_FUTURE_TIME) then
    -- else, if the switch hasn't yet timed out

    -- handle scheduling a "pre-timeout" poll for Z-wave devices
    if (luup.device_supports_service(SID.ZWAVE_DEVICE, tonumber(switchId))) then

      -- calculate when we should be polling the switch
      local pollTime = timeout - PRE_TIMEOUT_POLL_DELAY

      -- if pollTime has arrived (or passed), then check if we have already polled the switch recently
      if (pollTime <= currentTime) then
        local lastPollTime = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "LastPollTime", smartSwitchId, util.T_NUMBER)
        if (currentTime - lastPollTime > PRE_TIMEOUT_POLL_DELAY) then
          log.debugValues("Polling switch before timeout", "timeout", timeout, "pollTime", pollTime, "lastPollTime", lastPollTime , "currentTime", currentTime)
          luup.call_action(SID.HA_DEVICE, "Poll", {}, switchId)
          util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "LastPollTime", currentTime, smartSwitchId)
        else
          log.debugValues("Switch poll not needed", "timeout", timeout, "pollTime", pollTime, "lastPollTime", lastPollTime , "currentTime", currentTime)
        end
      else
        -- as pollTime has not arrived yet, schedule next wakeup at pollTime
        nextWakeup = pollTime
        log.debugValues("pollTime has not arrived, scheduling wakeup at pollTime", "timeout", timeout, "pollTime", pollTime , "currentTime", currentTime)
      end


    else
      log.debugValues("target switch is not a ZWave device, scheduling wakeup at normal timeout", "timeout", timeout, "currentTime", currentTime)

    end
  end

  return nextWakeup
end

-- Find the next (earliest) scheduled call time in the g_scheduledCalls table
local function getNextWakeup()
  log.debugValues("", "#g_scheduledCalls", #g_scheduledCalls)
  local nextWakeup = FAR_FUTURE_TIME
  for i = #g_scheduledCalls, 1, -1 do
    log.debug ("g_scheduledCalls[", i, "] = ", os.date(DATE_FORMAT, g_scheduledCalls[i]))
    if (g_scheduledCalls[i] < nextWakeup) then
      nextWakeup = g_scheduledCalls[i]
    end
  end
  log.debug("Next wakeup is ", os.date(DATE_FORMAT, nextWakeup))
  return nextWakeup
end


-- Remove the next (earliest) scheduled call time in the g_scheduledCalls table
local function removeNextWakeup()
  log.debugValues("", "#g_scheduledCalls", #g_scheduledCalls)
  local nextWakeup = FAR_FUTURE_TIME
  local foundIndex = 0;
  for i = #g_scheduledCalls, 1, -1 do
    log.debug ("g_scheduledCalls[", i, "] = ", os.date(DATE_FORMAT, g_scheduledCalls[i]))
    if (g_scheduledCalls[i] < nextWakeup) then
      nextWakeup = g_scheduledCalls[i]
      foundIndex = i
    end
  end
  if (foundIndex > 0) then
    log.debug("removing g_scheduledCall[",foundIndex,"]")
    table.remove(g_scheduledCalls, foundIndex)
  end
end


-- Add a new scheduled call
local function addWakeup(currentTime, wakeupTime, functionName)
  local timeRemaining = wakeupTime - currentTime

  table.insert(g_scheduledCalls, wakeupTime)

  luup.call_delay(functionName, timeRemaining, g_deviceId, true)

  log.infoValues ("Scheduled new wakeup", "functionName", functionName, "wakeupTime", os.date(DATE_FORMAT, wakeupTime), "timeRemaining", timeRemaining)
end

--[[
Schedule a call back at "wakeupTime".

This function doesn't actually schedule a new callback for every
invocation. A new callback is not scheduled if there is an existing callback scheduled
before wakeupTime.
]]
local function scheduleNextWakeup(wakeupTime)
  local currentTime = os.time()

  log.debugValues ("Entering scheduleNextWakeup", "wakeupTime", os.date(DATE_FORMAT,wakeupTime), "currentTime", os.date(DATE_FORMAT,currentTime))

  if (wakeupTime == FAR_FUTURE_TIME) then
    log.debug("scheduleNextWakeup called with far future time. Not scheduling a call.")
    return
  end
  -- callbacks with a checkTime in the past are scheduled at the current time instead
  if (wakeupTime < currentTime) then
    log.infoValues ("scheduleNextWakeup called with time in the past", "wakeupTime", os.date(DATE_FORMAT,wakeupTime), "currentTime", os.date(DATE_FORMAT,currentTime))
    wakeupTime = currentTime
  end

  local nextWakeup = getNextWakeup()

  -- only add a new callback if checkTime occurs before nextWakeup
  if (wakeupTime < nextWakeup) then
    log.debugValues ("Adding new wakeup call ","wakeupTime", os.date(DATE_FORMAT,wakeupTime))
    addWakeup(currentTime, wakeupTime, "checkSwitches")
  else
    log.debug ("New call_delay of checkSwitches not needed, existing call scheduled for ", os.date(DATE_FORMAT,nextWakeup))
  end
end

-- This function is called whenever an event occurs that may require
-- calculating a new timeout for a switch. This includes sensor resets,
-- manual activations, or adjustment of the timeout settings for
-- a particular switch.
local function updateSwitchTimeout(switchId)
  log.debugValues ("updating timeout for switch", "switchId", switchId)

  local tripped = false
  local smartSwitchId = g_switches[switchId].smartSwitchId

  -- Check to see if any of the sensors that control this switch are in "tripped" state.
  -- If so, we don't need to do anything with the timeout value.
  for sensorId, status in pairs(g_switches[switchId].sensors)  do
    if (util.getLuupVariable(SID.SECURITY_SENSOR, "Tripped", tonumber(sensorId), util.T_BOOLEAN)) then
      log.debugValues("Sensor is still tripped", "sensorId", sensorId)
      tripped = true
    end
  end

  if (tripped) then
    -- no need to schedule a timeout for a switch with a sensor that hasn't reset yet (the
    -- timeout will be scheduled when the sensor actually resets).
    log.debugValues ("One or more sensors for switch are still tripped. Not updating switch timeout.", "switchId", switchId)
  else
    local currentTime = os.time()
    local newTimeout = FAR_FUTURE_TIME
    local currentMode = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", smartSwitchId, util.T_STRING)

    if (currentMode == MODE.AUTO) then
      newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", smartSwitchId, util.T_NUMBER)
    elseif (currentMode == MODE.MANUAL) then
      newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", smartSwitchId, util.T_NUMBER)
    else
      log.infoValues ("Sensor state reset, but switch was already turned off.", "switchId",switchId)
    end

    if (newTimeout ~= FAR_FUTURE_TIME) then
      log.infoValues ("Setting new timeout for switch", "switchId",switchId, "newTimeout", os.date(DATE_FORMAT, newTimeout), "currentMode", currentMode)
      util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", newTimeout, smartSwitchId)
      scheduleNextWakeup (newTimeout)
    end
  end
end

-- This is the luup.call_delay callback function that is scheduled
-- by the scheduleNextWakeup() function. It checks to see if any switches
-- have "timed out" and need to be turned back off. If there are switches
-- have not timed out, this function will schedule a new timeout
-- callback for the next occurring timeout.
function checkSwitches (data)

  log.info("Starting checkSwitches")

  local currentTime = os.time()

  local nextWakeupTime = FAR_FUTURE_TIME

  removeNextWakeup()

  -- loop through all the smart switches, performing actions based
  -- on their timeout values
  for switchId, state in pairs(g_switches) do

    -- get the device id for this smart switch
    local smartSwitchId = state.smartSwitchId

    local wakeupTime = checkSwitch(currentTime, smartSwitchId)
    -- keep track of the earliest timeout of all switches that haven't timed out
    if (wakeupTime < nextWakeupTime) then
      nextWakeupTime = wakeupTime
    end
  end

  log.debugValues ("Done with checkSwitches","nextWakeupTime", os.date(DATE_FORMAT, nextWakeupTime))

  scheduleNextWakeup(nextWakeupTime)
end

-------------------------------------
----- SENSOR ADD / REMOVE LOGIC -----
-------------------------------------

local function initSensorState (sensorId)
  log.debug ("Initializing sensor state", "sensorId", sensorId)
  g_sensors[sensorId] = {
    switches = {}
  }
end

local function addSensor(sensorId, switchId)
  log.debug ("addSensor","sensorId", sensorId, "switchId", switchId)
  if (not g_sensors[sensorId]) then
    initSensorState (sensorId)
  end
  g_sensors[sensorId].switches[switchId] = 1
  g_switches[switchId].sensors[sensorId] = 1
end

local function removeSensor(sensorId, switchId)
  log.debug ("removeSensor","sensorId", sensorId, "switchId", switchId)
  g_sensors[sensorId].switches[switchId] = nil
  g_switches[switchId].sensors[sensorId] = nil
end

------------------------------------------
-------- RUN / JOB HANDLERS --------------
------------------------------------------

local function setOnLevel(smartSwitchId, level)
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OnLevel", level, smartSwitchId)
  updateSwitchLevel(smartSwitchId)
end

local function setOffLevel(smartSwitchId, level)
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", level, smartSwitchId)
  updateSwitchLevel(smartSwitchId)
end

local function setAutoTimeout(smartSwitchId, timeout)
  local switchId = g_smartSwitches[smartSwitchId].switchId
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", timeout, smartSwitchId)
  updateSwitchTimeout(switchId)
end

local function setManualTimeout(smartSwitchId, timeout)
  local switchId = g_smartSwitches[smartSwitchId].switchId
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", timeout, smartSwitchId)
  updateSwitchTimeout(switchId)
end

local function setLevel(smartSwitchId, level)
  local switchId = g_smartSwitches[smartSwitchId].switchId
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.MANUAL, smartSwitchId)
  setSwitchLevel(switchId, level)
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", level, smartSwitchId)
  updateSwitchTimeout(switchId)
end

local function setRememberManualLevel(smartSwitchId, rememberManualLevel)
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "RememberManualLevel", rememberManualLevel, smartSwitchId)
end

-- function to handle UPnP api calls
local function dispatchRun(lul_device, lul_settings, serviceId, action)
  log.infoValues ("Entering dispatchRun", "lul_device", lul_device, "serviceId" , serviceId , "action" , action ,
    "lul_settings" , (lul_settings))

  local success = true
  local lul_device = tonumber(lul_device)

  if (serviceId == SID.SMART_SWITCH_CONTROLLER) then
    if (action == "SetLevel") then
      setLevel(lul_device, tonumber(lul_settings.NewLevel))
    elseif (action == "SetOnLevel") then
      setOnLevel(lul_device, tonumber(lul_settings.NewLevel))
    elseif (action == "SetOffLevel") then
      setOffLevel(lul_device, tonumber(lul_settings.NewLevel))
    elseif (action == "SetAutoTimeout") then
      setAutoTimeout(lul_device, tonumber(lul_settings.NewTimeout))
    elseif (action == "SetManualTimeout") then
      setManualTimeout(lul_device, tonumber(lul_settings.NewTimeout))
    elseif (action == "SetRememberManualLevel") then
      setRememberManualLevel(lul_device, toboolean(lul_settings.NewRememberManualLevel))
    else
      log.error("Unrecognized job request")
    end
  else
    log.error("Unrecognized job request")
  end

  return (success)
end

----------------------------------------------
-------- CALLBACK HELPER FUNCTIONS -----------
----------------------------------------------

local function convertSwitchLevel(lul_variable, lul_value_new)
  local newLevel = nil
  if (lul_variable == "LoadLevelStatus") then
    newLevel = tonumber(lul_value_new)
  elseif (lul_variable == "Status") then
    if (lul_value_new == "0") then
      newLevel = 0
    else
      newLevel = 100
    end
  end

  return newLevel
end

local function recordManualActivation(smartSwitchId, newLevel)
  local switchId = g_smartSwitches[smartSwitchId].switchId
  local manualTimeout = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", smartSwitchId, util.T_NUMBER)

  -- only change to "manual" mode if there is a manualTimeout set
  if (manualTimeout > 0) then
    util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.MANUAL, smartSwitchId)
  end

  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", newLevel, smartSwitchId)

  if (util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "RememberManualLevel", smartSwitchId, util.T_BOOLEAN)) then
    util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OnLevel", newLevel, smartSwitchId)
  end

  updateSwitchTimeout(switchId)
end


local function sensorTripped(sensorId)
  log.infoValues ("Sensor tripped", "sensorId", sensorId);

  for switchId in pairs(g_sensors[sensorId].switches) do
    local smartSwitchId = g_switches[switchId].smartSwitchId
    local autoTimeout = util.getLuupVariable(
      SID.SMART_SWITCH_CONTROLLER, "AutoTimeout",smartSwitchId, util.T_NUMBER)
    local currentMode = util.getLuupVariable(
      SID.SMART_SWITCH_CONTROLLER, "Mode",smartSwitchId, util.T_STRING)

    -- only change to "AUTO" mode if the switch is "OFF" and there is an autoTimeout value
    if (currentMode == MODE.OFF and autoTimeout > 0) then
      setSwitchLevel(switchId, util.getLuupVariable(
        SID.SMART_SWITCH_CONTROLLER, "OnLevel", smartSwitchId, util.T_NUMBER))
      util.setLuupVariable(
        SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.AUTO, smartSwitchId)
    end

    -- clear the current timeout
    util.setLuupVariable(
      SID.SMART_SWITCH_CONTROLLER, "Timeout", FAR_FUTURE_TIME, smartSwitchId)

  end
end


local function sensorReset(sensorId)
  log.infoValues ("Sensor reset", "sensorId", sensorId);
  for switchId in pairs(g_sensors[sensorId].switches) do
    updateSwitchTimeout(switchId)
  end
end

------------------------------------------------------
-------- VARIABLE WATCH CALLBACK HANDLERS ------------
------------------------------------------------------

-- These callback functions listen for changes in the state of the "target" devices

function sensorCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
  log.debugValues("Entering sensorCallback", "lul_device", lul_device,
    "lul_service", lul_service,
    "lul_variable", lul_variable,
    "lul_value_old", lul_value_old,
    "lul_value_new", lul_value_new)

  lul_device = tonumber(lul_device)

  if (not g_sensors[lul_device]) then
    log.debug("Not a sensor we care about")
    return
  end

  if (lul_variable == "Tripped") then
    if (lul_value_new == "1" and lul_value_old == "0") then
      sensorTripped(lul_device)
    elseif (lul_value_new == "0" and lul_value_old == "1") then
      sensorReset(lul_device)
    end
  end
end

function switchCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
  log.debugValues("switchCallback", "lul_device", lul_device,
    "lul_service", lul_service,
    "lul_variable", lul_variable,
    "lul_value_old", lul_value_old,
    "lul_value_new", lul_value_new)

  local lul_device = tonumber(lul_device)

  -- If this is a dimmer, ignore "Status" (we look at LoadLevelStatus instead)
  if (lul_variable == "Status" and luup.device_supports_service(SID.DIMMER, lul_device)) then
    log.debug("Ignoring change in Status for dimmer")
    return
  end

  local newLevel = convertSwitchLevel(lul_variable, lul_value_new)

  -- Check to see if this is a switch that we recognize / care about
  if (g_switches[lul_device]) then
    local smartSwitchId = g_switches[lul_device].smartSwitchId

    local currentLevel = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", smartSwitchId, util.T_NUMBER)

    -- Check to see if we received a level in the callback that doesn't match our current level.
    if (newLevel ~= nil and newLevel ~= currentLevel) then
      log.infoValues ("Received manual override for switch","lul_device", lul_device, "smartSwitchId", smartSwitchId,
        "currentLevel", currentLevel, "newLevel", newLevel)

      recordManualActivation(smartSwitchId, newLevel)
    else
      log.debug ("received unchanged state in switch callback")
    end
  end

  -- if this switch is registered as a "sensor", process accordingly
  if (g_sensors[lul_device]) then
    if (newLevel > 0) then
      sensorTripped(lul_device)
    else
      sensorReset(lul_device)
    end
  end
end


local function setLogConfig(newLogConfig)
  logConfig = newLogConfig
end

-----------------------------------
-------- INITIALIZATION -----------
-----------------------------------

--- init Luup variables if they don't have values
local function initLuupVariables()
  util.initVariableIfNotSet(SID.SMART_SWITCH, "SwitchIds", "[]", g_deviceId)
end

local function getDefaultParameters()
  return
    SID.SMART_SWITCH_CONTROLLER..",Level=0\n"..
    SID.SMART_SWITCH_CONTROLLER..",Mode=" .. MODE.OFF .. "\n"..
    SID.SMART_SWITCH_CONTROLLER..",Timeout=" .. FAR_FUTURE_TIME .. "\n"..
    SID.SMART_SWITCH_CONTROLLER..",LastPollTime=0\n"..
    SID.SMART_SWITCH_CONTROLLER..",OnLevel=100\n"..
    SID.SMART_SWITCH_CONTROLLER..",OffLevel=0\n"..
    SID.SMART_SWITCH_CONTROLLER..",AutoTimeout=300\n"..
    SID.SMART_SWITCH_CONTROLLER..",ManualTimeout=1800\n"..
    SID.SMART_SWITCH_CONTROLLER..",SensorIds=[]\n"..
    SID.SMART_SWITCH_CONTROLLER..",RememberManualLevel=0"
end

local function initSwitchState(switchId, smartSwitchId)
  log.debugValues ("Initializing switch state", "switchId", switchId, "smartSwitchId", smartSwitchId)
  g_switches[switchId] = {
    smartSwitchId = smartSwitchId,
    sensors = {}
  }
end

local function initSmartSwitch(smartSwitchId)
  local switchId = tonumber(luup.devices[smartSwitchId].id)
  log.debugValues ("Initializing smart switch", "switchId", switchId, "smartSwitchId", smartSwitchId)

  initSwitchState(switchId, smartSwitchId)

  local sensorIds = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", smartSwitchId, util.T_TABLE)
  local validSensorIds = {}

  for index, sensorId in pairs(sensorIds) do
    if (luup.devices[tonumber(sensorId)] ~= nil) then
      table.insert(validSensorIds, sensorId)
      addSensor(tonumber(sensorId), switchId)
    end
  end

  if (#sensorIds ~= #validSensorIds) then
    log.error ("Found invalid sensor id in sensor list for switch ",smartSwitchId," - old list: ", sensorIds, ", new list: ", validSensorIds)
    util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", validSensorIds, smartSwitchId)
  end

  g_smartSwitches[smartSwitchId] = { ["switchId"] = switchId }

  -- Clear out old "StatusText" variable
  util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "StatusText", "", smartSwitchId)
end

local function initSmartSwitches()
  log.info ("Finding and initializing smart switch devices for parent deviceId = ", g_deviceId)

  for deviceId, deviceData in pairs(luup.devices) do
    log.debug ("examining deviceId = ", deviceId)
    if (deviceData.device_num_parent == g_deviceId and
      deviceData.device_type == DID_SMART_SWITCH_CONTROLLER) then
      log.info ("found child SmartSwitchController device, deviceId = ", deviceId)
      initSmartSwitch(deviceId)
    end
  end

  -- Clear out old "StatusText" variable
  util.setLuupVariable(SID.SMART_SWITCH, "StatusText", "", g_deviceId)

  log.debug ("done with state initialization")
  log.debugValues ("", "g_switches", g_switches)
  log.debugValues ("", "g_sensors", g_sensors)
  log.debugValues ("", "g_smartSwitches", g_smartSwitches)
end

-- Synchronize the Smart Switch Controller devices
local function syncChildDevices()
  local switchIds = util.getLuupVariable(SID.SMART_SWITCH, "SwitchIds", g_deviceId, util.T_TABLE)
  log.debugValues ("", "switchIds", switchIds)

  local validSwitchIds = {}

  local rootPtr = luup.chdev.start(g_deviceId)

  for index, switchIdStr in pairs(switchIds) do
    local switchId = tonumber(switchIdStr)
    if (luup.devices[switchId] ~= nil) then
      log.debugValues ("syncing", "switchId", switchId)

      table.insert(validSwitchIds, switchIdStr)

      local description = "SS: " .. luup.devices[switchId].description

      luup.chdev.append(g_deviceId, rootPtr,
        switchId, description,
        DID_SMART_SWITCH_CONTROLLER,
        "D_SmartSwitchController1.xml", "", getDefaultParameters(), false)

    end
  end

  if (#switchIds ~= #validSwitchIds) then
    log.error ("Found invalid switch id in switch list, old list: ", switchIds, ", new list: ", validSwitchIds)
    util.setLuupVariable(SID.SMART_SWITCH, "SwitchIds", validSwitchIds, g_deviceId)
  end

  luup.chdev.sync(g_deviceId, rootPtr)
end

local function initialize(lul_device)
  local success = false
  local errorMsg = nil

  g_deviceId = tonumber(lul_device)

  util.initLogging(LOG_PREFIX, logConfig, SID.SMART_SWITCH, g_deviceId)

  log.info ("Initializing SmartSwitch plugin for device " , g_deviceId)
  --
  --	log.error ("luup.devices = " , luup.devices)

  -- set plugin version number
  luup.variable_set(SID.SMART_SWITCH, "PluginVersion", PLUGIN_VERSION, g_deviceId)

  initLuupVariables()

  syncChildDevices()

  initSmartSwitches()

  luup.variable_watch("switchCallback", SID.SWITCH, "Status", nil)
  luup.variable_watch("switchCallback", SID.DIMMER, "Status", nil)
  luup.variable_watch("switchCallback", SID.DIMMER, "LoadLevelStatus", nil)
  luup.variable_watch("sensorCallback", SID.SECURITY_SENSOR, "Tripped", nil)

  log.info("Done with initialization")

  return success, errorMsg, "SmartSwitch"
end


-- RETURN GLOBAL FUNCTIONS
return {
  initialize=initialize,
  dispatchRun=dispatchRun,
  checkSwitches=checkSwitches,
  sensorCallback=sensorCallback,
  switchCallback=switchCallback,
  setLogConfig=setLogConfig
}
		
