#!/usr/bin/env python3
"""bleguard-discovery — hold a BlueZ filtered-discovery session open and
stream the target device's RSSI property changes on stdout.

Why this helper exists
----------------------
BlueZ only republishes a device's ``RSSI`` property when the value moves
by at least 8 dBm (``RSSI_THRESHOLD`` in device.c).  A phone lying on the
desk next to the laptop fluctuates by roughly 10 dBm, so the exported
value stays frozen at whatever was published first — the classic
"RSSI stuck at -45 dBm while the phone is right there" symptom.

When the adapter runs a *filtered* discovery session, BlueZ publishes the
RSSI on every received advertisement instead
(``device_set_rssi_with_delta(dev, rssi, 0)``).  That turns the property
into a real heartbeat: every advertisement of the phone refreshes it, even
when the measured value did not move.

The filter has to be installed by the same D-Bus connection that later
calls ``StartDiscovery()``: ``SetDiscoveryFilter()`` only pre-sets a
filter for its caller, and that pre-set filter is dropped as soon as the
caller's connection dies.  ``busctl`` is one-shot, so a small long-lived
helper is required.

Protocol (stdout, one line per event, flushed immediately)
----------------------------------------------------------
    ready            discovery is active and the subscription is live
    rssi <int>       the device's RSSI property changed to <int> dBm
    device <path>    the device object moved to a new D-Bus path
    error <text>     recoverable error; the helper keeps running

The helper exits when it receives SIGTERM/SIGINT; on the way out it stops
the discovery session it owns.
"""

import argparse
import signal
import sys

try:
    import gi

    gi.require_version("Gio", "2.0")
    from gi.repository import Gio, GLib
except Exception as exc:  # pragma: no cover - environment problem
    sys.stderr.write("bleguard-discovery: cannot load GObject Introspection: %s\n" % exc)
    sys.exit(70)


def emit(line):
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


def variant_to_int(value):
    """Read an integer out of a property value.

    Depending on how PyGObject unmarshalled the ``a{sv}`` payload the
    value is either a plain Python int or a GVariant, so both are
    accepted.
    """
    if isinstance(value, int):
        return value
    kind = value.get_type_string()
    if kind == "n":  # int16
        return value.get_int16()
    if kind == "i":  # int32
        return value.get_int32()
    if kind == "u":  # uint32
        return value.get_uint32()
    if kind == "q":  # uint16
        return value.get_uint16()
    if kind == "y":  # uint8
        return value.get_uint8()
    if kind == "x":  # int64
        return value.get_int64()
    if kind == "t":  # uint64
        return value.get_uint64()
    if kind == "d":  # double
        return int(value.get_double())
    raise ValueError("not an integer value: %r" % (value,))


def variant_to_string(value):
    if isinstance(value, str):
        return value
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    kind = value.get_type_string()
    if kind == "s":
        return value.get_string()
    raise ValueError("not a string value: %r" % (value,))


