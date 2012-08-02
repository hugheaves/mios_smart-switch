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
local DATE_FORMAT = "%m/%d/%y %H:%M:%S"


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

-- assign a few contants from util module to reduce verbosity
local T_NUMBER = util.T_NUMBER
local T_BOOLEAN = util.T_BOOLEAN
local T_STRING = util.T_STRING

local LOG_FILTER = {
	["L_SmartSwitch_core.lua$"] = {
	},
	["L_SmartSwitch_util.lua$"] = {
		["getLuupVariable"] = true
	}
}

-- GLOBALS

-- Indexed by SwitchId
g_switchState = {
-- Status
-- LoadLevelStatus
-- smartSwitchId
-- auto
-- manual
-- timeout
-- sensors
}

-- Indexed by SensorId
g_sensorState = {
-- switches
-- tripped
}

-- Indexed by SmartSwitchId
g_smartSwitchToSwitchMap = {}


-- Holds a stack of currently scheduled processTimeouts tasks scheduled by "call_delay" 
g_scheduledTimeouts = {}


g_deviceId = nil
g_taskHandle = -1

-- Set light level on physical switch
local function setSwitchLevel(switchId, level)
	log.info ("Setting Switch Level: switchId = ", switchId, ", level = ", level)

	local lul_settings = {}
	local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments
	local binaryLevel

	if (level == 0) then
		binaryLevel = 0
	else
		binaryLevel = 1
	end

	if (luup.device_supports_service(SID.DIMMER, tonumber(switchId))) then
		g_switchState[switchId].LoadLevelStatus = level
		g_switchState[switchId].Status = binaryLevel

		lul_settings.newLoadlevelTarget = level

		lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.DIMMER,
		"SetLoadLevelTarget", lul_settings, tonumber(switchId))

	elseif (luup.device_supports_service(SID.SWITCH, tonumber(switchId))) then
		g_switchState[switchId].Status = binaryLevel

		lul_settings.newTargetValue = binaryLevel
		
		local lul_resultcode, lul_resultstring, lul_job, lul_returnarguments = luup.call_action(SID.SWITCH,
		"SetTarget", lul_settings, tonumber(switchId))
	end


	log.debug ("updated switch state: ", g_switchState[switchId])
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
	local smartSwitchId = g_switchState[switchId].smartSwitchId

	for sensorId, status in pairs(g_switchState[switchId].sensors)  do
		if (g_sensorState[tonumber(sensorId)].tripped) then
			tripped = true
		end
	end

	if (tripped) then
		log.debug ("One or more sensors for switch ", switchId, " are still tripped. Not updating switch timeout.")
	else
		local currentTime = os.time()
		local newTimeout = math.huge
		local varName
		if (g_switchState[switchId].auto) then
			newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", smartSwitchId, T_NUMBER)
		elseif (g_switchState[switchId].manual) then
			newTimeout = currentTime + util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", smartSwitchId, T_NUMBER)
		else
			log.debug ("Sensor state reset, but switch ", switchId, " does not have an active timeout.")
		end

		if (newTimeout ~= math.huge) then
			log.info ("Switch ", switchId, ": setting timeout to ", os.date(DATE_FORMAT, newTimeout), " ( manual = ", g_switchState[switchId].manual, ", auto = ", g_switchState[switchId].auto, " )")
			g_switchState[switchId].timeout = newTimeout
			scheduleTimeout (newTimeout)	
		end
		
	end
end

function processTimeouts (data)
	log.info("Starting processTimeouts")
	local nextTimeout = math.huge
	local currentTime = os.time()
	
	for switchId, state in pairs(g_switchState) do
		log.debug ("Switch ", switchId, " has a timeout set for ", os.date(DATE_FORMAT, state.timeout))
		if (state.timeout <= currentTime) then
			log.info ("Timeout has expired, so turning off switch ", switchId, "( manual = ", state.manual, ", auto = ", state.auto,  ")")
			setSwitchLevel(switchId, util.getLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "OffLevel", g_switchState[switchId].smartSwitchId, util.T_NUMBER))
			state.timeout = math.huge
			state.manual = false
			state.auto = false
		elseif (state.timeout < nextTimeout) then
			nextTimeout = state.timeout
		end
	end

	log.debug ("Done with processTimeouts, nextTimeout = ", os.date(DATE_FORMAT, nextTimeout))

	if (nextTimeout < math.huge) then
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
	g_sensorState[sensorId] = {
		switches = {},
		tripped = util.getLuupVariable(SID.SECURITY_SENSOR, "Tripped", sensorId, T_BOOLEAN)
	}
