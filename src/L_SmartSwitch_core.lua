-- MiOS "Smart Switch" Plugin
--
-- Copyright (C) 2012  Hugh Eaves
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
local json = g_dkjson
local log = g_log
local util = g_util

-- CONSTANTS

-- Plug-in version
local PLUGIN_VERSION = "0.7"
local LOG_PREFIX = "SmartSwitch"
local DATE_FORMAT = "%m/%d/%y %H:%M:%S"

-- value assigned to timeout when there is no timeout
local NO_TIMEOUT = 2147483647

local MODE = {
	OFF = "Off",
	AUTO = "Auto",
	MANUAL = "Manual"
}

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
	SECURITY_SENSOR = "urn:micasaverde-com:serviceId:SecuritySensor1"
}

local DID_SMART_SWITCH_CONTROLLER = "urn:schemas-hugheaves-com:device:SmartSwitchController:1"

local DEFAULT_LOG_CONFIG = {
	["version"] = 1,
	["files"] = {
		["./*L_SmartSwith_log.lua$"] = {
			["level"] = log.LOG_LEVEL_INFO,
			["functions"] = {
			}
		},
		["./*L_SmartSwitch_util.lua$"] = {
			["level"] = log.LOG_LEVEL_INFO,
			["functions"] = {
			}
		},
	}
}

-- GLOBALS

-- Indexed by SwitchId
g_switches = {
-- smartSwitchId
-- sensors
}

-- Indexed by SensorId
g_sensors = {
-- switches
}

-- Indexed by SmartSwitchId
g_smartSwitches = {
-- switchId
}

-- Holds a stack of currently scheduled processTimeouts tasks scheduled by "call_delay"
g_scheduledTimeouts = {}

g_deviceId = nil
g_taskHandle = -1

-- Set light level on target switch
local function setSwitchLevel(switchId, level)
	log.info ("Setting Switch Level: switchId = ", switchId, ", level = ", level)

	local lul_settings = {}
	local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments

	local smartSwitchId = g_switches[tonumber(switchId)].smartSwitchId

	if (luup.device_supports_service(SID.DIMMER, tonumber(switchId))) then
		lul_settings.newLoadlevelTarget = level

		util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", level, smartSwitchId)

		lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.DIMMER,
		"SetLoadLevelTarget", lul_settings, tonumber(switchId))

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
end

----------------------------------------------
------ TIMEOUT SCHEDULING / HANDLING ---------
----------------------------------------------