class Discovery:
    def __init__(self, adapter_path, device_path, device_mac):
        self.adapter_path = adapter_path
        self.device_path = device_path
        self.device_mac = device_mac
        self.loop = GLib.MainLoop()
        self.bus = None
        self.adapter = None
        self.subscription = 0
        self.address_cache = {}
        self.started = False
        # "/dev_EC_2F_90_89_5F_3C" — the tail of the device object path.
        self.device_suffix = ""
        if device_path and "/dev_" in device_path:
            self.device_suffix = device_path[device_path.index("/dev_") :]
        elif device_mac:
            self.device_suffix = "/dev_" + device_mac.replace(":", "_").upper()

    # -- lifecycle ---------------------------------------------------------
    def run(self):
        signal.signal(signal.SIGTERM, self._on_signal)
        signal.signal(signal.SIGINT, self._on_signal)
        try:
            self.bus = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
            self._resolve_device()
            self._start_discovery()
            self._subscribe()
        except GLib.Error as exc:
            emit("error %s" % exc.message)
            return 1
        emit("ready")
        self.started = True
        # Keep an eye on the discovery session: if the adapter is reset or
        # BlueZ restarts, the session dies with it and the RSSI would stay
        # frozen again. Re-establish it periodically.
        GLib.timeout_add_seconds(15, self._tick)
        self.loop.run()
        self._stop_discovery()
        return 0

    def _on_signal(self, *_args):
        self.loop.quit()

    def _tick(self):
        if self.adapter is None:
            return True
        try:
            discovering = self.adapter.get_cached_property("Discovering")
            if discovering is None or not discovering.get_boolean():
                emit("error discovery stopped, restarting")
                self._start_discovery()
        except GLib.Error as exc:
            emit("error %s" % exc.message)
        return True

    # -- BlueZ -------------------------------------------------------------
    def _adapter_proxy(self):
        return Gio.DBusProxy.new_sync(
            self.bus,
            Gio.DBusProxyFlags.DO_NOT_AUTO_START,
            None,
            "org.bluez",
            self.adapter_path,
            "org.bluez.Adapter1",
            None,
        )

    def _resolve_device(self):
        """Find the device object, tolerating a recreated D-Bus path."""
        if self.device_path:
            return
        if not self.device_mac:
            raise GLib.Error("no device path and no MAC to look for")
        suffix = self.device_mac.replace(":", "_").upper()
        for index in range(0, 10):
            candidate = "/org/bluez/hci%d/dev_%s" % (index, suffix)
            if self._path_exists(candidate):
                self.device_path = candidate
                return
        raise GLib.Error("device %s not found on any adapter" % self.device_mac)

    def _path_exists(self, path):
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.bus,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                "org.bluez",
                path,
                "org.bluez.Device1",
                None,
            )
        except GLib.Error:
            return False
        return proxy.get_cached_property("Address") is not None

    def _address_of(self, path):
        """Address of the device object at `path` (cached)."""
        if path in self.address_cache:
            return self.address_cache[path]
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.bus,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                "org.bluez",
                path,
                "org.bluez.Device1",
                None,
            )
            prop = proxy.get_cached_property("Address")
            if prop is None:
                return None
            address = variant_to_string(prop)
        except GLib.Error:
            return None
        self.address_cache[path] = address
        return address

    def _matches_device(self, path):
        """Is `path` the object of our phone?

        BlueZ derives the device object path from the device's *identity*
        address, so the path stays stable across adapter resets — the
        object may be destroyed and recreated, but under the same path.
        The suffix check is a cheap safety net for the case where the
        plugin handed us a path that no longer exists.
        """
        if path == self.device_path:
            return True
        if self.device_suffix and path.endswith(self.device_suffix):
            return True
        return False

    def _start_discovery(self):
        self.adapter = self._adapter_proxy()
        # Permissive filter: every device at any distance, no UUID
        # restriction, no path loss limit.  A filtered session is what makes
        # BlueZ publish RSSI with a delta of 0 (i.e. on every advertisement);
        # a regular session keeps the 8 dBm threshold and freezes the value.
        # The filter must stay permissive so that a phone walking out of
        # range is still reported with its fading RSSI instead of being
        # filtered out entirely.
        # NB: BlueZ parses the "RSSI" filter entry as an int16, so the
        # variant has to be "n" and not "i".
        filt = GLib.Variant("(a{sv})", ({"RSSI": GLib.Variant("n", -127)},))
        self.adapter.call_sync(
            "SetDiscoveryFilter", filt, Gio.DBusCallFlags.NONE, -1, None
        )
        self.adapter.call_sync(
            "StartDiscovery", GLib.Variant("()", ()), Gio.DBusCallFlags.NONE, -1, None
        )

    def _stop_discovery(self):
        if self.adapter is None:
            return
        try:
            self.adapter.call_sync(
                "StopDiscovery", GLib.Variant("()", ()), Gio.DBusCallFlags.NONE, -1, None
            )
        except GLib.Error:
            # The session is torn down by the bus connection going away
            # anyway; a failure here must not mask the clean shutdown.
            pass

    def _subscribe(self):
        # Subscribe to every org.bluez.Device1 object rather than to one
        # path: BlueZ recreates the device object (with a new path) whenever
        # the adapter resets, and the events would otherwise be lost.
        self.subscription = self.bus.signal_subscribe(
            sender="org.bluez",
            interface_name="org.freedesktop.DBus.Properties",
            member="PropertiesChanged",
            object_path=None,
            arg0="org.bluez.Device1",
            flags=0,
            callback=self._on_properties_changed,
        )
        self._emit_current_rssi()

    def _emit_current_rssi(self):
        """Push the current value once, so the consumer starts warm."""
        if not self.device_path:
            return
        try:
            proxy = Gio.DBusProxy.new_sync(
                self.bus,
                Gio.DBusProxyFlags.DO_NOT_AUTO_START,
                None,
                "org.bluez",
                self.device_path,
                "org.bluez.Device1",
                None,
            )
            prop = proxy.get_cached_property("RSSI")
            if prop is not None:
                emit("rssi %d" % variant_to_int(prop))
        except GLib.Error as exc:
            emit("error %s" % exc.message)

    # -- events ------------------------------------------------------------
    def _on_properties_changed(self, _conn, _sender, path, _iface, _name, params):
        try:
            changed = params[1]
            if "RSSI" not in changed:
                return
            if not self._matches_device(path):
                return
            if path != self.device_path:
                self.device_path = path
                emit("device %s" % path)
            emit("rssi %d" % variant_to_int(changed["RSSI"]))
        except Exception as exc:  # pragma: no cover - defensive
            emit("error %s" % exc)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--adapter", help="BlueZ adapter object path")
    parser.add_argument("--device", help="BlueZ device object path")
    parser.add_argument("--mac", help="device address, used to find the device path")
    args = parser.parse_args()
    if not args.adapter and not args.device:
        parser.error("either --adapter/--device or --mac is required")
    return Discovery(args.adapter, args.device, args.mac).run()


if __name__ == "__main__":
    sys.exit(main())
