#!/usr/bin/env python3
"""Tests for the notarization gate.

Two things are proven here:

1. `scripts/verify-notarization.py` REJECTS un-notarized and tampered
   artifacts. A checker that has only ever seen a passing input is not a
   checker. Every fixture is synthesized in a temp directory at test time --
   no binary is committed to this repository.

2. `scripts/build-universal-dmg.sh` cannot be talked out of notarizing on the
   release path. These are executed, not grepped: the script is actually run
   with hostile `NOTARIZE` values and its behaviour observed.

Run:  python3 scripts/tests/test_verify_notarization.py
"""

from __future__ import annotations

import hashlib
import importlib.util
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VERIFIER = REPO_ROOT / "scripts" / "verify-notarization.py"
BUILD_SCRIPT = REPO_ROOT / "scripts" / "build-universal-dmg.sh"


def _load_verifier():
    spec = importlib.util.spec_from_file_location("verify_notarization", VERIFIER)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {VERIFIER}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


vn = _load_verifier()


# --------------------------------------------------------------------------
# Fixture synthesis: build a minimal, structurally valid UDIF disk image with
# whatever code-signature superblob the test needs.
# --------------------------------------------------------------------------

APPLE_TICKET_CHAIN = (
    b"Apple System Integration CA 4"
    b"Software Ticket Signing"
    b"Apple Root CA - G3"
)


def make_code_directory(identifier: bytes = b"test-artifact", flags: int = 0x10000) -> bytes:
    """A CodeDirectory blob that is minimal but structurally parseable."""
    ident_offset = 44
    body = identifier + b"\x00"
    length = ident_offset + len(body)
    header = struct.pack(
        ">IIIIIIIIIBBBBI",
        vn.CSMAGIC_CODEDIRECTORY,
        length,
        0x20000,      # version
        flags,        # flags (0x10000 = CS_RUNTIME)
        0,            # hashOffset
        ident_offset, # identOffset
        0,            # nSpecialSlots
        0,            # nCodeSlots
        0,            # codeLimit
        32,           # hashSize
        2,            # hashType: 2 = SHA-256
        1,            # platform
        12,           # pageSize
        0,            # spare2
    )
    assert len(header) == ident_offset, len(header)
    return header + body


def cdhash_of(cd_blob: bytes) -> bytes:
    return hashlib.sha256(cd_blob).digest()[: vn.CS_CDHASH_LEN]


def make_ticket_payload(
    cdhash: bytes | None,
    magic: bytes = vn.TICKET_CONTAINER_MAGIC,
    chain: bytes = APPLE_TICKET_CHAIN,
) -> bytes:
    payload = magic + struct.pack("<I", 1) + b"\x00" * 8
    payload += chain
    payload += b"\xa5" * 32
    if cdhash is not None:
        payload += cdhash
    payload += b"\x5a" * 32
    return payload


def make_blob_wrapper(payload: bytes) -> bytes:
    return struct.pack(">II", vn.CSMAGIC_BLOBWRAPPER, 8 + len(payload)) + payload


def make_superblob(slots: list[tuple[int, bytes]]) -> bytes:
    count = len(slots)
    index_size = 12 + (count * 8)
    blobs = b""
    index = b""
    offset = index_size
    for slot_type, blob in slots:
        index += struct.pack(">II", slot_type, offset)
        blobs += blob
        offset += len(blob)
    total = index_size + len(blobs)
    header = struct.pack(">III", vn.CSMAGIC_EMBEDDED_SIGNATURE, total, count)
    return header + index + blobs


def make_koly(xml_offset: int, xml_length: int, data_fork_length: int) -> bytes:
    trailer = bytearray(vn.KOLY_SIZE)
    trailer[0:4] = vn.KOLY_MAGIC
    struct.pack_into(">I", trailer, 4, 4)             # version
    struct.pack_into(">I", trailer, 8, vn.KOLY_SIZE)  # headerSize
    struct.pack_into(">Q", trailer, 32, data_fork_length)
    struct.pack_into(">Q", trailer, 216, xml_offset)
    struct.pack_into(">Q", trailer, 224, xml_length)
    return bytes(trailer)


def make_dmg(signature: bytes, data_fork: bytes = b"\x11" * 2048) -> bytes:
    xml = b"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict/></plist>"
    xml_offset = len(data_fork)
    body = data_fork + xml + signature
    return body + make_koly(xml_offset, len(xml), len(data_fork))


