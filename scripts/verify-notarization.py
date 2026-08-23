#!/usr/bin/env python3
"""Verify that a distributed macOS artifact carries a stapled Apple notarization ticket.

This inspects the ARTIFACT ITSELF. It does not read build configuration and it
does not trust any claim made by the build script. It answers exactly one
question, from the bytes that users receive:

    Does this .dmg carry an Apple-issued notarization ticket that is bound to
    this .dmg's own code-directory hash?

Design rule: FAIL CLOSED. Anything this program cannot positively prove is a
failure. `unknown` is never `notarized`.

What it proves
--------------
* The file is a UDIF disk image with an embedded code-signature superblob.
* The superblob carries CSSLOT_SIGNATURESLOT (0x10000) -- the artifact is signed.
* The superblob carries CSSLOT_TICKETSLOT (0x10002) -- a ticket was stapled.
  Only `xcrun stapler staple` writes that slot, and it can only obtain a ticket
  from Apple's notary service after a submission is Accepted.
* The ticket payload carries Apple's stapled-ticket container magic `s8ch`.
* The ticket carries Apple's ticket-signing certificate chain.
* The artifact's OWN cdhash appears inside the ticket, so the ticket certifies
  this build and not some other one.

What it does NOT prove
----------------------
* It does not cryptographically validate Apple's CMS signature over the ticket
  against a pinned Apple root. It checks the chain's identifying subject
  strings. Use `xcrun stapler validate` on a macOS host for that.
* It does not detect revocation of the ticket or of the Developer ID
  certificate. Only a live Gatekeeper assessment (`spctl --assess`) can.
* It says nothing about the app bundle inside the image beyond the image-level
  signature; the image-level ticket is what Gatekeeper consults for a .dmg.

Usage
-----
    verify-notarization.py <artifact.dmg> [--json]

Exit codes: 0 = verified, 1 = verification failed, 2 = could not run the check.
Both 1 and 2 are failures. There is no "skip".
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from pathlib import Path

# Code-signing constants (cs_blobs.h).
CSMAGIC_EMBEDDED_SIGNATURE = 0xFADE0CC0
CSMAGIC_CODEDIRECTORY = 0xFADE0C02
CSMAGIC_BLOBWRAPPER = 0xFADE0B01

CSSLOT_CODEDIRECTORY = 0x00000
CSSLOT_SIGNATURESLOT = 0x10000
CSSLOT_TICKETSLOT = 0x10002
CSSLOT_ALTERNATE_CODEDIRECTORIES = range(0x1000, 0x1005)

CS_RUNTIME = 0x10000  # hardened runtime
CS_CDHASH_LEN = 20    # Apple truncates the cdhash to 20 bytes everywhere

# Digest used by a CodeDirectory, keyed by its hashType field.
HASH_TYPES = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384", 5: "sha512"}

KOLY_MAGIC = b"koly"
KOLY_SIZE = 512

TICKET_CONTAINER_MAGIC = b"s8ch"

# Apple's notarization ticket-signing chain. The leaf CN is the load-bearing
# one: only Apple holds that key. The root markers are checked as a set so an
# Apple CA rotation does not silently weaken the check to nothing.
TICKET_LEAF_MARKER = b"Software Ticket Signing"
TICKET_ROOT_MARKERS = (b"Apple Root CA", b"Apple Certification Authority")


class VerificationError(Exception):
    """A check proved the artifact is not verifiably notarized."""


class UnrunnableError(Exception):
    """The check could not be run at all. Treated as a failure, never a pass."""


def _u32be(buf: bytes, off: int) -> int:
    return struct.unpack_from(">I", buf, off)[0]


def _u64be(buf: bytes, off: int) -> int:
    return struct.unpack_from(">Q", buf, off)[0]


def find_signature_region(data: bytes) -> tuple[int, int]:
    """Return (offset, length) of the embedded code-signature superblob."""
    if len(data) < KOLY_SIZE:
        raise UnrunnableError(
            f"file is {len(data)} bytes, too small to contain a UDIF trailer"
        )

    trailer = data[-KOLY_SIZE:]
    if trailer[:4] != KOLY_MAGIC:
        raise VerificationError(
            "no UDIF 'koly' trailer at end of file -- not a disk image this "
            "checker can account for"
        )

    xml_offset = _u64be(trailer, 216)
    xml_length = _u64be(trailer, 224)
    start = xml_offset + xml_length
    end = len(data) - KOLY_SIZE

    if 0 < start < end and _u32be(data, start) == CSMAGIC_EMBEDDED_SIGNATURE:
        return start, end - start

    # Fallback: some images pad between the plist and the signature.
    marker = struct.pack(">I", CSMAGIC_EMBEDDED_SIGNATURE)
    found = data.rfind(marker, 0, end)
    if found != -1 and found >= xml_offset:
        return found, end - found

    raise VerificationError(
        "no embedded code-signature superblob found between the XML plist and "
        "the UDIF trailer -- the artifact is not signed"
    )


def parse_superblob(data: bytes, start: int, region_len: int) -> dict[int, bytes]:
    """Return {slot_type: raw blob bytes} for every slot in the superblob."""
    if _u32be(data, start) != CSMAGIC_EMBEDDED_SIGNATURE:
        raise VerificationError("code-signature region does not begin with 0xfade0cc0")

    length = _u32be(data, start + 4)
    count = _u32be(data, start + 8)
    if length > region_len:
        raise VerificationError(
            f"superblob claims {length} bytes but only {region_len} are present"
        )
    if count == 0 or count > 64:
        raise VerificationError(f"implausible superblob slot count: {count}")

    slots: dict[int, bytes] = {}
    for i in range(count):
        idx = start + 12 + (i * 8)
        slot_type = _u32be(data, idx)
        slot_off = _u32be(data, idx + 4)
        blob_at = start + slot_off
        if not (start <= blob_at <= start + length - 8):
            raise VerificationError(f"slot 0x{slot_type:x} points outside the superblob")
        blob_len = _u32be(data, blob_at + 4)
        if blob_len < 8 or blob_at + blob_len > start + length:
            raise VerificationError(f"slot 0x{slot_type:x} has an out-of-range length")
        slots[slot_type] = data[blob_at:blob_at + blob_len]
    return slots


def code_directory_hashes(slots: dict[int, bytes]) -> list[dict]:
    """Compute the cdhash of every CodeDirectory in the superblob."""
    results = []
    wanted = [CSSLOT_CODEDIRECTORY, *CSSLOT_ALTERNATE_CODEDIRECTORIES]
    for slot_type in wanted:
        blob = slots.get(slot_type)
        if not blob:
            continue
        if _u32be(blob, 0) != CSMAGIC_CODEDIRECTORY:
            raise VerificationError(
                f"slot 0x{slot_type:x} is not a CodeDirectory (magic mismatch)"
            )
        if len(blob) < 44:
            raise VerificationError(f"CodeDirectory in slot 0x{slot_type:x} is truncated")

        flags = _u32be(blob, 12)
        ident_offset = _u32be(blob, 20)
        hash_type = blob[37]
        algo = HASH_TYPES.get(hash_type)
        if algo is None:
            raise VerificationError(f"unsupported CodeDirectory hashType {hash_type}")

        identifier = ""
        if 0 < ident_offset < len(blob):
            end = blob.find(b"\x00", ident_offset)
            identifier = blob[ident_offset:end if end != -1 else len(blob)].decode(
                "utf-8", "replace"
            )

        digest = hashlib.new(algo, blob).digest()
        results.append(
            {
                "slot": f"0x{slot_type:x}",
                "identifier": identifier,
                "hash_type": hash_type,
                "hash_algorithm": algo,
                "flags": f"0x{flags:x}",
                "hardened_runtime": bool(flags & CS_RUNTIME),
                "cdhash": digest[:CS_CDHASH_LEN].hex(),
                "_cdhash_bytes": digest[:CS_CDHASH_LEN],
            }
        )

    if not results:
        raise VerificationError("no CodeDirectory present -- the artifact is not signed")
    return results


def ticket_payload(slots: dict[int, bytes]) -> bytes:
    blob = slots.get(CSSLOT_TICKETSLOT)
    if blob is None:
        raise VerificationError(
            "CSSLOT_TICKETSLOT (0x10002) is absent -- NO STAPLED NOTARIZATION "
            "TICKET. This artifact must not be published."
        )
    magic = _u32be(blob, 0)
    if magic != CSMAGIC_BLOBWRAPPER:
        raise VerificationError(
            f"ticket slot has magic 0x{magic:08x}, expected a BlobWrapper 0xfade0b01"
        )
    payload = blob[8:]
    if not payload:
        raise VerificationError("ticket slot is present but empty")
    return payload


def verify(path: Path) -> dict:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise UnrunnableError(f"cannot read {path}: {exc}") from exc

    report: dict = {
        "artifact": str(path),
        "size_bytes": len(data),
        "sha256": hashlib.sha256(data).hexdigest(),
        "checks": [],
    }

    def record(name: str, ok: bool, detail: str) -> None:
        report["checks"].append({"check": name, "ok": ok, "detail": detail})

    sig_off, sig_len = find_signature_region(data)
    record("signature_region", True, f"superblob at offset {sig_off}, {sig_len} bytes")

    slots = parse_superblob(data, sig_off, sig_len)
    record(
        "superblob_slots",
        True,
        "slots: " + ", ".join(f"0x{s:x}" for s in sorted(slots)),
    )

    if CSSLOT_SIGNATURESLOT not in slots:
        raise VerificationError(
            "CSSLOT_SIGNATURESLOT (0x10000) is absent -- the artifact carries no "
            "CMS signature"
        )
    record(
        "code_signature",
        True,
        f"CMS signature present ({len(slots[CSSLOT_SIGNATURESLOT])} bytes)",
    )

    directories = code_directory_hashes(slots)
    report["code_directories"] = [
        {k: v for k, v in d.items() if not k.startswith("_")} for d in directories
    ]
    record(
        "code_directory",
        True,
        "cdhash " + ", ".join(d["cdhash"] for d in directories),
    )

    payload = ticket_payload(slots)
    report["ticket_bytes"] = len(payload)
    record("ticket_slot", True, f"CSSLOT_TICKETSLOT present ({len(payload)} bytes)")

    if not payload.startswith(TICKET_CONTAINER_MAGIC):
        raise VerificationError(
            "ticket payload does not begin with Apple's 's8ch' container magic "
            f"(saw {payload[:4]!r}) -- this is not an Apple notarization ticket"
        )
    record("ticket_magic", True, "Apple stapled-ticket container magic 's8ch'")

    if TICKET_LEAF_MARKER not in payload:
        raise VerificationError(
            "ticket does not carry Apple's 'Software Ticket Signing' certificate "
            "-- it was not issued by Apple's notary service"
        )
    if not any(marker in payload for marker in TICKET_ROOT_MARKERS):
        raise VerificationError(
            "ticket does not carry an Apple certificate-authority chain marker"
        )
    record(
        "ticket_issuer",
        True,
        "Apple 'Software Ticket Signing' chain present in the ticket",
    )

    bound = [d for d in directories if d["_cdhash_bytes"] in payload]
    if not bound:
        raise VerificationError(
            "the artifact's own cdhash ("
            + ", ".join(d["cdhash"] for d in directories)
            + ") does NOT appear inside the ticket -- the ticket does not "
            "certify this build"
        )
    report["bound_cdhash"] = [d["cdhash"] for d in bound]
    record(
        "ticket_binding",
        True,
        "cdhash " + ", ".join(d["cdhash"] for d in bound) + " found inside the ticket",
    )

    report["hardened_runtime"] = any(d["hardened_runtime"] for d in directories)
    report["verified"] = True
    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Prove a macOS artifact carries a stapled Apple notarization ticket."
    )
    parser.add_argument("artifact", type=Path, help="path to the .dmg to verify")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    args = parser.parse_args(argv)

    try:
        report = verify(args.artifact)
    except VerificationError as exc:
        print(f"NOT_NOTARIZED: {exc}", file=sys.stderr)
        print("FAIL: artifact is not verifiably notarized.", file=sys.stderr)
        return 1
    except UnrunnableError as exc:
        print(f"CHECK_COULD_NOT_RUN: {exc}", file=sys.stderr)
        print("FAIL: unknown is not notarized.", file=sys.stderr)
        return 2
    except Exception as exc:  # noqa: BLE001 - fail closed on anything unexpected
        print(f"CHECK_COULD_NOT_RUN: unexpected {type(exc).__name__}: {exc}", file=sys.stderr)
        print("FAIL: unknown is not notarized.", file=sys.stderr)
        return 2

    if args.json:
        print(json.dumps(report, indent=2))
    else:
        print(f"artifact : {report['artifact']}")
        print(f"size     : {report['size_bytes']} bytes")
        print(f"sha256   : {report['sha256']}")
        for check in report["checks"]:
            print(f"  [ok] {check['check']}: {check['detail']}")
        print("NOTARIZED: stapled Apple ticket bound to this artifact's cdhash.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
