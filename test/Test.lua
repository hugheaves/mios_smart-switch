luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "19"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "21"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "35"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "37"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "43"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "59"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "137"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "167"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "194"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "201"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "203"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "230"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "232"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSwitch", { SwitchId = "235"}, 237)



-- living room
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "35", SensorId = "209"}, 237)

-- kitchen
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "59", SensorId = "216"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "59", NewAutoTimeout = "180"}, 237)

-- family room
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "201", SensorId = "196"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "203", SensorId = "196"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "230", SensorId = "196"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "235", SensorId = "196"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "201", NewAutoTimeout = "3600"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "203", NewAutoTimeout = "3600"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "230", NewAutoTimeout = "3600"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "235", NewAutoTimeout = "3600"}, 237)

-- tv
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "167", SensorId = "196"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "167", NewAutoTimeout = "3600"}, 237)

-- dining room
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "137", SensorId = "79"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "137", NewAutoTimeout = "300"}, 237)

-- playroom
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "43", SensorId = "80"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "21", SensorId = "80"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "19", SensorId = "80"}, 237)

-- upstairs hallway
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "37", SensorId = "195"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "37", NewAutoTimeout = "60"}, 237)

-- mud room
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "232", SensorId = "218"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "232", NewAutoTimeout = "120"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "AddSensor", { SwitchId = "194", SensorId = "218"}, 237)
luup.call_action("urn:hugheaves-com:serviceId:SmartSwitch1", "SetAutoTimeout", { SwitchId = "194", NewAutoTimeout = "120"}, 237)
