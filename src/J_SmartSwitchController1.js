var SMART_SWITCH_SID = 'urn:hugheaves-com:serviceId:SmartSwitch1';
var SMART_SWITCH_CONTROLLER_SID = 'urn:hugheaves-com:serviceId:SmartSwitchController1';
var SECURITY_SENSOR_SID = 'urn:micasaverde-com:serviceId:SecuritySensor1';
var SWITCH_SID = 'urn:upnp-org:serviceId:SwitchPower1';

var ssc_settingSid;
var ssc_settingVar;
var ssc_deviceId = 0;

function ssc_showSettings(deviceId) {
	var panelHtml = '';

	ssc_deviceId = deviceId;
	ssc_settingSid = SMART_SWITCH_CONTROLLER_SID;
	ssc_settingVar = 'SensorIds';
	
	panelHtml += '<p>To use this smart switch, you must add one or more motion sensors (or '
			+ 'other switches) that will act as the trigger for this switch.</p>';

	panelHtml += '<p>To add a trigger device, select a device from the drop-down '
			+ 'below and and click the "Add" button. To remove an '
			+ 'existing device, click the "Remove" button next to the device.</p>';

	panelHtml += '<p>To save your changes, remember to click the "Save" button '
			+ 'at the top of the screen after closing this dialog.</p>';

	panelHtml += ssc_deviceSelectDropdown(SECURITY_SENSOR_SID, SWITCH_SID);
	
	panelHtml += ssc_devicesTable();

	set_panel_html(panelHtml);
}

/*
 * Generic (Shared) functions
 */

function ssc_findDevices(sid1, sid2) {
	var foundDevices = [];

	var devices = jsonp.ud.devices;

	for ( var i = 0; i < devices.length; i++) {
		var device = devices[i];
		var found = false;

		for ( var j = 0; j < device.states.length; j++) {
			var state = device.states[j];
			if (state.service == sid1 || state.service == sid2) {
				found = true;
			}
		}

		if (found) {
			foundDevices.push(device);
		}

	}
	return foundDevices;
}

function ssc_removeUsedDevices(devices) {
	var deviceIds = ssc_getDeviceIdsSetting();
	var newDevices = [];
	
	for ( var i = 0; i < devices.length; ++i) {
		var device = devices[i];
		var index = deviceIds.indexOf(device.id);
		if (index == -1) {
			newDevices.push(device);
		}
	}
	
	return newDevices;
}

function ssc_getDeviceIdsSetting() {
	var deviceIdsJSON = get_device_state(ssc_deviceId, ssc_settingSid,
			ssc_settingVar, 0);

	deviceIdsJSON = deviceIdsJSON.replace(/'/g, '\"');

	return (JSON.parse(deviceIdsJSON));
}

function ssc_setDeviceIdsSetting(deviceIds) {
	var deviceIdsJSON = JSON.stringify(deviceIds);

	deviceIdsJSON = deviceIdsJSON.replace(/"/g, '\'');

	set_device_state(ssc_deviceId, ssc_settingSid, ssc_settingVar, deviceIdsJSON, 0);
}

function ssc_deviceSelectDropdown(sid1, sid2) {
	var panelHtml = '';

	var devices = ssc_findDevices(sid1, sid2);
	devices = ssc_removeUsedDevices(devices);

	panelHtml += '<select id="deviceSelect">'
	panelHtml += '<option value="0">-- Select a device --</option>'
	for ( var i = 0; i < devices.length; ++i) {
		var device = devices[i];
		panelHtml += '<option value="' + device.id + '">' + device.name + ' (#'
				+ device.id + ')</option>';

	}
	panelHtml += '</select>';
	panelHtml += '<input type="button" value="Add" onclick="ssc_addSelectedDevice()" />';
	panelHtml += '<p/>';

	return panelHtml;
}

function ssc_devicesTable() {
	var panelHtml = '';

	panelHtml += ssc_tableHeader();

	var deviceIds = ssc_getDeviceIdsSetting();

	for ( var i = 0; i < deviceIds.length; ++i) {
		panelHtml += ssc_tableRow(jsonp.get_device_by_id(deviceIds[i]));
	}

	panelHtml += ssc_tableFooter();

	return panelHtml;
}

function ssc_tableHeader() {
	var panelHtml = '';

	panelHtml += '<table style="border-collapse:collapse">';
	panelHtml += '<tr>';
	panelHtml += '<th style="width: 20%">Device Id</th>';
	panelHtml += '<th style="width: 20%">Room</th>';
	panelHtml += '<th style="width: 50%">Name</th>';
	panelHtml += '<th style="width: 20%">Action</th>';
	panelHtml += '</tr>';

	return panelHtml;
}

function ssc_tableRow(device) {
	var panelHtml = '';
	var roomName = 'none';

	if (device.room > 0) {
		roomName = jsonp.get_room_by_id(device.room).name;
	}

	panelHtml += '<tr style="border: 1px solid black">';
	panelHtml += '<td style="border: 1px solid black">' + device.id + '</td>';
	panelHtml += '<td style="border: 1px solid black">' + roomName + '</td>';
	panelHtml += '<td style="border: 1px solid black">' + device.name + '</td>';
	panelHtml += '<td style="border: 1px solid black"><input type="button" value="Remove" '
			+ 'onclick="ssc_removeDevice(\'' + device.id + '\')" /></td>';
	panelHtml += '</tr>';

	return panelHtml;
}

function ssc_tableFooter() {
	return '</table>';
}

function ssc_removeDevice(deviceId) {
	var deviceIds = ssc_getDeviceIdsSetting();
	var index = deviceIds.indexOf(deviceId);
	if (index > -1) {
		deviceIds.splice(index, 1);
		ssc_setDeviceIdsSetting(deviceIds);
		ssc_showSettings(ssc_deviceId);
	}
}

function ssc_addSelectedDevice() {
	var element = document.getElementById("deviceSelect");
	var deviceId = element.options[element.selectedIndex].value;
	var deviceIds = ssc_getDeviceIdsSetting();
	var index = deviceIds.indexOf(deviceId);
	if (index == -1 && deviceId > 0) {
		deviceIds.push(deviceId);
		ssc_setDeviceIdsSetting(deviceIds);
		ssc_showSettings(ssc_deviceId);
	}
}
