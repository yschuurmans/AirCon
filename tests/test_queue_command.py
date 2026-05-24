import unittest

from aircon.aircon import FglDevice
from aircon.mqtt_client import MqttClient
from aircon.properties import FglFanSpeed, FglOperationMode
from paho.mqtt.client import MQTTMessage


def _device_config():
  return {
      'name': 'Test AC',
      'app': 'fglair-eu',
      'model': 'AP-WA12E',
      'sw_version': '1.0.0',
      'mac_address': '00:11:22:33:44:55',
      'ip_address': '127.0.0.1',
      'temp_type': 'C',
      'lanip_key': 'test-lanip-key',
      'lanip_key_id': 1,
  }


class QueueCommandTests(unittest.TestCase):

  def setUp(self):
    self.device = FglDevice(_device_config(), lambda: None)
    self.notifications = []
    self.device.add_property_change_listener(
        lambda mac_address, prop_name, value, retain: self.notifications.append(
            (mac_address, prop_name, value, retain)))

  def test_precision_scaled_command_keeps_human_readable_temperature(self):
    self.device.queue_command('adjust_temperature', '22')

    command_entry = self.device.commands_queue.get_nowait()
    property_value = command_entry.command['properties'][0]['property']['value']

    self.assertEqual(220, property_value)

    command_entry.updater()

    self.assertEqual(22, self.device.get_property('adjust_temperature'))
    self.assertEqual(('00:11:22:33:44:55', 'adjust_temperature', 22, False),
                     self.notifications[-1])

  def test_precision_scaled_inbound_update_still_uses_raw_device_value(self):
    self.device.update_property('adjust_temperature', 220)

    self.assertEqual(22, self.device.get_property('adjust_temperature'))
    self.assertEqual(('00:11:22:33:44:55', 'adjust_temperature', 22, False),
                     self.notifications[-1])

  def test_non_precision_command_preserves_typed_value(self):
    self.device.queue_command('fan_speed', 'HIGH')

    command_entry = self.device.commands_queue.get_nowait()
    property_value = command_entry.command['properties'][0]['property']['value']

    self.assertEqual(FglFanSpeed.HIGH.value, property_value)

    command_entry.updater()

    self.assertEqual(FglFanSpeed.HIGH, self.device.get_property('fan_speed'))
    self.assertEqual(('00:11:22:33:44:55', 'fan_speed', FglFanSpeed.HIGH, False),
                     self.notifications[-1])

  def test_mqtt_fan_only_command_maps_to_fgl_fan_mode(self):
    mqtt_client = MqttClient(
        client_id='test-client',
        mqtt_topics={
            'sub': 'hisense_ac/{}/{}',
            'pub': 'hisense_ac/{}/{}',
        },
        devices=[self.device])
    message = MQTTMessage(mid=0)
    message.topic = b'hisense_ac/00:11:22:33:44:55/operation_mode/command'
    message.payload = b'fan_only'

    mqtt_client.mqtt_on_message(None, None, message)

    command_entry = self.device.commands_queue.get_nowait()
    property_value = command_entry.command['properties'][0]['property']['value']

    self.assertEqual(FglOperationMode.FAN.value, property_value)

    command_entry.updater()

    self.assertEqual(FglOperationMode.FAN, self.device.get_property('operation_mode'))
    self.assertEqual(('00:11:22:33:44:55', 'operation_mode', FglOperationMode.FAN, False),
                     self.notifications[-1])


if __name__ == '__main__':
  unittest.main()