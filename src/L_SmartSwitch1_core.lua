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
local PLUGIN_VERSION = "0.1"
local LOG_PREFIX = "SmartSwitch"

local SID = {
	SWITCH = "urn:upnp-org:serviceId:SwitchPower1",
	DIMMER = "urn:upnp-org:serviceId:Dimming1",
	SMART_SWITCH = "urn:hugheaves-com:serviceId:SmartSwitch1",
	SECURITY_SENSOR = "urn:micasaverde-com:serviceId:SecuritySensor1"
}

-- assign a few contants from util module to reduce verbosity
local T_NUMBER = util.T_NUMBER
local T_BOOLEAN = util.T_BOOLEAN
local T_STRING = util.T_STRING

local LOG_FILTER = {
	["L_SmartSwitch_core.lua$"] = {
	},
	["L_Common_util.lua$"] = {
	}
}

-- GLOBALS

local g_settings = {}
local g_switchState = {}
local g_sensorState = {}
local g_scheduledTimeouts = {}

local function setSwitchLevel(switchId, level)
	log.debug ("setSwitchLevel: switchId = ", switchId, ", level = ", level)
	
	local lul_settings = {}
	local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments
	local binaryLevel
	
	if (level == 0) then
		binaryLevel = 0
	else
		binaryLevel = 1
	end
		
	if (luup.device_supports_service(SID.DIMMER, tonumber(switchId))) then
		g_switchState[switchId].LoadLevelTarget = level
		g_switchState[switchId].LoadLevelStatus = level
		g_switchState[switchId].Status = binaryLevel

		lul_settings.newLoadlevelTarget = level
		lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.DIMMER,
		"SetLoadLevelTarget", lul_settings, tonumber(switchId))
	elseif (luup.device_supports_service(SID.SWITCH, tonumber(switchId))) then
		g_switchState[switchId].Target = binaryLevel
		g_switchState[switchId].Status = binaryLevel

		lul_settings.newTargetValue = binaryLevel
		local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.SWITCH,
		"SetTarget", lul_settings, tonumber(switchId))
	end
	
	log.debug ("updated switch state: ", g_switchState[switchId])
end

local function initializeSensorState (sensorId)
		g_sensorState[sensorId] = {
			switches = {},
			tripped = util.getLuupVariable(SID.SECURITY_SENSOR, "Tripped", sensorId, T_BOOLEAN)
		}
end

local function addSwitchToSensorTable(sensorId, switchId)
	log.debug ("addSwitchToSensorTable: sensorId = ", sensorId, " switchId = ", switchId)
	if (not g_sensorState[sensorId]) then
		initializeSensorState (sensorId)
	end
	if (not g_sensorState[sensorId].switches[switchId]) then
		g_sensorState[sensorId].switches[switchId] = 1
	else
		g_sensorState[sensorId].switches[switchId] = g_sensorState[sensorId].switches[switchId] + 1
	end
end

local function removeSwitchFromSensorTable(sensorId, switchId)
	g_sensorState[sensorId].switches[switchId] = g_sensorState[sensorId].switches[switchId] - 1
	if (g_sensorState[sensorId].switches[switchId] == 0) then
		table.remove(g_sensorState[sensorId].switches, switchId)
	end
end

local function loadSettings()
	local settings = util.getLuupVariable(SID.SMART_SWITCH, "Settings", g_deviceId, T_STRING)

	if (settings) then
		settings = settings:gsub("'", "\"")

		log.debug ("settings = ", settings)

		local decodedSettings = json.decode(settings)
		if (decodedSettings) then
			g_settings = decodedSettings
		end
	end
	
	log.debug("g_settings = ", g_settings)
end


local function saveSettings()
	log.debug ("g_settings = ", g_settings)
	
	local settings = json.encode(g_settings)

	settings = settings:gsub("\"", "'")

	util.setLuupVariable(SID.SMART_SWITCH, "Settings", settings, g_deviceId, T_STRING)
end

local function initializeSwitchState(switchId)
		g_switchState[switchId] = {
			Target = util.getLuupVariable(SID.SWITCH, "Target", switchId, T_STRING),
			Status = util.getLuupVariable(SID.SWITCH, "Status", switchId, T_STRING),
			LoadLevelTarget = util.getLuupVariable(SID.DIMMER, "LoadLevelTarget", switchId, T_STRING),
			LoadLevelStatus = util.getLuupVariable(SID.DIMMER, "LoadLevelStatus", switchId, T_STRING),
			auto = false,
			manual = false,
			timeout = math.huge
		}
end

local function initializeState()
	for switchId, deviceSettings in pairs(g_settings) do
		initializeSwitchState(switchId)
		
		for index, sensorId in pairs(g_settings[switchId].sensors) do
			addSwitchToSensorTable(sensorId, switchId)
		end
	end
	
	log.debug ("done with state initialization")
	log.debug ("g_switchState = ", g_switchState)
	log.debug ("g_sensorState = ", g_sensorState)
