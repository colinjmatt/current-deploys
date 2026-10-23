#!/usr/bin/env python3
import os
import logging
import argparse
import sys
import time
import subprocess

# -------------------- Config knobs (no flags needed) --------------------
POLL_FAST = 0.003          # 3 ms while wheel is active (~333 Hz)
POLL_IDLE = 0.050          # 50 ms when idle (plays nice with other apps)
ACTIVE_HOLD_SECONDS = 0.8  # stay in fast mode this long after last change
CHAT_ZERO_FLOOR = 2        # <=2% → force 0% + mute
JITTER_THRESHOLD = 1       # Ignore <= 1% ADC noise on potentiometer

# -------------------- HID (hidapi) --------------------
try:
    import hid  # Arch: sudo pacman -S hidapi python-hid
except Exception as e:
    print("ERROR: python-hid (hidapi) not installed. Install with: sudo pacman -S hidapi python-hid", file=sys.stderr)
    raise

STEELSERIES_VID = 0x1038
ARCTIS7PLUS_PID = 0x220e
TARGET_INTERFACE_NUMBER = 7   # match your original interface
FEATURE_REPORT_ID = 0xB0      # first byte observed in your dumps: b0 ...

class Arctis7PlusChatMix:
    def __init__(self, log_level=logging.INFO):
        self.log = self._init_log(log_level)
        self.log.info("Initializing Arctis 7+ ChatMix script...")

        # Open the same HID interface you targeted originally
        try:
            self.h = self._open_interface_by_number(
                STEELSERIES_VID, ARCTIS7PLUS_PID, TARGET_INTERFACE_NUMBER
            )
            if not self.h:
                raise RuntimeError(f"Could not open HID interface #{TARGET_INTERFACE_NUMBER} for 1038:220e")
        except Exception as e:
            self.log.error(f"Failed to initialize Arctis 7+ device: {e}")
            self.die_gracefully()

    # ---------------- Logging ----------------
    def _init_log(self, log_level):
        log = logging.getLogger(__name__)
        log.setLevel(log_level)
        if not log.handlers:
            h = logging.StreamHandler()
            h.setLevel(log_level)
            h.setFormatter(logging.Formatter('%(levelname)8s | %(message)s'))
            log.addHandler(h)
        return log

    # ---------------- HID helpers ----------------
    def _open_interface_by_number(self, vid, pid, iface_num):
        candidates = hid.enumerate(vid, pid)
        path = None
        for c in candidates:
            inum = c.get("interface_number", c.get("interface"))
            if inum == iface_num:
                path = c.get("path")
                break
        if not path and candidates:
            path = candidates[0].get("path")
        if not path:
            return None

        try:
            try:
                dev = hid.Device(path=path)
            except (TypeError, AttributeError):
                dev = hid.device()
                dev.open_path(path)
        except Exception:
            return None

        # non-blocking for fallback interrupt-read
        if hasattr(dev, "set_nonblocking"):
            dev.set_nonblocking(True)
        else:
            try:
                setattr(dev, "nonblocking", True)
            except Exception:
                pass
        return dev

    def _hid_read(self, size, timeout_ms=0):
        try:
            return self.h.read(size, timeout_ms)
        except TypeError:
            return self.h.read(size)

    def _hid_get_feature(self, report_id, size):
        if hasattr(self.h, "get_feature_report"):
            try:
                return self.h.get_feature_report(report_id, size)
            except Exception:
                return []
        return []

    # ---------------- PipeWire helpers ----------------
    def _run(self, cmd, capture=False, check=False):
        return subprocess.run(
            cmd, text=True,
            stdout=subprocess.PIPE if capture else subprocess.DEVNULL,
            stderr=subprocess.PIPE if capture else subprocess.DEVNULL,
            check=check
        )

    def _unload_module_if_exists(self, module_name):
        try:
            module_list = os.popen("pactl list short modules").read().strip().split("\n")
            for line in module_list:
                if module_name in line:
                    module_id = line.split("\t")[0]
                    self._run(["pactl", "unload-module", module_id])
                    self.log.info(f"Unloaded module {module_name}.")
                    break
        except Exception as e:
            self.log.error(f"Failed to unload module {module_name}: {e}")

    def _setup_sinks(self):
        try:
            self.log.info("Setting up PipeWire sinks...")

            self._unload_module_if_exists("module-combine-sink")
            self._unload_module_if_exists("module-null-sink")
            self._unload_module_if_exists("module-loopback")

            self._run([
                "pactl", "load-module", "module-combine-sink",
                "sink_name=Combined", "sink_properties=device.description=Combined",
                "slaves=alsa_output.pci-0000_09_00.1.hdmi-stereo,"
                "alsa_output.pci-0000_0b_00.4.analog-stereo,"
                "alsa_output.usb-SteelSeries_Arctis_7_-00.analog-stereo"
            ])
            self._run([
                "pactl", "load-module", "module-null-sink",
                "sink_name=Chat", "sink_properties=device.description=Chat"
            ])
            self._run([
                "pactl", "load-module", "module-loopback",
                "source=Chat.monitor",
                "sink=alsa_output.usb-SteelSeries_Arctis_7_-00.analog-stereo"
            ])

            self.log.info("PipeWire sinks setup completed.")
        except Exception as e:
            self.log.error(f"Failed to set up sinks: {e}")
            self.die_gracefully()

    def _set_default_sink(self):
        try:
            self._run(["pactl", "set-default-sink", "Combined"])
            self.log.info("Default sink set to Combined.")
        except Exception as e:
            self.log.error(f"Failed to set default sink: {e}")

    # ---------------- Value filtering & hysteresis ----------------
    @staticmethod
    def _normalize_pct(val, zero_floor=0):
        val = max(0, min(val, 100))
        if val >= 99:
            return 100
        if val <= zero_floor:
            return 0
        return val

    @staticmethod
    def _has_changed(new_val, last_val, threshold=JITTER_THRESHOLD):
        if last_val is None:
            return True
        if new_val == last_val:
            return False
        # Always allow clean boundaries
        if new_val in (0, 100):
            return True
        # Suppress single-unit potentiometer micro-wobbles
        return abs(new_val - last_val) > threshold

    # ---------------- Main loop ----------------
    def start_modulator_signal(self):
        self.log.info("Monitoring Arctis 7+ ChatMix wheel...")

        self._setup_sinks()
        self._set_default_sink()

        last_def_vol = None
        last_chat_vol = None
        last_chat_muted = None
        last_move_t = time.monotonic()

        try:
            while True:
                data = self._hid_get_feature(FEATURE_REPORT_ID, 64)
                if not data:
                    data = self._hid_read(64, 0)

                if data:
                    if self.log.level <= logging.DEBUG:
                        self.log.debug("HID report: %s", " ".join(f"{b:02x}" for b in data))

                    default_pct = None
                    virtual_pct = None

                    # Feature report layout: percentages at [4] and [5]
                    if len(data) >= 6 and data[0] == FEATURE_REPORT_ID:
                        default_pct = int(data[4])
                        virtual_pct = int(data[5])
                    # Old interrupt layout fallback: [0]==69, values at [1]/[2]
                    elif len(data) >= 3 and data[0] == 69:
                        default_pct = int(data[1])
                        virtual_pct = int(data[2])

                    if default_pct is not None and virtual_pct is not None:
                        # 1. Check Default (Combined) volume independently
                        norm_def = self._normalize_pct(default_pct, zero_floor=1)
                        if self._has_changed(norm_def, last_def_vol):
                            last_def_vol = norm_def
                            last_move_t = time.monotonic()
                            self.log.debug(f"Default device volume: {norm_def}%")
                            self._run(["pactl", "set-sink-volume", "Combined", f"{norm_def}%"])

                        # 2. Check Chat volume & mute state independently
                        should_mute = (virtual_pct <= CHAT_ZERO_FLOOR)
                        norm_chat = 0 if should_mute else self._normalize_pct(virtual_pct, zero_floor=CHAT_ZERO_FLOOR)

                        if self._has_changed(norm_chat, last_chat_vol):
                            last_chat_vol = norm_chat
                            last_move_t = time.monotonic()
                            self.log.debug(f"Virtual device volume: {norm_chat}%")
                            self._run(["pactl", "set-sink-volume", "Chat", f"{norm_chat}%"])

                        if should_mute != last_chat_muted:
                            last_chat_muted = should_mute
                            last_move_t = time.monotonic()
                            mute_arg = "1" if should_mute else "0"
                            self._run(["pactl", "set-sink-mute", "Chat", mute_arg])

                # Adaptive polling: fast while active, gentle when idle
                sleep_s = POLL_FAST if (time.monotonic() - last_move_t) < ACTIVE_HOLD_SECONDS else POLL_IDLE
                time.sleep(sleep_s)

        except KeyboardInterrupt:
            self.log.info("Keyboard interrupt received. Exiting...")
            self.die_gracefully()
        except Exception as e:
            self.log.error(f"Error in monitoring ChatMix wheel: {e}")
            self.die_gracefully()

    def die_gracefully(self):
        self.log.info("Exiting Arctis 7+ ChatMix script gracefully.")
        try:
            if hasattr(self, "h") and self.h:
                self.h.close()
        except Exception:
            pass
        sys.exit(0)

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description="Arctis 7+ ChatMix script")
    parser.add_argument('--log-level', default='INFO',
                        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'],
                        help='Set the logging level (default: INFO)')
    args = parser.parse_args()
    log_level = getattr(logging, args.log_level.upper(), logging.INFO)

    svc = Arctis7PlusChatMix(log_level)
    svc.start_modulator_signal()