-- Figure out if we need a new call_delay to handle the newTimeout
local function scheduleTimeout(newTimeout)
	log.debug ("Scheduling new timeout for ", os.date(DATE_FORMAT,newTimeout))

	local currentTime = os.time()

	-- cleanup expired timeouts
	log.debug ("Cleaning up expired timeouts in g_scheduledTimeouts")
	for i = #g_scheduledTimeouts, 1, -1 do
		if (g_scheduledTimeouts[i] <= currentTime) then
			table.remove(g_scheduledTimeouts, i)
			log.debug ("Removed old timeout [", i, "] @ ", os.date(DATE_FORMAT, g_scheduledTimeouts[i]))
		end
	end

	-- check to see if we need to add a new timeout
	log.debug ("Checking if we need to add a new timeout to g_scheduledTimeouts")
	if (#g_scheduledTimeouts == 0 or g_scheduledTimeouts[#g_scheduledTimeouts] > newTimeout) then
		table.insert(g_scheduledTimeouts, newTimeout)
		log.debug ("Added new timeout [", #g_scheduledTimeouts, "] @ ", os.date(DATE_FORMAT, g_scheduledTimeouts[#g_scheduledTimeouts]))
		local timeoutInterval = newTimeout - currentTime
		if (timeoutInterval < 0) then
			timeoutInterval = 0
		end
		log.info ("Adding new call_delay to execute processTimeouts in ", timeoutInterval, " seconds")
		luup.call_delay("processTimeouts", timeoutInterval, g_deviceId, true)
	else
		log.debug ("New call_delay of processTimeouts not needed, existing call scheduled for ", os.date(DATE_FORMAT,g_scheduledTimeouts[#g_scheduledTimeouts]))
	end
end

local function updateSwitchTimeout(switchId)
	log.debug ("updating timeout for switch ", switchId)

	local tripped = false
	local smartSwitchId = g_switches[switchId].smartSwitchId

	for sensorId, status in pairs(g_switches[switchId].sensors)  do
		if (util.getLuupVariable(SID.SECURITY_SENSOR, "Tripped", tonumber(sensorId), util.T_BOOLEAN)) then
			tripped = true
		end
	end

	if (tripped) then
		log.debug ("One or more sensors for switch ", switchId, " are still tripped. Not updating switch timeout.")
	else
		local currentTime = os.time()
		local newTimeout = NO_TIMEOUT
		local varName
		local currentMode = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", smartSwitchId, util.T_STRING)
		if (currentMode == MODE.AUTO) then
			newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", smartSwitchId, util.T_NUMBER)
		elseif (currentMode == MODE.MANUAL) then
			newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", smartSwitchId, util.T_NUMBER)
		else
			log.debug ("Sensor state reset, but switch ", switchId, " does not have an active timeout.")
		end

		if (newTimeout ~= NO_TIMEOUT) then
			log.info ("Switch ", switchId, ": setting timeout to ", os.date(DATE_FORMAT, newTimeout), " ( currentMode = ", currentMode, " )")
			util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", newTimeout, smartSwitchId)
			scheduleTimeout (newTimeout)
		end
	end
end

function processTimeouts (data)
	log.info("Starting processTimeouts")
	local nextTimeout = NO_TIMEOUT
	local currentTime = os.time()

	for switchId, state in pairs(g_switches) do
		local smartSwitchId = state.smartSwitchId
		local timeout = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", smartSwitchId, util.T_NUMBER)
		log.debug ("Switch ", switchId, " has a timeout set for ", os.date(DATE_FORMAT, timeout))
		if (timeout <= currentTime) then
			log.info ("Timeout has expired, so turning off switch ", switchId, "( currentMode = ",
			util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", smartSwitchId, util.T_STRING)," )")
			setSwitchLevel(switchId, util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", smartSwitchId, util.T_NUMBER))
			util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.OFF, smartSwitchId)
			util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Timeout", NO_TIMEOUT, smartSwitchId)
		elseif (timeout < nextTimeout) then
			nextTimeout = timeout
		end
	end

	log.debug ("Done with processTimeouts, nextTimeout = ", os.date(DATE_FORMAT, nextTimeout))

	if (nextTimeout < NO_TIMEOUT) then
		scheduleTimeout(nextTimeout)
	else
		log.debug ("There are no remaining active timeouts")
	end
end

-------------------------------------
----- SENSOR ADD / REMOVE LOGIC -----
-------------------------------------

local function initSensorState (sensorId)
	log.debug ("Initializing sensor state for sensor #", sensorId)
	g_sensors[sensorId] = {
		switches = {}
	}
end

local function addSensor(sensorId, switchId)
	log.debug ("addSensor: sensorId = ", sensorId, " switchId = ", switchId)
	if (not g_sensors[sensorId]) then
		initSensorState (sensorId)
	end
	g_sensors[sensorId].switches[switchId] = 1
	g_switches[switchId].sensors[sensorId] = 1
end

local function removeSensor(sensorId, switchId)
	log.debug ("removeSensor: sensorId = ", sensorId, " switchId = ", switchId)
	g_sensors[sensorId].switches[switchId] = nil
	g_switches[switchId].sensors[sensorId] = nil
end

------------------------------------------
-------- RUN / JOB HANDLERS --------------
------------------------------------------

local function setOnLevel(smartSwitchId, level)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OnLevel", level, smartSwitchId)
end

local function setOffLevel(smartSwitchId, level)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", level, smartSwitchId)
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

-- function to handle UPnP api calls
local function dispatchRun(lul_device, lul_settings, serviceId, action)
	log.info ("Entering dispatchRun, lul_device = ", lul_device, ", serviceId = " , serviceId , ", action = " , action ,
	", lul_settings = " , (lul_settings))

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

	updateSwitchTimeout(switchId)
end


local function sensorTripped(sensorId)
	log.info ("Sensor tripped, deviceId = ", sensorId);
	
	for switchId in pairs(g_sensors[sensorId].switches) do
		local smartSwitchId = g_switches[switchId].smartSwitchId
		local autoTimeout = util.getLuupVariable(
		SID.SMART_SWITCH_CONTROLLER, "AutoTimeout",smartSwitchId, util.T_NUMBER)
		local currentMode = util.getLuupVariable(
		SID.SMART_SWITCH_CONTROLLER, "Mode",smartSwitchId, util.T_STRING)

		-- only change to "auto" mode if we are not already in manual mode
		-- and there is an autoTimeout value
		if (currentMode == MODE.OFF and autoTimeout > 0) then
			setSwitchLevel(switchId, util.getLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "OnLevel", smartSwitchId, util.T_NUMBER))
			util.setLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "Mode", MODE.AUTO, smartSwitchId)
		elseif (currentMode == MODE.AUTO) then  -- if we are already in auto mode, clear the current timeout
			util.setLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "Timeout", NO_TIMEOUT, smartSwitchId)
		end

	end
end


local function sensorReset(sensorId)
	log.info ("Sensor reset, deviceId = ", sensorId);
	for switchId in pairs(g_sensors[sensorId].switches) do
		updateSwitchTimeout(switchId)
	end
end

--------------------------------------
-------- CALLBACK HANDLERS -----------
--------------------------------------

function sensorCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	log.debug("sensorCallback: lul_device = ", lul_device, ", type(lul_device) = ", type(lul_device),
	", lul_service = ", lul_service,
	", lul_variable = ", lul_variable,
	", lul_value_old = ", lul_value_old,
	", lul_value_new = ", lul_value_new)

	lul_device = tonumber(lul_device)

	if (not g_sensors[lul_device]) then
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
	log.debug("switchCallback: lul_device = ", lul_device, ", type(lul_device) = ", type(lul_device),
	", lul_service = ", lul_service,
	", lul_variable = ", lul_variable,
	", lul_value_old = ", lul_value_old,
	", lul_value_new = ", lul_value_new)

	local lul_device = tonumber(lul_device)

	-- If this is a dimmer, ignore "Status" (we look at LoadLevelStatus instead)
	if (lul_variable == "Status" and luup.device_supports_service(SID.DIMMER, switchId)) then
		return
	end

	local newLevel = convertSwitchLevel(lul_variable, lul_value_new)

    -- Check to see if this is a switch that we recognize / care about
	if (g_switches[lul_device]) then
		local smartSwitchId = g_switches[lul_device].smartSwitchId

		local currentLevel = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "Level", smartSwitchId, util.T_NUMBER)

		-- Got level in switch callback that doesn't match our current level.
		if (newLevel ~= nil and newLevel ~= currentLevel) then
			log.info ("Received manual override for switch: switchId = ", lul_device, ", smartSwitchId = ", smartSwitchId,
			"currentLevel = ", currentLevel, " , newLevel = ", newLevel)

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
	SID.SMART_SWITCH_CONTROLLER..",Timeout=" .. NO_TIMEOUT .. "\n"..
	SID.SMART_SWITCH_CONTROLLER..",OnLevel=100\n"..
	SID.SMART_SWITCH_CONTROLLER..",OffLevel=0\n"..
	SID.SMART_SWITCH_CONTROLLER..",AutoTimeout=300\n"..
	SID.SMART_SWITCH_CONTROLLER..",ManualTimeout=1800\n"..
	SID.SMART_SWITCH_CONTROLLER..",SensorIds=[]"
end

local function initSwitchState(switchId, smartSwitchId)
	log.debug ("Initializing switch state for switch #", switchId, ", smart switch #", smartSwitchId)
	g_switches[switchId] = {
		smartSwitchId = smartSwitchId,
		sensors = {}
	}
end

local function initSmartSwitch(smartSwitchId)
	local switchId = tonumber(luup.devices[smartSwitchId].id)
	log.debug ("initializing smart switch for switchId = ",switchId, "smartSwitchId = ",smartSwitchId)

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
	log.debug ("g_switches = ", g_switches)
	log.debug ("g_sensors = ", g_sensors)
	log.debug ("g_smartSwitches = ", g_smartSwitches)
end

-- Synchronize the Smart Switch Controller devices
local function syncChildDevices()
	local switchIds = util.getLuupVariable(SID.SMART_SWITCH, "SwitchIds", g_deviceId, util.T_TABLE)
	log.debug ("switchIds = ", switchIds)

	local validSwitchIds = {}

	local rootPtr = luup.chdev.start(g_deviceId)

	for index, switchIdStr in pairs(switchIds) do
		local switchId = tonumber(switchIdStr)
		if (luup.devices[switchId] ~= nil) then
			log.debug ("syncing switchId = ", switchId)

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

	util.initLogging(LOG_PREFIX, DEFAULT_LOG_CONFIG, SID.SMART_SWITCH, g_deviceId)

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
	dispatchRun=dispatchRun
}
		