end

---
--- TIMEOUT SCHEDULING / HANDLING
---

-- Figure out if we need a new call_delay to handle the newTimeout
local function scheduleTimeout(newTimeout) 
	local currentTime = os.time()
	
	-- cleanup expired timeouts
	for i = #g_scheduledTimeouts, 1, -1 do
		if (g_scheduledTimeouts[i] <= currentTime) then
			table.remove(g_scheduledTimeouts, i)
			log.debug ("Removed old timeout [", i, "] @ ", os.date("%c", g_scheduledTimeouts[i]))
		end
	end
	
	-- check to see if we need to add a new timeout
	if (#g_scheduledTimeouts == 0 or g_scheduledTimeouts[#g_scheduledTimeouts] > newTimeout) then
		table.insert(g_scheduledTimeouts, newTimeout)
		log.debug ("Added new timeout [", #g_scheduledTimeouts, "] @ ", os.date("%c", g_scheduledTimeouts[#g_scheduledTimeouts]))
		local timeoutInterval = newTimeout - currentTime
		if (timeoutInterval < 0) then
			timeoutInterval = 0
		end
		log.debug ("Seconds to next processTimeout = ", timeoutInterval)
		luup.call_delay("processTimeout", timeoutInterval, g_deviceId, true)
	end
end

local function updateSwitchTimeout(switchId)
	log.debug ("updating timeout for switch ", switchId)
	local tripped = false
	for index, sensorId in pairs (g_settings[switchId].sensors)  do
		if (g_sensorState[sensorId].tripped) then
			log.debug ("sensor ", sensorId, " is tripped")
			tripped = true
		end
	end
	if (not tripped) then
		local currentTime = os.time()
		local newTimeout = math.huge
		if (g_switchState[switchId].auto) then
			newTimeout = currentTime + g_settings[switchId].autoTimeout
		elseif (g_switchState[switchId].manual) then
			newTimeout = currentTime + g_settings[switchId].manualTimeout
		end
		
		log.debug ("No tripped sensors for switch ", switchId, ", setting timeout to ", os.date("%c", newTimeout))
		g_switchState[switchId].timeout = newTimeout
		
		scheduleTimeout (newTimeout)
	end
end

function processTimeout (data)
	log.debug("starting processTimeout")
	local nextTimeout = math.huge
	local currentTime = os.time()
	for switchId, state in pairs(g_switchState) do
		log.debug ("processTimeout, switchId = ", switchId, ", timeout = ", os.date("%c", state.timeout))
		if (state.timeout <= currentTime) then
			setSwitchLevel(switchId, g_settings[switchId].offLevel)
			state.timeout = math.huge
			state.manual = false
			state.auto = false
		elseif (state.timeout < nextTimeout) then
			nextTimeout = state.timeout
		end
	end
	
	log.debug ("nextTimeout = ", os.date("%c", nextTimeout))
	
	if (nextTimeout < math.huge) then
		scheduleTimeout(nextTimeout)
	end
end

-- init Luup variables if they don't have values
local function initLuupVariables()

end


local function createSwitch(switchId)
	g_settings[switchId] = {
		sensors = {},
		autoTimeout = 600,
		manualTimeout = 1800,
		onLevel = 100,
		offLevel = 0
	}
	initializeSwitchState(switchId)
end

local function addSwitch(switchId)
	if (not g_settings[switchId]) then
		createSwitch(switchId)
		saveSettings()
	end
end

local function removeSwitch(switchId)
	if (not g_settings[switchId]) then
		return
	end
	for sensorId in pairs (g_settings[switchId].sensors) do
		removeSwitchFromSensorTable(sensorId, switchId)
	end
	table.remove(g_switchState, switchId)
	table.remove(g_settings, switchId)
	saveSettings()
end

local function addSensor(switchId, sensorId)
	if (not g_settings[switchId]) then
		createSwitch(switchId)
	end
	table.insert(g_settings[switchId].sensors, sensorId)
	addSwitchToSensorTable(sensorId, switchId)
	saveSettings()
end

local function removeSensor(switchId, sensorId)
	if (table.remove(g_settings[switchId].sensors, sensorId)) then
		removeSwitchFromSensorTable(sensorId, switchId)
		saveSettings()
	end
end

local function setOnLevel(switchId, level)
	g_settings[switchId].onLevel = level
	saveSettings()
end

local function setOffLevel(switchId, level)
	g_settings[switchId].offLevel = level
	saveSettings()
end

local function setAutoTimeout(switchId, timeout)
	g_settings[switchId].autoTimeout = timeout
	saveSettings()
end

local function setManualTimeout(switchId, timeout)
	g_settings[switchId].manualTimeout = timeout
	saveSettings()
end

local function setLevel(switchId, level)
	g_switchState[switchId].manual = true
	g_switchState[switchId].auto = false
	updateSwitchTimeout(switchId)
end

-- function to handle UPnP api calls
local function dispatchRun(lul_device, lul_settings, serviceId, action)
	log.info ("Entering dispatchRun, serviceId = " , serviceId , ", action = " , action ,
	", lul_settings = " , (lul_settings))

	local success = true

	if (serviceId == SID.SMART_SWITCH) then
		if (action == "AddSwitch") then
			addSwitch(lul_settings.SwitchId)
		elseif (action == "RemoveSwitch") then
			removeSwitch(lul_settings.SwitchId)
		elseif (action == "AddSensor") then
			addSensor(lul_settings.SwitchId, lul_settings.SensorId)
		elseif (action == "RemoveSensor") then
			removeSensor(lul_settings.SwitchId, lul_settings.SensorId)
		elseif (action == "SetLevel") then
			setLevel(lul_settings.SwitchId, lul_settings.NewLevel)
		elseif (action == "SetOnLevel") then
			setOnLevel(lul_settings.SwitchId, lul_settings.NewOnLevel)
		elseif (action == "SetOffLevel") then
			setOffLevel(lul_settings.SwitchId, lul_settings.NewOffLevel)
		elseif (action == "SetAutoTimeout") then
			setAutoTimeout(lul_settings.SwitchId, lul_settings.NewAutoTimeout)
		elseif (action == "SetManualTimeout") then
			setManualTimeout(lul_settings.SwitchId, lul_settings.NewManualTimeout)
		else
			log.error("Unrecognized job request")
		end
	end

	return (success)
end

local function sensorTripped(sensorId)
	g_sensorState[sensorId].tripped = true
	for switchId in pairs(g_sensorState[sensorId].switches) do
		if (not g_switchState[switchId].manual and not g_switchState[switchId].auto) then
			setSwitchLevel(switchId, g_settings[switchId].onLevel)
			g_switchState[switchId].auto = true
		end
	end
end

local function sensorReset(sensorId)
	g_sensorState[sensorId].tripped = false
	for switchId in pairs(g_sensorState[sensorId].switches) do
		updateSwitchTimeout(switchId)
	end
end

function sensorCallback(lul_device, lul_service, lul_variable, lul_value_old, lul_value_new)
	log.debug("sensorCallback: lul_device = ", lul_device, ", type(lul_device) = ", type(lul_device),
	", lul_service = ", lul_service,
	", lul_variable = ", lul_variable,
	", lul_value_old = ", lul_value_old,
	", lul_value_new = ", lul_value_new)
	
	lul_device = tostring(lul_device)
	
	if (not g_sensorState[lul_device]) then
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
	
	lul_device = tostring(lul_device)
	lul_value_old = tonumber(lul_value_old)
	lul_value_new = tonumber(lul_value_new)
	
	if (not g_switchState[lul_device]) then
		return
	end

	if (lul_variable == "Target" or
	lul_variable == "Status" or
	lul_variable == "LoadLevelTarget" or
	lul_variable == "LoadLevelStatus") then
		if (lul_value_new ~= g_switchState[lul_device][lul_variable]) then
			log.debug ("received updated state in switch callback: ",
			" newValue = ", lul_value_new,
			", type(newValue) = ", type(lul_value_new),
			", currentValue = ", g_switchState[lul_device][lul_variable],
			", type(currentValue) = ", type(g_switchState[lul_device][lul_variable]))
			g_switchState[lul_device].manual = true
			g_switchState[lul_device].auto = false
			g_switchState[lul_device][lul_variable] = lul_value_new
			updateSwitchTimeout(lul_device)
		end
	end
end

--- Initialize the  plugin
local function initialize(lul_device)
	local success = false
	local errorMsg = nil

	g_deviceId = tonumber(lul_device)

	util.initLogging(LOG_PREFIX, LOG_FILTER, SID.SMART_SWITCH, "LogLevel", g_deviceId)

	log.info ("Initializing SmartSwitch plugin for device " , g_deviceId)
	--
	--	log.error ("luup.devices = " , luup.devices)

	-- set plugin version number
	luup.variable_set(SID.SMART_SWITCH, "PluginVersion", PLUGIN_VERSION, g_deviceId)

	initLuupVariables()

	loadSettings()

	initializeState()
	
	luup.variable_watch("switchCallback", SID.SWITCH, nil, nil)
	luup.variable_watch("switchCallback", SID.DIMMER, nil, nil)
	luup.variable_watch("sensorCallback", SID.SECURITY_SENSOR, "Tripped", nil)
	
	log.info("Done with initialization")
	
	return success, errorMsg, "SmartSwitch"
end


-- RETURN GLOBAL FUNCTIONS
return {
	initialize=initialize,
	dispatchRun=dispatchRun
}


		
		