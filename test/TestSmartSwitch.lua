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

package.path = package.path .. ";?.lua;../src/?.lua"

g_pluginName = "SmartSwitch"

luup = require ("LuupTestHarness")
math = require("math")

local log = require("L_" .. g_pluginName .. "_" .. "log")
local core = require("L_" .. g_pluginName .. "_" .. "core")
local util = require("L_" .. g_pluginName .. "_" .. "util")

local LOG_CONFIG = {
  ["version"] = 1,
  ["files"] = {
    ["LuupTestHarness.lua"] = {
      ["level"] = log.LOG_LEVEL_DEBUG,
      ["functions"] = {
      }
    },
    ["L_SmartSwitch_util.lua"] = {
      ["level"] = log.LOG_LEVEL_DEBUG,
      ["functions"] = {
        "none"
      }
    },
  }
}

log.setConfig(LOG_CONFIG)
log.setLevel(log.LOG_LEVEL_DEBUG)

luup._setLog(log)
luup._addFunctions(core)

local mainDevice = luup._createDevice(0, 0, "Smart Switch", "urn:schemas-hugheaves-com:device:SmartSwitch:1", "")

util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitch1", "LogConfig", LOG_CONFIG, mainDevice)

util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitch1", "LogLevel", log.LOG_LEVEL_DEBUG, mainDevice)

local switches =  { luup._createDevice(0, 1, "switch 1", "SwitchDeviceId", ""), luup._createDevice(0, 2, "switch 2", "SwitchDeviceId", ""),
  luup._createDevice(0, 3, "switch 3", "SwitchDeviceId", "") }
util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", false, switches[1])
util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", false, switches[2])
util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", false, switches[3])

util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitch1", "SwitchIds", switches, mainDevice)

local sensors =   { luup._createDevice(0, 1, "sensor 1", "SensorDeviceId", ""),
  luup._createDevice(0, 2, "sensor 2", "SensorDeviceId", ""),
  luup._createDevice(0, 3, "sensor 2", "SensorDeviceId", "") }

util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[1])
util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[2])
util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[3])

local smartSwitches = { luup._createDevice(mainDevice, switches[1], "smartswitch 1", "urn:schemas-hugheaves-com:device:SmartSwitchController:1", ""),
  luup._createDevice(mainDevice, switches[2], "smartswitch 2", "urn:schemas-hugheaves-com:device:SmartSwitchController:1", ""),
  luup._createDevice(mainDevice, switches[3], "smartswitch 3", "urn:schemas-hugheaves-com:device:SmartSwitchController:1", "") }

util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "SensorIds", { sensors[1] }, smartSwitches[1])
util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "AutoTimeout", 3, smartSwitches[1])
util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "SensorIds", {  sensors[2] }, smartSwitches[2])
util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "AutoTimeout", 5, smartSwitches[2])
util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "SensorIds", {  sensors[2] }, smartSwitches[2])
util.setLuupVariable("urn:hugheaves-com:serviceId:SmartSwitchController1", "AutoTimeout", 7, smartSwitches[2])

core.setLogConfig(LOG_CONFIG)
core.initialize(mainDevice)

luup._callbackLoop()

--util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", true, sensors[1])
--
--luup._callbackLoop()
--
--util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[1])
--
--luup._callbackLoop()

util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", true, switches[2])
util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", true, sensors[1])
util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[1])

luup._callbackLoop()

--util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[1])
--
--luup._callbackLoop()


function randomStuff()
  print() print() print() print() print() print()
  local delay = math.random(0, 1)
  local option = math.random(0, 5)
  local device = math.random(1, 3)
  log.debugValues("", "delay", delay, "option", option, "device", device)

  if (option == 0) then
    util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", true, sensors[device])
  elseif (option == 1) then
    util.setLuupVariable("urn:micasaverde-com:serviceId:SecuritySensor1", "Tripped", false, sensors[device])
  elseif (option == 2) then
    util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", false, switches[device])
  elseif (option == 3) then
    util.setLuupVariable("urn:upnp-org:serviceId:SwitchPower1", "Status", true, switches[device])
  else
    log.debug("OPTION ", option)
  end
  
  luup.call_delay("randomStuff", delay, "")
  print() print() print() print() print() print()
end

luup._addFunctions({randomStuff = randomStuff})

--luup.call_delay("randomStuff", 2, "")

luup._callbackLoop()
