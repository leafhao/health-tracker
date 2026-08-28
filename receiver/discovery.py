from __future__ import annotations

import logging
import os
import shutil
import socket
import subprocess

from .identity import ReceiverIdentity


LOGGER = logging.getLogger(__name__)
SERVICE_TYPE = "_healthtracker._tcp"


class BonjourPublisher:
    """Advertise through macOS dns-sd or Linux Avahi when available."""

    def __init__(self, identity: ReceiverIdentity, port: int | None = None) -> None:
        self.identity = identity
        self.port = port or int(os.environ.get("HEALTH_RECEIVER_PORT", "8787"))
        self.process: subprocess.Popen[bytes] | None = None

    def start(self) -> None:
        if os.environ.get("HEALTH_RECEIVER_DISABLE_BONJOUR") == "1" or self.process:
            return
        hostname = socket.gethostname().split(".")[0]
        name = f"Health Receiver · {hostname}"
        txt = [
            "protocol=health-pairing/2",
            f"receiver_key_id={self.identity.key_id}",
            "path=/api/v2/system/identity",
        ]
        dns_sd = shutil.which("dns-sd")
        avahi = shutil.which("avahi-publish-service")
        if dns_sd:
            command = [dns_sd, "-R", name, SERVICE_TYPE, "local.", str(self.port), *txt]
        elif avahi:
            command = [avahi, name, SERVICE_TYPE, str(self.port), *txt]
        else:
            LOGGER.warning("Bonjour advertisement skipped: dns-sd/Avahi is unavailable")
            return
        self.process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        LOGGER.info("Bonjour advertised %s on port %s", name, self.port)

    def stop(self) -> None:
        if not self.process:
            return
        self.process.terminate()
        try:
            self.process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=2)
        self.process = None
