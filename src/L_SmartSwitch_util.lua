-- MiOS Utility Functions
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

--
-- This logging module provides some higher level
-- functionality on top of Luup logging.
--

-- IMPORT GLOBALS
local luup = luup
local string = string
local log = g_log
local json = g_dkjson

-- CONSTANTS
local T_NUMBER = "T_NUMBER"
local T_BOOLEAN = "T_BOOLEAN"
local T_STRING = "T_STRING"
local T_TABLE = "T_TABLE"

-- GLOBALS

local function luupLog(message, level)
	local luupLogLevel 
	if (level <= log.LOG_LEVEL_ERROR) then
		luupLogLevel = 1
	elseif (level <= log.LOG_LEVEL_INFO) then
		luupLogLevel = 2
	else
		luupLogLevel = 50
	end
	luup.log(message, luupLogLevel)
end

-- initalize a Luup variable to a value if it's not already set
local function initVariableIfNotSet(serviceId, variableName, initValue, lul_device)
	local value = luup.variable_get(serviceId, variableName, lul_device)
	log.debug ("initVariableIfNotSet: lul_device [",lul_device,"] serviceId [",serviceId,"] Variable Name [",variableName,
	"] Lua Type [", type(value), "] Value [", value, "]")
	if (value == nil or value == "") then
		luup.variable_set(serviceId, variableName, initValue, lul_device)
	end
end

--- return a Luup variable with the added capability to convert to a the
-- appropriate Lua type.
-- The Luup API _should_ do this automatically as the variables are
-- all declared with types, but it doesn't. Grrrr.....
local function getLuupVariable(serviceId, variableName, deviceId, varType) 
	if (type(deviceId) == "string") then
--		log.debug ("Converting deviceId to number for device ", lul_device)
		deviceId = tonumber(deviceId)
	end
	
	local rawValue = luup.variable_get(serviceId, variableName, deviceId)
	
	local returnValue = nil
	if (not rawValue) then
		returnValue = nil
	elseif (varType == T_BOOLEAN) then
		returnValue = (rawValue == "1")
	elseif (varType == T_NUMBER) then
		returnValue = tonumber(rawValue)
	elseif (varType == T_STRING) then
		returnValue = tostring(rawValue)
	elseif (varType == T_TABLE) then
		rawValue = rawValue:gsub("'", "\"")
		log.debug ("rawValue = ", rawValue)
		returnValue = json.decode(rawValue)
	else
		error ("Invalid varType passed to getLuupVariable, serviceId = " .. serviceId ..
			", variableName = " .. variableName .. ", deviceId = " .. deviceId ..
			", varType = " .. tostring(varType) )
		return nil
	end
	
	log.debug ("getLuupVariable: deviceId [",deviceId,"] serviceId [",serviceId,"] variableName [",variableName,
	"] rawValue [", rawValue, "] varType [", varType, "] returnValue [", returnValue, "]")
	
	return returnValue
end

local function setLuupVariable(serviceId, variableName, newValue, deviceId) 
	log.debug ("setLuupVariable: deviceId [",deviceId,"] serviceId [",serviceId,"] variableName [",variableName,
	 "] newValue [", newValue, "]", "] type(newValue) [", type(newValue), "]")
	
	if (type(deviceId) == "string") then
--		log.debug ("Converting deviceId to number for device ", lul_device)
		lul_device = tonumber(deviceId)
	end

	if (newValue == nil) then
		luup.variable_set(serviceId, variableName, "", deviceId)
	elseif (type(newValue) == "boolean") then
		local luupValue = "0"
		if (newValue) then
			luupValue = "1"
		end
		luup.variable_set(serviceId, variableName, luupValue, deviceId)
	elseif (type(newValue) == "table") then
		luup.variable_set(serviceId, variableName, json.encode(newValue):gsub("\"", "'"), deviceId)
	else
		luup.variable_set(serviceId, variableName, newValue, deviceId)
	end
end

-- initialize the logging system
local function initLogging(logPrefix, logFilter, logLevelSID, logLevelVar, logLevelDevice)
	log.setPrefix(logPrefix)
	log.setLogFunction(luupLog)
	log.addFilter(logFilter)
	initVariableIfNotSet(logLevelSID, logLevelVar, log.LOG_LEVEL_INFO, logLevelDevice)
	log.setLevel(getLuupVariable(logLevelSID, logLevelVar, logLevelDevice, T_NUMBER))
end


-------------------------------------
-------- Lua Utility functions ----------
-------------------------------------

-- math rounding function (would be nice if Lua had this!)
local function round (value, multiplier)
	local result = 0
	if (value >= 0) then
		return math.floor(value * multiplier + 0.5) / multiplier
	else
		return math.ceil(value * multiplier - 0.5) / multiplier
	end
end

-- lookup a key in a table by its value
local function findKeyByValue(table, value)
	for k,v in pairs(table) do
		if (v == value) then
			return k
		end
	end

	return nil
end

-- RETURN GLOBAL FUNCTION TABLE
return {
	initVariableIfNotSet = initVariableIfNotSet,
	getLuupVariable = getLuupVariable,
	setLuupVariable = setLuupVariable,
	luupLog = luupLog,
	initLogging = initLogging,
	findKeyByValue = findKeyByValue,
	round = round,
	T_NUMBER = T_NUMBER,
	T_BOOLEAN = T_BOOLEAN,
	T_STRING = T_STRING,
	T_TABLE = T_TABLE
}