end

local function addSensor(sensorId, switchId)
	log.debug ("addSensor: sensorId = ", sensorId, " switchId = ", switchId)
	if (not g_sensorState[sensorId]) then
		initSensorState (sensorId)
	end
	g_sensorState[sensorId].switches[switchId] = 1
	g_switchState[switchId].sensors[sensorId] = 1
end

local function removeSensor(sensorId, switchId)
	log.debug ("removeSensor: sensorId = ", sensorId, " switchId = ", switchId)
	g_sensorState[sensorId].switches[switchId] = nil
	g_switchState[switchId].sensors[sensorId] = nil
end

-------------------------------------
---------- MISC FUNCTIONS -----------
-------------------------------------
local function updatePluginStatusText()
	local statusText = "Switches controlled by this plugin:<br>" ..
	"<table><thead>" ..
	"<tr><th>Id</th><th>Name</th><th>Sensor Name / Id(s)</th></tr></thead><tbody>"
	for switchId, data in pairs(g_switchState) do
		log.debug ("switchId = ", switchId, ", data = ", data)
		local description = luup.devices[switchId].description
		local sensors = ""

		for sensorId, status in pairs(data.sensors) do
			sensors = sensors .. luup.devices[sensorId].description .. " (#" .. sensorId .."), "
		end

		statusText = statusText .. "<tr><td>" .. switchId .. "</td><td>" .. description  .. "</td><td>" .. sensors  .. "</td></tr>"
	end
	statusText = statusText .. "</tbody></table>"
	util.setLuupVariable(SID.SMART_SWITCH, "StatusText", statusText, g_deviceId)
end

local function updateSmartSwitchStatusText(smartSwitchId)
	local switchId = g_smartSwitchToSwitchMap[smartSwitchId]
	log.debug ("switchId = ", switchId, ", smartSwitchId = ", smartSwitchId)
	local statusText = "Sensors controlling this switch:<br>" ..
	"<table><thead>"..
	"<tr><th>Id</th><th>Name</th></tr></thead><tbody>"
	for sensorId, status in pairs(g_switchState[switchId].sensors) do
		statusText = statusText .. "<tr><td>" .. sensorId .. "</td><td>" .. luup.devices[sensorId].description .. "</td></tr>"
	end
	statusText = statusText .. "</tbody></table>"
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "StatusText", statusText, smartSwitchId)
end

------------------------------------------
-------- RUN / JOB HANDLERS --------------
------------------------------------------

local function addSwitch(switchId)
	log.debug ("switchId = ", switchId)
	if (switchId ~= nil and ( luup.device_supports_service(SID.DIMMER, switchId) or
	luup.device_supports_service(SID.SWITCH, switchId) ) ) then
		local switchIds = util.getLuupVariable(SID.SMART_SWITCH, "SwitchIds", g_deviceId, util.T_TABLE)
		if (not util.findKeyByValue(switchIds, tostring(switchId))) then
			table.insert(switchIds, tostring(switchId))
			util.setLuupVariable(SID.SMART_SWITCH, "SwitchIds", switchIds, g_deviceId)
		end
		syncChildDevices()
	else
		luup.task ("Add Switch: Invalid switch id (" .. tostring(switchId) .. ")", TASK.ERROR, "Smart Switch", g_taskHandle)
	end
end

local function removeSwitch(switchId)
	log.debug ("switchId = ", switchId)
	local switchIds = util.getLuupVariable(SID.SMART_SWITCH, "SwitchIds", g_deviceId, util.T_TABLE)
	local index = util.findKeyByValue(switchIds, tostring(switchId))
	if (index) then
		table.remove(switchIds, index)
		util.setLuupVariable(SID.SMART_SWITCH, "SwitchIds", switchIds, g_deviceId)
		syncChildDevices()
	else
		luup.task ("Remove Switch: Invalid switch id (" .. tostring(switchId) .. ")", TASK.ERROR, "Smart Switch", g_taskHandle)
	end
end

