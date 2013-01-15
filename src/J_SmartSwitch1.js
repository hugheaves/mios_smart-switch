var SMART_SWITCH_SID = 'urn:hugheaves-com:serviceId:SmartSwitch1';
var SMART_SWITCH_CONTROLLER_SID = 'urn:hugheaves-com:serviceId:SmartSwitchController1';
var SECURITY_SENSOR_SID = 'urn:micasaverde-com:serviceId:SecuritySensor1';
var SWITCH_SID = 'urn:upnp-org:serviceId:SwitchPower1';

var ss_settingSid;
var ss_settingVar;
var ss_deviceId = 0;

function ss_showSettings(deviceId) {
	var panelHtml = '';

	ss_deviceId = deviceId;
	ss_settingSid = SMART_SWITCH_SID;
	ss_settingVar = 'SwitchIds';
	
	panelHtml += '<p>To control switches using this plug-in, you must '
			+ 'first add the switches to the list below. '
			+ 'When you save your settings, the plug-in will then '
			+ 'create a new "smart switch" device for each switch in the '
			+ 'list. After the new smart switches have been created, '
			+ 'go to the settings page for each '
			+ 'smart switch to add the sensors that control '
			+ 'that switch.</p>';

	panelHtml += '<p>To add a switch, select a device from the drop-down '
			+ 'below and and click the "Add" button. To remove an existing '
			+ 'switch, click the "Remove" button next to the device. ';

	panelHtml += 'To save your changes (and allow the plug-in to create '
			+ 'or remove the smart switches), remember to click the "Save" button '
			+ 'at the top of the screen after closing this dialog.</p>';

	panelHtml += ss_deviceSelectDropdown(SWITCH_SID, SWITCH_SID);

	panelHtml += ss_devicesTable();

	set_panel_html(panelHtml);
}

/*
 * Generic (Shared) functions
 */

function ss_findDevices(sid1, sid2) {
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

function ss_removeUsedDevices(devices) {
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

function ss_getDeviceIdsSetting() {
	var deviceIdsJSON = get_device_state(ssc_deviceId, ssc_settingSid,
			ssc_settingVar, 0);

	deviceIdsJSON = deviceIdsJSON.replace(/'/g, '\"');

	if (deviceIdsJSON == "") {
		return ([]);
	} else {
		return (JSON.parse(deviceIdsJSON));
	}
}

function ss_setDeviceIdsSetting(deviceIds) {
	var deviceIdsJSON = JSON.stringify(deviceIds);

	deviceIdsJSON = deviceIdsJSON.replace(/"/g, '\'');

	set_device_state(ss_deviceId, ss_settingSid, ss_settingVar, deviceIdsJSON, 0);
}

function ss_deviceSelectDropdown(sid1, sid2) {
	var panelHtml = '';

	var devices = ss_findDevices(sid1, sid2);
	devices = ss_removeUsedDevices(devices);

	panelHtml += '<select id="deviceSelect">'
	panelHtml += '<option value="0">-- Select a device --</option>'
	for ( var i = 0; i < devices.length; ++i) {
		var device = devices[i];
		panelHtml += '<option value="' + device.id + '">' + device.name + ' (#'
				+ device.id + ')</option>';

	}
	panelHtml += '</select>';
	panelHtml += '<input type="button" value="Add" onclick="ss_addSelectedDevice()" />';
	panelHtml += '<p/>';

	return panelHtml;
}

function ss_devicesTable() {
	var panelHtml = '';

	panelHtml += ss_tableHeader();

	var deviceIds = ss_getDeviceIdsSetting();

	for ( var i = 0; i < deviceIds.length; ++i) {
		panelHtml += ss_tableRow(jsonp.get_device_by_id(deviceIds[i]));
	}

	panelHtml += ss_tableFooter();

	return panelHtml;
}

function ss_tableHeader() {
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

function ss_tableRow(device) {
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
			+ 'onclick="ss_removeDevice(\'' + device.id + '\')" /></td>';
	panelHtml += '</tr>';

	return panelHtml;
}

function ss_tableFooter() {
	return '</table>';
}

function ss_removeDevice(deviceId) {
	var deviceIds = ss_getDeviceIdsSetting();
	var index = deviceIds.indexOf(deviceId);
	if (index > -1) {
		deviceIds.splice(index, 1);
		ss_setDeviceIdsSetting(deviceIds);
		ss_showSettings(ss_deviceId);
	}
}

function ss_addSelectedDevice() {
	var element = document.getElementById("deviceSelect");
	var deviceId = element.options[element.selectedIndex].value;
	var deviceIds = ss_getDeviceIdsSetting();
	var index = deviceIds.indexOf(deviceId);
	if (index == -1 && deviceId > 0) {
		deviceIds.push(deviceId);
		ss_setDeviceIdsSetting(deviceIds);
		ss_showSettings(ss_deviceId);
	}
}