def notarized_dmg() -> bytes:
    cd = make_code_directory()
    ticket = make_blob_wrapper(make_ticket_payload(cdhash_of(cd)))
    return make_dmg(
        make_superblob(
            [
                (vn.CSSLOT_CODEDIRECTORY, cd),
                (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                (vn.CSSLOT_TICKETSLOT, ticket),
            ]
        )
    )


# --------------------------------------------------------------------------


class VerifierTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="notarization-fixture-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)

    def write(self, name: str, blob: bytes) -> Path:
        path = self.tmp / name
        path.write_bytes(blob)
        return path

    def assert_rejected(self, path: Path, needle: str) -> None:
        """The CLI must exit non-zero and say why. Fail closed, always."""
        proc = subprocess.run(
            [sys.executable, str(VERIFIER), str(path)],
            capture_output=True,
            text=True,
        )
        self.assertNotEqual(proc.returncode, 0, f"checker PASSED a bad artifact: {path.name}")
        self.assertIn(needle, proc.stderr + proc.stdout)

    # -- the one input that must pass ------------------------------------

    def test_notarized_fixture_passes(self) -> None:
        path = self.write("notarized.dmg", notarized_dmg())
        proc = subprocess.run(
            [sys.executable, str(VERIFIER), str(path), "--json"],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("ticket_binding", proc.stdout)

    # -- the inputs that must fail ---------------------------------------

    def test_missing_ticket_slot_is_rejected(self) -> None:
        """A signed but NOT notarized artifact. This is the exact regression
        the CI gate exists to catch: NOTARIZE=0 produces this."""
        cd = make_code_directory()
        dmg = make_dmg(
            make_superblob(
                [
                    (vn.CSSLOT_CODEDIRECTORY, cd),
                    (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                ]
            )
        )
        self.assert_rejected(self.write("unnotarized.dmg", dmg), "CSSLOT_TICKETSLOT (0x10002) is absent")

    def test_empty_ticket_slot_is_rejected(self) -> None:
        cd = make_code_directory()
        dmg = make_dmg(
            make_superblob(
                [
                    (vn.CSSLOT_CODEDIRECTORY, cd),
                    (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                    (vn.CSSLOT_TICKETSLOT, make_blob_wrapper(b"")),
                ]
            )
        )
        self.assert_rejected(self.write("empty-ticket.dmg", dmg), "empty")

    def test_ticket_with_wrong_container_magic_is_rejected(self) -> None:
        cd = make_code_directory()
        ticket = make_blob_wrapper(make_ticket_payload(cdhash_of(cd), magic=b"XXXX"))
        dmg = make_dmg(
            make_superblob(
                [
                    (vn.CSSLOT_CODEDIRECTORY, cd),
                    (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                    (vn.CSSLOT_TICKETSLOT, ticket),
                ]
            )
        )
        self.assert_rejected(self.write("bad-magic.dmg", dmg), "s8ch")

    def test_ticket_not_issued_by_apple_is_rejected(self) -> None:
        cd = make_code_directory()
        ticket = make_blob_wrapper(
            make_ticket_payload(cdhash_of(cd), chain=b"Some Other Ticket Signing Authority")
        )
        dmg = make_dmg(
            make_superblob(
                [
                    (vn.CSSLOT_CODEDIRECTORY, cd),
                    (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                    (vn.CSSLOT_TICKETSLOT, ticket),
                ]
            )
        )
        self.assert_rejected(self.write("not-apple.dmg", dmg), "Software Ticket Signing")

    def test_ticket_for_a_different_build_is_rejected(self) -> None:
        """A real Apple ticket lifted from another build. The cdhash binding is
        what makes ticket-transplanting detectable."""
        cd = make_code_directory()
        other_cdhash = cdhash_of(make_code_directory(identifier=b"a-different-build"))
        self.assertNotEqual(other_cdhash, cdhash_of(cd))
        ticket = make_blob_wrapper(make_ticket_payload(other_cdhash))
        dmg = make_dmg(
            make_superblob(
                [
                    (vn.CSSLOT_CODEDIRECTORY, cd),
                    (vn.CSSLOT_SIGNATURESLOT, make_blob_wrapper(b"pretend-cms" * 8)),
                    (vn.CSSLOT_TICKETSLOT, ticket),
                ]
            )
        )
        self.assert_rejected(self.write("wrong-build.dmg", dmg), "does NOT appear inside the ticket")

    def test_unsigned_image_is_rejected(self) -> None:
        dmg = make_dmg(b"")
        self.assert_rejected(self.write("unsigned.dmg", dmg), "not signed")

    def test_image_without_cms_signature_is_rejected(self) -> None:
        cd = make_code_directory()
        ticket = make_blob_wrapper(make_ticket_payload(cdhash_of(cd)))
        dmg = make_dmg(
            make_superblob(
                [(vn.CSSLOT_CODEDIRECTORY, cd), (vn.CSSLOT_TICKETSLOT, ticket)]
            )
        )
        self.assert_rejected(self.write("no-cms.dmg", dmg), "CSSLOT_SIGNATURESLOT")

    def test_not_a_disk_image_is_rejected(self) -> None:
        self.assert_rejected(self.write("junk.dmg", b"\x7f" * 4096), "koly")

    def test_truncated_file_is_rejected(self) -> None:
        self.assert_rejected(self.write("tiny.dmg", b"koly"), "too small")

    def test_missing_file_cannot_pass(self) -> None:
        proc = subprocess.run(
            [sys.executable, str(VERIFIER), str(self.tmp / "does-not-exist.dmg")],
            capture_output=True,
            text=True,
        )
        self.assertEqual(proc.returncode, 2)
        self.assertIn("unknown is not notarized", proc.stderr)

    def test_truncated_notarized_image_is_rejected(self) -> None:
        """Truncation must not degrade into a pass."""
        blob = notarized_dmg()
        self.assert_rejected(self.write("cut.dmg", blob[: len(blob) // 2]), "FAIL")


class BuildScriptGateTestCase(unittest.TestCase):
    """The release path must not be able to skip notarization.

    These execute the real script. Signing configuration is deliberately
    cleared so the run stops at the signing check; no credential is read,
    supplied, printed, or required by these tests.
    """

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="build-script-gate-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        shutil.copytree(REPO_ROOT / "scripts", self.tmp / "scripts")
        for name in ("VERSION", "MIN_MACOS_VERSION"):
            shutil.copy2(REPO_ROOT / name, self.tmp / name)

    def run_build(self, **env_overrides: str) -> subprocess.CompletedProcess:
        bash = shutil.which("bash")
        self.assertIsNotNone(bash, "bash is required to test the build-script gate")
        env = dict(os.environ)
        for key in ("CI", "GITHUB_ACTIONS", "RELEASE_BUILD", "NOTARIZE"):
            env.pop(key, None)
        env.update(
            {
                # Never source a developer's real credential file during tests.
                "APPLE_DEVELOPER_FILE": str(self.tmp / "no-such-developer-file.txt"),
                "SIGN_IDENTITY": "",
                "APPLE_CERTIFICATE": "",
                "APPLE_CERTIFICATE_PASSWORD": "",
                "APPLE_ID": "",
                "APPLE_PASSWORD": "",
                "APPLE_TEAM_ID": "",
            }
        )
        env.update(env_overrides)
        return subprocess.run(
            [bash, str(self.tmp / "scripts" / "build-universal-dmg.sh")],
            capture_output=True,
            text=True,
            env=env,
            cwd=str(self.tmp),
        )

    def test_default_is_notarize_on(self) -> None:
        """With nothing set, the script must not be in a skip state."""
        proc = self.run_build()
        self.assertNotIn("NOTARIZATION DISABLED", proc.stdout + proc.stderr)
        self.assertIn("Missing signing configuration", proc.stderr)

    def test_unrecognised_notarize_value_is_a_hard_error(self) -> None:
        """`NOTARIZE=true` / `yes` / `on` used to skip notarization silently,
        because the gate compared against the literal string "1"."""
        for value in ("true", "yes", "on", "TRUE", "2", "00", " 1"):
            with self.subTest(value=value):
                proc = self.run_build(NOTARIZE=value)
                self.assertEqual(proc.returncode, 1, proc.stdout)
                self.assertIn("NOTARIZE_INVALID", proc.stderr)
                self.assertNotIn("NOTARIZATION DISABLED", proc.stdout + proc.stderr)

    def test_notarize_zero_is_refused_under_ci(self) -> None:
        for key in ("CI", "GITHUB_ACTIONS", "RELEASE_BUILD"):
            with self.subTest(env=key):
                proc = self.run_build(NOTARIZE="0", **{key: "1"})
                self.assertEqual(proc.returncode, 1, proc.stdout)
                self.assertIn("NOTARIZE_DISABLED_ON_RELEASE_PATH", proc.stderr)

    def test_notarize_zero_locally_is_loud_and_renames_the_artifact(self) -> None:
        """The local escape hatch survives, but what it produces is named so it
        can never be mistaken for -- or uploaded as -- a release asset."""
        proc = self.run_build(NOTARIZE="0")
        combined = proc.stdout + proc.stderr
        self.assertIn("NOTARIZATION DISABLED", combined)
        self.assertIn("UNNOTARIZED-DO-NOT-DISTRIBUTE", combined)
        # It still stops for the ordinary reason, not at the notarization gate.
        self.assertIn("Missing signing configuration", proc.stderr)


if __name__ == "__main__":
    unittest.main(verbosity=2)