local function addSensorToSwitch(smartSwitchId, sensorId)
	log.debug ("smartSwitchId = ", smartSwitchId, "sensorId = ", sensorId)
	if (sensorId ~= nil and luup.device_supports_service(SID.SECURITY_SENSOR, sensorId)) then
		local sensorIds = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", smartSwitchId, util.T_TABLE)
		if (not util.findKeyByValue(sensorIds, tostring(sensorId))) then
			table.insert(sensorIds, tostring(sensorId))
			util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", sensorIds, smartSwitchId)
			addSensor(sensorId, g_smartSwitchToSwitchMap[smartSwitchId])
			updateSmartSwitchStatusText(smartSwitchId)
			updatePluginStatusText()
		end
	end
end

local function removeSensorFromSwitch(smartSwitchId, sensorId)
	log.debug ("smartSwitchId = ", smartSwitchId, "sensorId = ", sensorId)
	local sensorIds = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", smartSwitchId, util.T_TABLE)
	local index = util.findKeyByValue(sensorIds, tostring(sensorId))
	if (index) then
		table.remove(sensorIds, index)
		util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", sensorIds, smartSwitchId)
		removeSensor(sensorId, g_smartSwitchToSwitchMap[smartSwitchId])
		updateSmartSwitchStatusText(smartSwitchId)
		updatePluginStatusText()
	end
end

local function setOnLevel(smartSwitchId, level)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OnLevel", level, smartSwitchId)
end

local function setOffLevel(smartSwitchId, level)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "OffLevel", level, smartSwitchId)
end

local function setAutoTimeout(smartSwitchId, timeout)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", timeout, smartSwitchId)
end

local function setManualTimeout(smartSwitchId, timeout)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", timeout, smartSwitchId)
end

local function setLevel(smartSwitchId, level)
	local switchId = g_smartSwitchToSwitchMap[smartSwitchId]
	g_switchState[switchId].manual = true
	g_switchState[switchId].auto = false
	setSwitchLevel(switchId, level)
	util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", level, smartSwitchId)
	updateSwitchTimeout(switchId)
end

-- function to handle UPnP api calls
local function dispatchRun(lul_device, lul_settings, serviceId, action)
	log.info ("Entering dispatchRun, lul_device = ", lul_device, ", serviceId = " , serviceId , ", action = " , action ,
	", lul_settings = " , (lul_settings))

	local success = true
	local lul_device = tonumber(lul_device)

	if (serviceId == SID.SMART_SWITCH) then
		if (action == "AddSwitch") then
			addSwitch(tonumber(lul_settings.SwitchId))
		elseif (action == "RemoveSwitch") then
			removeSwitch(tonumber(lul_settings.SwitchId))
		else
			log.error("Unrecognized job request")
		end
	elseif (serviceId == SID.SMART_SWITCH_CONTROLLER) then
		if (action == "AddSensor") then
			addSensorToSwitch(lul_device, tonumber(lul_settings.SensorId))
		elseif (action == "RemoveSensor") then
			removeSensorFromSwitch(lul_device, tonumber(lul_settings.SensorId))
		elseif (action == "SetLevel") then
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

--------------------------------------
-------- CALLBACK HANDLERS -----------
--------------------------------------

