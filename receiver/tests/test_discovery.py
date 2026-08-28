from __future__ import annotations

import unittest
from types import SimpleNamespace
from unittest.mock import Mock, call, patch

from receiver.discovery import BonjourPublisher, SERVICE_TYPE


class BonjourPublisherTests(unittest.TestCase):
    @patch("receiver.discovery.subprocess.Popen")
    @patch("receiver.discovery.shutil.which")
    @patch("receiver.discovery.socket.gethostname", return_value="linux-receiver.example")
    def test_linux_uses_avahi_with_the_ios_service_type(
        self,
        _: Mock,
        which: Mock,
        popen: Mock,
    ) -> None:
        which.side_effect = [None, "/usr/bin/avahi-publish-service"]
        identity = SimpleNamespace(key_id="receiver-key-123")

        BonjourPublisher(identity, port=8787).start()

        self.assertEqual(
            which.call_args_list,
            [call("dns-sd"), call("avahi-publish-service")],
        )
        command = popen.call_args.args[0]
        self.assertEqual(command[0], "/usr/bin/avahi-publish-service")
        self.assertEqual(command[2:4], [SERVICE_TYPE, "8787"])
        self.assertIn("protocol=health-pairing/2", command)
        self.assertIn("receiver_key_id=receiver-key-123", command)


if __name__ == "__main__":
    unittest.main()
