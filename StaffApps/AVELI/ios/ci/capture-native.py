#!/usr/bin/env python3
"""Build AVELI for a real iOS Simulator and capture its DEBUG preview screens.

This is native simulator QA, not a browser automation script. All compilation
output and captures remain inside the caller's private output directory.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import http.client
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import time
import uuid


SCREENS = (
    "inbox", "shared", "compose", "cloud", "uploads", "chat", "assistant",
    "team", "integrations", "settings", "avatar", "access", "login",
    "reader", "profile", "mailbox", "translator",
)
EXPECTED_BUNDLE_ID = "ru.archiverf.aveli"
LOCAL_PORT = 19473
LOCAL_HOST = f"127.0.0.1:{LOCAL_PORT}"
REPORT_SCHEMA = "aveli.native-design-qa.v1"


class QAError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(v) for v in re.findall(r"\d+", value))


def select_runtime(catalog: dict, sdk_version: str) -> dict:
    sdk = version_tuple(sdk_version)
    if not sdk or sdk[0] < 17:
        raise QAError("Selected Xcode does not provide an iOS 17+ simulator SDK.")
    ceiling = (sdk + (0, 0))[:2]
    available = [
        item for item in catalog.get("runtimes", [])
        if item.get("isAvailable", False)
        and str(item.get("identifier", "")).startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and version_tuple(str(item.get("version", "0"))) >= (17,)
        # A shared macOS runner can contain runtimes installed by newer Xcodes.
        # Match the selected SDK, not the numerically newest global runtime.
        and (version_tuple(str(item.get("version", "0"))) + (0, 0))[:2] <= ceiling
    ]
    if not available:
        raise QAError(f"No available iOS 17+ runtime compatible with selected simulator SDK {sdk_version}.")
    return max(available, key=lambda item: version_tuple(str(item.get("version", "0"))))


def select_device_type(catalog: dict, runtime: dict, family: str = "iPhone") -> dict:
    major = version_tuple(str(runtime.get("version", "0")))[0]
    items = []
    for item in catalog.get("devicetypes", []):
        name = str(item.get("name", ""))
        if not name.startswith(family + " "):
            continue
        minimum = item.get("minRuntimeVersion")
        maximum = item.get("maxRuntimeVersion")
        # Apple's integer runtime versions encode the major in the high bits.
        if isinstance(minimum, int) and major < (minimum >> 16):
            continue
        if isinstance(maximum, int) and maximum != 4294967295 and major > (maximum >> 16):
            continue
        items.append(item)
    if not items:
        raise QAError(f"No {family} simulator device type supports iOS {major}.")
    if family == "iPhone":
        # Normal iPhone size first, then reasonable fallbacks; avoid SE-only QA.
        preferred = (
            "iPhone 16", "iPhone 15", "iPhone 16 Pro", "iPhone 15 Pro",
            "iPhone 14", "iPhone 14 Pro", "iPhone 13", "iPhone 12",
        )
    else:
        preferred = (
            "iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)",
            "iPad Air 13-inch (M2)", "iPad Pro (12.9-inch) (6th generation)",
            "iPad Air 11-inch (M3)", "iPad Air 11-inch (M2)",
            "iPad Pro 11-inch (M4)", "iPad (10th generation)",
        )
    for name in preferred:
        match = next((item for item in items if item.get("name") == name), None)
        if match:
            return match
    # Runtime-compatible newest entry supplied by CoreSimulator is a fallback.
    return items[-1]


def png_info(path: Path) -> dict:
    raw = path.read_bytes()
    if len(raw) < 24 or raw[:8] != b"\x89PNG\r\n\x1a\n" or raw[12:16] != b"IHDR":
        raise QAError("Simulator did not produce a valid PNG screenshot.")
    width, height = struct.unpack(">II", raw[16:24])
    if width < 320 or height < 320:
        raise QAError("Simulator screenshot resolution is unexpectedly small.")
    return {
        "widthPixels": width, "heightPixels": height,
        "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
    }


def jpeg_info(path: Path) -> dict:
    """Validate native JPEG header structure/metadata; do not decode or edit pixels."""
    raw = path.read_bytes()
    if len(raw) < 12 or raw[:2] != b"\xff\xd8" or raw[-2:] != b"\xff\xd9":
        raise QAError("Simulator did not produce a complete JPEG screenshot.")
    offset, dimensions, components, sof_marker = 2, None, None, None
    sof_markers = {0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF}
    while offset < len(raw) - 2:
        if raw[offset] != 0xFF:
            raise QAError("JPEG metadata contains an invalid marker boundary.")
        while offset < len(raw) and raw[offset] == 0xFF:
            offset += 1
        if offset >= len(raw):
            raise QAError("JPEG metadata ends inside a marker.")
        marker = raw[offset]
        offset += 1
        if marker == 0x01:
            continue
        if marker in {0x00, 0xD8, 0xD9} or 0xD0 <= marker <= 0xD7:
            raise QAError("JPEG metadata contains an unexpected standalone marker.")
        if offset + 2 > len(raw):
            raise QAError("JPEG metadata omits a segment length.")
        length = struct.unpack(">H", raw[offset:offset + 2])[0]
        end = offset + length
        if length < 2 or end > len(raw):
            raise QAError("JPEG metadata contains an invalid segment length.")
        body = offset + 2
        if marker in sof_markers:
            if length < 8 or dimensions is not None:
                raise QAError("JPEG metadata contains an invalid frame header.")
            height, width = struct.unpack(">HH", raw[body + 1:body + 5])
            components = raw[body + 5]
            if components < 1 or length != 8 + 3 * components:
                raise QAError("JPEG frame components are incomplete.")
            if width < 320 or height < 320:
                raise QAError("Simulator screenshot resolution is unexpectedly small.")
            dimensions, sof_marker = (width, height), marker
        if marker == 0xDA:
            if dimensions is None or length < 8:
                raise QAError("JPEG scan starts without a valid frame header.")
            count = raw[body]
            if count < 1 or count > components or length != 6 + 2 * count:
                raise QAError("JPEG scan components are incomplete.")
            return {
                "widthPixels": dimensions[0], "heightPixels": dimensions[1],
                "bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest(),
                "imageFormat": "jpeg", "sofMarker": f"0x{sof_marker:02x}",
                "validation": "JPEG metadata and structure; compressed pixels not decoded",
            }
        offset = end
    raise QAError("JPEG screenshot is missing a bounded image scan.")


def screen_list(value: str) -> tuple[str, ...]:
    names = tuple(name.strip() for name in value.split(","))
    if any(not name or name not in SCREENS for name in names):
        raise argparse.ArgumentTypeError("--screens must contain only valid screen names separated by commas.")
    return tuple(dict.fromkeys(names))


class Runner:
    def __init__(self, args: argparse.Namespace):
        self.args = args
        self.selected_screens = tuple(args.screens)
        self.capture_light_settings = "settings" in self.selected_screens
        self.repo = Path(args.repo_root).expanduser().resolve()
        self.output = Path(args.output).expanduser().resolve()
        self.started = time.monotonic()
        self.deadline = self.started + args.timeout
        self.owned_devices: list[str] = []
        self.app_processes: dict[str, int] = {}
        self.command_number = 0
        self.work: Path | None = None
        self.web_app: Path | None = None
        self.simulator_app: Path | None = None
        self.report = {
            "schema": REPORT_SCHEMA,
            "startedAt": utc_now(),
            "status": "running",
            "nativeSimulator": True,
            "physicalDeviceTested": False,
            "visualReviewRequired": True,
            "build": {"configuration": "Debug", "sdk": "iphonesimulator", "compiled": False},
            "screenshots": [],
            "diagnostics": [],
            "requiredCaptureCount": len(self.selected_screens) + int(self.capture_light_settings),
            "requiredCapturesComplete": False,
            "selectedScreens": list(self.selected_screens),
            "screenshotEncoding": "native-simctl-direct-jpeg",
            "expectedCaptures": [{"screen": screen, "theme": "dark", "family": "iPhone"} for screen in self.selected_screens]
                + ([{"screen": "settings", "theme": "light", "family": "iPhone"}] if self.capture_light_settings else []),
            "devices": [],
            "errors": [],
            "security": {"status": "not-run", "scope": "own-app-loopback-server", "checks": []},
        }

    def remaining(self) -> float:
        value = self.deadline - time.monotonic()
        if value <= 0:
            raise QAError("Native simulator QA exceeded its configured time budget.")
        return value

    def run(self, command: list[str], name: str, timeout: float = 45, *, required: bool = True) -> str:
        self.command_number += 1
        safe_name = re.sub(r"[^a-zA-Z0-9._-]", "-", name)
        log = self.output / "logs" / f"{self.command_number:02d}-{safe_name}.log"
        budget = min(timeout, self.remaining())
        # simctl can start launchd children that keep inherited pipe handles open.
        # File-backed output avoids communicate() hanging after its parent dies.
        timed_out = False
        with tempfile.TemporaryFile() as stdout_file, tempfile.TemporaryFile() as stderr_file:
            process = subprocess.Popen(command, cwd=self.repo, stdout=stdout_file,
                                       stderr=stderr_file, start_new_session=True)
            try:
                process.wait(timeout=budget)
            except subprocess.TimeoutExpired:
                timed_out = True
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            stdout_file.seek(0)
            stderr_file.seek(0)
            stdout, stderr = stdout_file.read(), stderr_file.read()
        log.write_bytes(stdout + b"\n" + stderr)
        if timed_out:
            message = f"{name} exceeded its time limit; see private log {log.name}."
            if required:
                raise QAError(message)
            self.report.setdefault("optionalCommandWarnings", []).append(message)
        if process.returncode and required:
            raise QAError(f"{name} failed with exit {process.returncode}; see private log {log.name}.")
        return stdout.decode("utf-8", errors="replace").strip()

    def wait_ready(self, data_container: Path, screen: str, theme: str, request_id: str) -> dict | None:
        marker = data_container / "Documents" / "aveli-preview.json"
        # A DEBUG hook writes this after M.showScreen/theme and two paint frames.
        marker_deadline = min(self.deadline, time.monotonic() + 24.0)
        while time.monotonic() < marker_deadline:
            try:
                value = json.loads(marker.read_text())
                if (value.get("requestID") == request_id and value.get("screen") == screen
                        and value.get("theme") == theme):
                    time.sleep(min(0.25, max(0, self.remaining())))
                    return value
            except (OSError, ValueError):
                pass
            time.sleep(min(0.15, max(0, self.remaining())))
        # Captures remain useful if a project version does not implement the hook,
        # but the report never claims DOM readiness from an arbitrary delay.
        return None

    def make_device(self, catalog: dict, runtime: dict, family: str, *, wait: bool = True) -> str:
        device_type = select_device_type(catalog, runtime, family)
        name = f"AVELI private design QA {family} {os.getpid()}"
        udid = self.run(
            ["xcrun", "simctl", "create", name, device_type["identifier"], runtime["identifier"]],
            f"create-{family}", 20,
        )
        if not re.fullmatch(r"[0-9A-Fa-f-]{36}", udid):
            raise QAError("CoreSimulator returned an invalid new device identifier.")
        self.owned_devices.append(udid)
        self.report["devices"].append({
            "name": name, "udid": udid, "deviceType": device_type["name"],
            "runtime": runtime["name"], "runtimeVersion": runtime["version"],
            "family": family, "createdByThisRun": True,
        })
        if self.simulator_app and self.simulator_app.is_dir():
            self.run(["open", "-a", str(self.simulator_app), "--args", "-CurrentDeviceUDID", udid],
                     f"open-selected-Xcode-Simulator-{family}", 15, required=False)
        # The GUI can already have booted this specific device; this is harmless.
        self.run(["xcrun", "simctl", "boot", udid], f"boot-{family}", 20, required=False)
        if wait:
            self.wait_for_device(udid, family)
        return udid

    def wait_for_device(self, udid: str, family: str) -> None:
        device = next(item for item in self.report["devices"] if item["udid"] == udid)
        boot_started = time.monotonic()
        # First boot may run data migration for substantially more than a minute.
        # Keep a bounded budget and leave room to collect required screenshots.
        reserve = 90 if family == "iPhone" else 20
        boot_budget = min(180 if family == "iPhone" else 120, max(15, self.remaining() - reserve))
        try:
            self.run(["xcrun", "simctl", "bootstatus", udid, "-b"], f"bootstatus-{family}", boot_budget)
            device["terminalBootStatusObserved"] = True
        except QAError as error:
            states = json.loads(self.run(["xcrun", "simctl", "list", "devices", "--json"], f"inspect-own-{family}-after-bootstatus", 15))
            own = next((item for devices in states.get("devices", {}).values() for item in devices if item.get("udid") == udid), None)
            if not own or own.get("state") != "Booted":
                raise error
            # Stage4/System App can remain pending despite a launchable Simulator.
            # Only this application's matched DEBUG marker and PNG prove readiness.
            device.update({"terminalBootStatusObserved": False, "state": "Booted", "bootStatusWarning": str(error)})
        device["bootElapsedSeconds"] = round(time.monotonic() - boot_started, 2)
        # Preserve real Simulator status-bar values. Cosmetic IPC must not
        # prevent installing and verifying the actual application.

    def sign_simulator_app(self, app: Path) -> None:
        """Ad hoc signing is simulator-only and needs no developer account.

        Record the pre-existing signatures rather than assuming that disabling
        Xcode's CodeSign step prevented linker-generated ad hoc signatures.
        """
        codesign = "/usr/bin/codesign"
        signing = {
            "mode": "ad-hoc-simulator-only", "developerAccountRequired": False,
            "unsignedCauseAssumed": False, "verified": False,
            "nestedDylibs": [path.name for path in sorted(app.glob("*.dylib"))],
        }
        self.report["simulatorSigning"] = signing
        self.run([codesign, "--display", "--verbose=4", str(app)],
                 "simulator-signature-before-display", 10, required=False)
        self.run([codesign, "--verify", "--deep", "--strict", "--verbose=4", str(app)],
                 "simulator-signature-before-verify", 15, required=False)
        # Xcode Debug can put AVELI.debug.dylib and __preview.dylib at the app
        # root. Sign each explicitly before sealing the outer app bundle.
        for dylib in sorted(app.glob("*.dylib")):
            self.run([codesign, "--verify", "--strict", "--verbose=4", str(dylib)],
                     f"simulator-signature-before-{dylib.name}", 10, required=False)
            self.run([codesign, "--force", "--sign", "-", str(dylib)],
                     f"simulator-adhoc-sign-{dylib.name}", 20)
            self.run([codesign, "--verify", "--strict", "--verbose=4", str(dylib)],
                     f"simulator-adhoc-verify-{dylib.name}", 15)
        self.run([codesign, "--force", "--sign", "-", str(app)],
                 "simulator-adhoc-sign-app", 30)
        self.run([codesign, "--verify", "--deep", "--strict", "--verbose=4", str(app)],
                 "simulator-adhoc-verify-app", 30)
        signing["verified"] = True

    def capture_system_diagnostic(self, udid: str, family: str) -> None:
        """An owned simulator's system UI before installation, never an app screen."""
        if udid not in self.owned_devices:
            raise QAError("Refusing to capture an unowned simulator diagnostic.")
        destination = self.output / "diagnostics" / f"{family}-before-install.jpg"
        destination.parent.mkdir(parents=True, exist_ok=True)
        item = {
            "kind": "owned-simulator-system-ui", "stage": "before-app-install",
            "family": family, "deviceUdid": udid, "applicationScreenshot": False,
            "status": "pending", "startedAt": utc_now(),
        }
        self.report["diagnostics"].append(item)
        started = time.monotonic()
        try:
            self.run(["xcrun", "simctl", "io", udid, "screenshot", "--type=jpeg", str(destination)],
                     f"diagnostic-{family}-before-install", 90, required=False)
            item.update(jpeg_info(destination))
            item.update({"status": "captured", "path": str(destination.relative_to(self.output)), "capturedAt": utc_now()})
        except (OSError, QAError) as error:
            item.update({"status": "failed", "error": str(error)})
            # Missing or slow system UI is diagnostic evidence; it must not
            # prevent an actual install/launch attempt within the total budget.
        finally:
            item["elapsedSeconds"] = round(time.monotonic() - started, 2)

    def probe_http(self, method: str, path: str, *, headers: dict | None = None,
                   body: bytes | None = None) -> tuple[int, dict, bytes]:
        """Send paths verbatim: unlike a URL client, http.client keeps ../ intact."""
        budget = min(2.0, self.remaining())
        connection = http.client.HTTPConnection("127.0.0.1", LOCAL_PORT, timeout=budget)
        request_headers = {"Host": LOCAL_HOST, "Connection": "close"}
        if headers:
            request_headers.update(headers)
        try:
            connection.request(method, path, body=body, headers=request_headers)
            response = connection.getresponse()
            # HTML/JavaScript never enters logs or the public command output.
            payload = response.read(8 * 1_024 * 1_024 + 1)
            return response.status, {key.lower(): value for key, value in response.getheaders()}, payload
        finally:
            connection.close()

    def run_security_probe(self, udid: str) -> None:
        security = self.report["security"]
        security["startedAt"] = utc_now()
        lsof = shutil.which("lsof") or ("/usr/sbin/lsof" if Path("/usr/sbin/lsof").is_file() else None)
        binding = {"name": "loopback-listener-binding", "optionalTool": "lsof"}
        security["checks"].append(binding)
        if lsof:
            try:
                raw = self.run([lsof, "-nP", f"-iTCP:{LOCAL_PORT}", "-sTCP:LISTEN", "-Fpn"], "security-loopback-binding", 5, required=False)
                pids: list[int] = []
                addresses: list[str] = []
                for line in raw.splitlines():
                    if line.startswith("p") and line[1:].isdigit():
                        pids.append(int(line[1:]))
                    elif line.startswith("n"):
                        addresses.append(line[1:])
                owner = self.app_processes.get(udid)
                binding.update({
                    "expectedAppPid": owner, "listeningPids": pids,
                    "listeningAddresses": addresses,
                    "passed": bool(addresses) and all(value == LOCAL_HOST for value in addresses)
                    and owner is not None and bool(pids) and all(pid == owner for pid in pids),
                })
            except (OSError, QAError) as error:
                binding.update({"passed": False, "error": type(error).__name__})
            if binding.get("passed") is not True:
                # Do not probe, kill or otherwise touch an unfamiliar listener.
                security.update({"status": "failed", "finishedAt": utc_now(), "httpProbesSkipped": "Listener is not proven to be this app's exact loopback bind."})
                return
        else:
            binding.update({"skipped": True, "reason": "lsof is unavailable on this runner."})
        cases = (
            ("bundled-index", "GET", "/", {}, None, {200}),
            ("bundled-js", "GET", "/app.js", {}, None, {200}),
            ("head-index", "HEAD", "/", {}, None, {200}),
            ("static-post-rejected", "POST", "/app.js", {}, b"qa", {405}),
            ("static-put-rejected", "PUT", "/app.js", {}, b"qa", {405}),
            ("literal-traversal", "GET", "/../Info.plist", {}, None, {400, 404}),
            ("encoded-traversal", "GET", "/%2e%2e/Info.plist", {}, None, {400, 404}),
            ("double-encoded-traversal", "GET", "/%252e%252e/Info.plist", {}, None, {400, 404}),
            ("encoded-separator-traversal", "GET", "/%2e%2e%2fInfo.plist", {}, None, {400, 404}),
            ("encoded-backslash-traversal", "GET", "/%5c..%5cInfo.plist", {}, None, {400, 404}),
            ("encoded-null-rejected", "GET", "/%00", {}, None, {400}),
            ("invalid-percent-rejected", "GET", "/%zz", {}, None, {400}),
            ("outside-system-file", "GET", "/etc/passwd", {}, None, {404}),
            ("outside-app-documents", "GET", "/Documents/aveli-preview.json", {}, None, {404}),
            ("outside-bundle-plist", "GET", "/Info.plist", {}, None, {404}),
            ("outside-repo-file", "GET", "/.git/config", {}, None, {404}),
            ("foreign-host-rejected", "GET", "/app.js", {"Host": "attacker.invalid"}, None, {403}),
            ("foreign-origin-rejected", "GET", "/app.js", {"Origin": "https://attacker.invalid"}, None, {403}),
            ("null-origin-rejected", "GET", "/app.js", {"Origin": "null"}, None, {403}),
            ("self-origin-allowed", "GET", "/app.js", {"Origin": f"http://{LOCAL_HOST}"}, None, {200}),
            ("local-demo-session", "GET", "/api/session", {}, None, {200}),
            ("static-body-rejected", "GET", "/app.js", {}, b"q", {400}),
            ("unconnected-api-rejected", "POST", "/api/translate", {}, b"{}", {503}),
        )
        for name, method, path, headers, body, expected in cases:
            result = {"name": name, "method": method, "path": path, "expectedStatuses": sorted(expected)}
            security["checks"].append(result)
            try:
                status, response_headers, payload = self.probe_http(method, path, headers=headers, body=body)
                passed = status in expected
                result.update({
                    "statusCode": status, "bodyBytesInspected": len(payload),
                    "bodySha256": hashlib.sha256(payload).hexdigest(),
                    "contentType": response_headers.get("content-type"),
                    "passed": passed,
                })
                if name == "bundled-index":
                    safe_headers = {
                        "nosniff": response_headers.get("x-content-type-options") == "nosniff",
                        "noReferrer": response_headers.get("referrer-policy") == "no-referrer",
                        "noStore": response_headers.get("cache-control") == "no-store",
                        "cspPresent": bool(response_headers.get("content-security-policy")),
                        "noCookieIssued": "set-cookie" not in response_headers,
                    }
                    result["securityHeaders"] = safe_headers
                    result["passed"] = passed and all(safe_headers.values()) and "text/html" in response_headers.get("content-type", "")
                if name == "head-index":
                    result["passed"] = passed and len(payload) == 0
                if name in ("bundled-index", "bundled-js"):
                    asset = self.web_app / ("index.html" if name == "bundled-index" else "app.js") if self.web_app else None
                    expected_payload = asset.read_bytes() if asset and asset.is_file() else None
                    same_asset = expected_payload is not None and hashlib.sha256(expected_payload).digest() == hashlib.sha256(payload).digest()
                    result["matchesCompiledBundledAsset"] = same_asset
                    result["passed"] = result["passed"] and same_asset
                if name == "local-demo-session":
                    session = json.loads(payload)
                    contract = {
                        "modeIsLocalDemo": session.get("mode") == "local-demo",
                        "userIsNull": session.get("user", "missing") is None,
                        "csrfIsNull": session.get("csrf", "missing") is None,
                        "remoteConfiguredFalse": session.get("remoteConfigured") is False,
                        "noCookieIssued": "set-cookie" not in response_headers,
                    }
                    result["sessionContract"] = contract
                    result["passed"] = passed and all(contract.values())
            except (OSError, ValueError, http.client.HTTPException, QAError) as error:
                result.update({"passed": False, "error": type(error).__name__})
        security["status"] = "passed" if all(item.get("passed", item.get("skipped", False)) for item in security["checks"]) else "failed"
        security["finishedAt"] = utc_now()

    def save_bootstrap(self, data_container: Path, item: dict) -> None:
        try:
            source = data_container / "Documents" / "aveli-bootstrap.json"
            raw = source.read_bytes()
            if len(raw) > 65_536:
                raise ValueError("Bootstrap metadata exceeded its expected size.")
            bootstrap = json.loads(raw)
            if not isinstance(bootstrap, dict) or bootstrap.get("requestID") != item["previewRequestID"]:
                item["bootstrapMatchedRequest"] = False
                return
            target = self.output / "readiness" / item["family"] / f"{item['screen']}-{item['theme']}-bootstrap.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(json.dumps(bootstrap, ensure_ascii=False, indent=2) + "\n")
            item.update({
                "bootstrapMatchedRequest": True, "bootstrapReport": str(target.relative_to(self.output)),
                "nativeBootstrap": bootstrap,
                "nativeDiagnosticCode": bootstrap.get("diagnosticCode"),
                "nativeBootstrapStage": bootstrap.get("stage"),
            })
        except OSError:
            item.setdefault("bootstrapMatchedRequest", False)
        except (ValueError, TypeError):
            item["bootstrapReadError"] = "Invalid native bootstrap metadata."

    def save_network(self, data_container: Path, item: dict, phase: str) -> None:
        """Copy bounded, request-matched DEBUG telemetry; never HTTP headers/body."""
        try:
            raw = (data_container / "Documents" / "aveli-network.json").read_bytes()
            if len(raw) > 65_536:
                raise ValueError("Network metadata exceeded its expected size.")
            network = json.loads(raw)
            if not isinstance(network, dict) or network.get("requestID") != item["previewRequestID"]:
                item["networkMatchedRequest"] = False
                return
            target = self.output / "readiness" / item["family"] / f"{item['screen']}-{item['theme']}-network-{phase}.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)
            errors = sorted({str(event["errorCode"]) for event in network.get("events", [])
                             if isinstance(event, dict) and event.get("errorCode") is not None})
            item.setdefault("networkReports", {})[phase] = str(target.relative_to(self.output))
            item.update({
                "networkMatchedRequest": True,
                "nativeTransport": {
                    "phase": phase, "listenerReady": network.get("listenerReady"),
                    "activeConnections": network.get("activeConnections"),
                    "counts": network.get("counts", {}), "errorCodes": errors,
                    "updatedAt": network.get("updatedAt"),
                },
            })
        except OSError:
            item.setdefault("networkMatchedRequest", False)
        except (ValueError, TypeError):
            item["networkReadError"] = "Invalid native network metadata."

    def capture(self, udid: str, data_container: Path, screen: str, theme: str,
                family: str, first: bool = False) -> None:
        marker = data_container / "Documents" / "aveli-preview.json"
        marker.unlink(missing_ok=True)
        (data_container / "Documents" / "aveli-bootstrap.json").unlink(missing_ok=True)
        (data_container / "Documents" / "aveli-network.json").unlink(missing_ok=True)
        started = time.monotonic()
        item = {
            "screen": screen, "theme": theme, "family": family, "deviceUdid": udid,
            "status": "pending", "capturedAt": None,
            "appearanceDriver": "bundled-app-theme-and-native-appearance-bridge",
        }
        request_id = str(uuid.uuid4())
        item["previewRequestID"] = request_id
        self.report["screenshots"].append(item)
        try:
            launch_output = self.run([
                "xcrun", "simctl", "launch", "--terminate-running-process", udid,
                EXPECTED_BUNDLE_ID, "--aveli-preview-screen", screen,
                "--aveli-preview-theme", theme, "--aveli-preview-request", request_id,
            ], f"launch-{family}-{screen}-{theme}", 45)
            pid_match = re.search(r":\s*(\d+)\s*$", launch_output)
            if pid_match:
                self.app_processes[udid] = int(pid_match.group(1))
            ready = self.wait_ready(data_container, screen, theme, request_id)
            item["settlingMethod"] = "native-debug-readiness-marker" if ready else "bounded-delay-no-readiness-proof"
            item["nativeReady"] = bool(ready and ready.get("ready") is True)
            if ready:
                readiness_path = self.output / "readiness" / family / f"{screen}-{theme}.json"
                readiness_path.parent.mkdir(parents=True, exist_ok=True)
                readiness_path.write_text(json.dumps(ready, ensure_ascii=False, indent=2) + "\n")
                item["readinessReport"] = str(readiness_path.relative_to(self.output))
                item["runtimeErrors"] = ready.get("errors", [])
                item["metrics"] = ready.get("metrics", {})
            else:
                item["runtimeErrors"] = ["DEBUG preview marker did not arrive for this request within 24 seconds."]
            self.save_bootstrap(data_container, item)
            self.save_network(data_container, item, "after-readiness")
            if first and family == "iPhone":
                self.run_security_probe(udid)
                self.save_network(data_container, item, "after-probes")
            destination = self.output / "screenshots" / ("mobile" if family == "iPhone" else "tablet") / f"{screen}-{theme}.jpg"
            destination.parent.mkdir(parents=True, exist_ok=True)
            self.run(
                ["xcrun", "simctl", "io", udid, "screenshot", "--type=jpeg", str(destination)],
                f"capture-{family}-{screen}-{theme}", 25,
            )
            item.update(jpeg_info(destination))
            item.update({"status": "captured", "path": str(destination.relative_to(self.output)), "capturedAt": utc_now()})
            if first and not item.get("nativeReady"):
                diagnostic = self.output / "screenshots" / "diagnostic" / f"{family}-first-not-ready.jpg"
                diagnostic.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(destination, diagnostic)
                item["systemDiagnosticScreenshot"] = str(diagnostic.relative_to(self.output))
        except QAError as error:
            item.update({"status": "failed", "error": str(error)})
            self.report["errors"].append(str(error))
        finally:
            self.save_bootstrap(data_container, item)
            self.save_network(data_container, item, "final")
            item["elapsedSeconds"] = round(time.monotonic() - started, 2)

    def execute(self) -> int:
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.output / "logs").mkdir(exist_ok=True, mode=0o700)
        if sys.platform != "darwin":
            raise QAError("This script requires macOS with full Xcode; no simulator runs on this host.")
        project = self.repo / "ios" / "AVELI.xcodeproj"
        if not (project / "project.pbxproj").is_file():
            raise QAError("AVELI.xcodeproj was not found beneath --repo-root/ios.")
        self.report["xcodeVersion"] = self.run(["xcodebuild", "-version"], "xcode-version", 10)
        sdk_version = self.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], "simulator-sdk-version", 10)
        self.report["build"]["sdkVersion"] = sdk_version
        platform_path = Path(self.run(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-platform-path"], "selected-simulator-platform-path", 10))
        self.simulator_app = platform_path.parent.parent / "Applications" / "Simulator.app"
        self.report["simulatorGUI"] = {"appPath": str(self.simulator_app), "available": self.simulator_app.is_dir()}
        catalog = json.loads(self.run(["xcrun", "simctl", "list", "--json"], "simulator-catalog", 15))
        runtime = select_runtime(catalog, sdk_version)
        self.report["runtimeSelection"] = {
            "selectedRuntime": runtime["name"], "selectedRuntimeVersion": runtime["version"],
            "sdkCeiling": sdk_version, "reason": "Newest available iOS 17+ runtime at or below the selected Xcode simulator SDK major/minor.",
        }
        self.work = Path(tempfile.mkdtemp(prefix="aveli-private-simulator-qa-"))
        derived = self.work / "DerivedData"
        host_arch = platform.machine()
        if host_arch not in ("arm64", "x86_64"):
            raise QAError("Unsupported macOS simulator host architecture.")
        self.report["build"]["hostArchitecture"] = host_arch
        command = [
            "xcodebuild", "-project", str(project), "-scheme", "AVELI",
            "-configuration", "Debug", "-sdk", "iphonesimulator",
            "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", str(derived),
            "CODE_SIGNING_ALLOWED=NO", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_IDENTITY=",
            "ARCHS=" + host_arch, "ONLY_ACTIVE_ARCH=YES",
            "IPHONEOS_DEPLOYMENT_TARGET=17.0", "build",
        ]
        # First-boot migration competes with actool and Swift compilation on a
        # standard runner. Compile only its host architecture before booting.
        self.run(command, "xcode-debug-simulator-build", min(240, self.args.timeout - 30))
        app = derived / "Build" / "Products" / "Debug-iphonesimulator" / "AVELI.app"
        self.web_app = app / "WebApp"
        with (app / "Info.plist").open("rb") as handle:
            plist = plistlib.load(handle)
        if plist.get("CFBundleIdentifier") != EXPECTED_BUNDLE_ID or plist.get("DTPlatformName") != "iphonesimulator":
            raise QAError("Compiled product is not the expected AVELI iOS Simulator app.")
        self.report["build"].update({
            "compiled": True, "bundleIdentifier": EXPECTED_BUNDLE_ID,
            "minimumOSVersion": plist.get("MinimumOSVersion"),
            "version": plist.get("CFBundleShortVersionString"),
            "buildNumber": plist.get("CFBundleVersion"),
        })
        self.sign_simulator_app(app)
        mobile = self.make_device(catalog, runtime, "iPhone")
        self.capture_system_diagnostic(mobile, "iPhone")
        self.run(["xcrun", "simctl", "install", mobile, str(app)], "install-iPhone", 120)
        data = Path(self.run(["xcrun", "simctl", "get_app_container", mobile, EXPECTED_BUNDLE_ID, "data"], "container-iPhone", 30))
        for index, screen in enumerate(self.selected_screens):
            self.capture(mobile, data, screen, "dark", "iPhone", first=index == 0)
        if self.capture_light_settings:
            self.capture(mobile, data, "settings", "light", "iPhone")
        if self.args.include_ipad:
            if self.remaining() < 90:
                self.report["optionalTabletSkipped"] = "Less than 90 seconds remaining for optional tablet first boot and capture."
            else:
                # Both Simulator apps share macOS loopback. Release the fixed
                # localhost port before starting the optional tablet instance.
                self.run(["xcrun", "simctl", "terminate", mobile, EXPECTED_BUNDLE_ID], "release-iPhone-app-port", 10, required=False)
                self.run(["xcrun", "simctl", "shutdown", mobile], "shutdown-iPhone-before-iPad", 15)
                try:
                    tablet = self.make_device(catalog, runtime, "iPad")
                    self.capture_system_diagnostic(tablet, "iPad")
                    self.run(["xcrun", "simctl", "install", tablet, str(app)], "install-iPad", 120)
                    tablet_data = Path(self.run(["xcrun", "simctl", "get_app_container", tablet, EXPECTED_BUNDLE_ID, "data"], "container-iPad", 30))
                    self.capture(tablet, tablet_data, "inbox", "dark", "iPad", first=True)
                except QAError as error:
                    self.report["optionalTabletFailure"] = str(error)
        required = {(screen, "dark", "iPhone") for screen in self.selected_screens}
        if self.capture_light_settings:
            required.add(("settings", "light", "iPhone"))
        captured = {(item["screen"], item["theme"], item["family"]) for item in self.report["screenshots"] if item["status"] == "captured"}
        self.report["requiredCapturesComplete"] = required.issubset(captured)
        all_proven = all(item.get("nativeReady") is True for item in self.report["screenshots"] if item["status"] == "captured" and (item["screen"], item["theme"], item["family"]) in required)
        self.report["allCapturedScreensReadyByNativeHook"] = all_proven
        self.report["screensWithRuntimeErrors"] = [
            {"screen": item["screen"], "theme": item["theme"], "family": item["family"], "errors": item.get("runtimeErrors", [])}
            for item in self.report["screenshots"] if item.get("runtimeErrors") and (item["screen"], item["theme"], item["family"]) in required
        ]
        ready_complete = required.issubset(captured) and all_proven and not self.report["screensWithRuntimeErrors"]
        security_passed = self.report["security"]["status"] == "passed"
        self.report["status"] = "captured" if ready_complete and security_passed else "captured-with-security-errors" if ready_complete else "captured-with-readiness-errors" if required.issubset(captured) else "partial"
        return 0 if ready_complete and security_passed else 1

    def cleanup(self) -> None:
        # Only simulators created by this invocation are terminated or deleted.
        for udid in reversed(self.owned_devices):
            for action in ("shutdown", "delete"):
                try:
                    with tempfile.TemporaryFile() as output:
                        process = subprocess.Popen(["xcrun", "simctl", action, udid], stdout=output,
                                                   stderr=output, start_new_session=True)
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            try:
                                process.wait(timeout=1)
                            except subprocess.TimeoutExpired:
                                pass
                except OSError:
                    pass
        if self.work:
            shutil.rmtree(self.work, ignore_errors=True)

    def write_report(self) -> None:
        self.report["finishedAt"] = utc_now()
        self.report["elapsedSeconds"] = round(time.monotonic() - self.started, 2)
        self.report["capturedScreenshotCount"] = sum(item["status"] == "captured" for item in self.report["screenshots"])
        self.report["ownedSimulatorCleanupAttempted"] = bool(self.owned_devices)
        self.output.mkdir(parents=True, exist_ok=True, mode=0o700)
        (self.output / "native-design-qa-report.json").write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n")


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", required=True, help="Source root containing ios/AVELI.xcodeproj.")
    parser.add_argument("--output", required=True, help="Private output directory for screenshots, logs and JSON report.")
    parser.add_argument("--timeout", type=int, default=720, help="Total build/capture budget in seconds (default: 720 for cold runner migrations).")
    parser.add_argument("--include-ipad", action="store_true", help="Also capture iPad inbox if at least 90 seconds remain.")
    parser.add_argument("--screens", type=screen_list, default=SCREENS, help="Validated comma-separated screen subset; default captures all 17 plus light settings.")
    args = parser.parse_args(argv)
    if not 90 <= args.timeout <= 900:
        parser.error("--timeout must be between 90 and 900 seconds.")
    return args


def main(argv: list[str] | None = None) -> int:
    runner = Runner(parse_args(argv))
    code = 1
    try:
        code = runner.execute()
    except (QAError, OSError, ValueError, KeyError) as error:
        runner.report["status"] = "failed"
        runner.report["errors"].append(str(error))
    finally:
        runner.cleanup()
        runner.write_report()
    # Only small status metadata is emitted; compiler logs remain private.
    print(json.dumps({
        "status": runner.report["status"],
        "capturedScreenshotCount": runner.report["capturedScreenshotCount"],
        "report": str(runner.output / "native-design-qa-report.json"),
    }))
    return code


if __name__ == "__main__":
    raise SystemExit(main())