local function sensorTripped(sensorId)
	g_sensorState[sensorId].tripped = true
		
	for switchId in pairs(g_sensorState[sensorId].switches) do
	
		local autoTimeout = util.getLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "AutoTimeout", g_switchState[switchId].smartSwitchId, util.T_NUMBER)

		-- only change to "auto" mode if we are not already in manual mode
		-- and there is an autoTimeout set
		if (not g_switchState[switchId].manual and not g_switchState[switchId].auto and autoTimeout > 0) then
			setSwitchLevel(switchId, util.getLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "OnLevel", g_switchState[switchId].smartSwitchId, util.T_NUMBER))
			g_switchState[switchId].auto = true
		elseif (g_switchState[switchId].auto) then  -- if we are already in auto mode, clear the current timeout
			g_switchState[switchId].timeout = math.huge
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

	lul_device = tonumber(lul_device)

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

	lul_device = tonumber(lul_device)
	lul_value_old = tonumber(lul_value_old)
	lul_value_new = tonumber(lul_value_new)

    -- if this isn't a switch that we're controlling with the 
    -- smart switch plugin, then return without doing anything
	if (not g_switchState[lul_device]) then
		return
	end

	
		if (lul_value_new ~= g_switchState[lul_device][lul_variable]) then
		
			log.debug ("received updated state in switch callback: ",
			" newValue = ", lul_value_new,
			", type(newValue) = ", type(lul_value_new),
			", currentValue = ", g_switchState[lul_device][lul_variable],
			", type(currentValue) = ", type(g_switchState[lul_device][lul_variable]))
			
			local manualTimeout = util.getLuupVariable(
			SID.SMART_SWITCH_CONTROLLER, "ManualTimeout", g_switchState[lul_device].smartSwitchId, util.T_NUMBER)
			
			-- only change to "manual" mode if there is a manualTimeout set
			if (manualTimeout > 0) then
				g_switchState[lul_device].manual = true
				g_switchState[lul_device].auto = false
			end
			
			g_switchState[lul_device][lul_variable] = lul_value_new
			
			local smartSwitchId = g_switchState[lul_device].smartSwitchId
			
			if (lul_variable == "LoadLevelStatus") then
				util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", lul_value_new, smartSwitchId)
			elseif (lul_variable == "Status") then
				if (lul_value_new == "0") then
					util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", "0", smartSwitchId)
				else
					util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", "100", smartSwitchId)
				end
			end
			
			updateSwitchTimeout(lul_device)
		else
			log.debug ("received unchanged state in switch callback")
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
	SID.SMART_SWITCH_CONTROLLER..",CurrentLevel=0\n"..
	SID.SMART_SWITCH_CONTROLLER..",OnLevel=100\n"..
	SID.SMART_SWITCH_CONTROLLER..",OffLevel=0\n"..
	SID.SMART_SWITCH_CONTROLLER..",AutoTimeout=300\n"..
	SID.SMART_SWITCH_CONTROLLER..",ManualTimeout=1800\n"..
	SID.SMART_SWITCH_CONTROLLER..",SensorIds=[]"
end

local function initSwitchState(switchId, smartSwitchId)
	log.debug ("Initializing switch state for switch #", switchId, ", smart switch #", smartSwitchId)
	g_switchState[switchId] = {
		Status = util.getLuupVariable(SID.SWITCH, "Status", switchId, T_STRING),
		LoadLevelStatus = util.getLuupVariable(SID.DIMMER, "LoadLevelStatus", switchId, T_STRING),
		auto = false,
		manual = false,
		timeout = math.huge,
		smartSwitchId = smartSwitchId,
		sensors = {}
	}

	if (g_switchState[switchId].LoadLevelStatus) then
		util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", g_switchState[switchId].LoadLevelStatus, smartSwitchId)
	elseif (g_switchState[switchId].Status == "0") then
		util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", "0", smartSwitchId)
	elseif (g_switchState[switchId].Status == "1") then
		util.setLuupVariable(SID.SMART_SWITCH_CONTROLLER, "CurrentLevel", "100", smartSwitchId)
	end
end

local function initSmartSwitch(smartSwitchId)
	local switchId = tonumber(luup.devices[smartSwitchId].id)
	log.debug ("initializing smart switch for switchId = ",switchId, "smartSwitchId = ",smartSwitchId)

	initSwitchState(switchId, smartSwitchId)

	local sensorIds = util.getLuupVariable(SID.SMART_SWITCH_CONTROLLER, "SensorIds", smartSwitchId, util.T_TABLE)
	for index, sensorId in pairs(sensorIds) do
		addSensor(tonumber(sensorId), switchId)
	end

	g_smartSwitchToSwitchMap[smartSwitchId] = switchId

	updateSmartSwitchStatusText(smartSwitchId)
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

	updatePluginStatusText()

	log.debug ("done with state initialization")
	log.debug ("g_switchState = ", g_switchState)
	log.debug ("g_sensorState = ", g_sensorState)
	log.debug ("g_smartSwitchToSwitchMap = ", g_smartSwitchToSwitchMap)
end

-- Synchronize the Smart Switch Controller devices
local function syncChildDevices()
	local switchIds = util.getLuupVariable(SID.SMART_SWITCH, "SwitchIds", g_deviceId, util.T_TABLE)
	log.debug ("switchIds = ", switchIds)

	local rootPtr = luup.chdev.start(g_deviceId)

	for index, SwitchIdString in pairs(switchIds) do
		local switchId = tonumber(SwitchIdString)
		log.debug ("syncing switchId = ", switchId)
		local description = "SS: " .. luup.devices[switchId].description
		luup.chdev.append(g_deviceId, rootPtr,
		switchId, description,
		DID_SMART_SWITCH_CONTROLLER,
		"D_SmartSwitchController1.xml", "", getDefaultParameters(), false)
	end

	luup.chdev.sync(g_deviceId, rootPtr)
end

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


		
		