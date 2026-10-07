#!/usr/bin/env python3
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Verify interrupted native file staging preserves the published outbox."""

import os
import shutil
import subprocess
import tempfile
import time
from pathlib import Path

HARNESS = r"""
import Foundation
import Darwin

@main struct Probe {
  static func main() async {
    do {
      let store = AttachmentStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
      if CommandLine.arguments[1] == "stage" {
        _ = try await store.stage(source: URL(fileURLWithPath: CommandLine.arguments[3]),
          name: "Fixture.bin", contentType: "application/octet-stream")
      } else {
        let entries = try await store.entries()
        guard entries.count == 1,
          try await store.localBytes(for: entries[0].id) == Data([1, 2, 3])
        else { exit(3) }
        print("Published attachment survived interrupted staging")
      }
    } catch {
      print(error)
      exit(2)
    }
  }
}
"""


def main():
    source = (
        Path(__file__).resolve().parents[1]
        / "packages/LifeKit/Sources/LifeKit/AttachmentStore.swift"
    )
    with tempfile.TemporaryDirectory(prefix="life-ui-attachment-staging-") as temporary:
        root = Path(temporary)
        harness, binary = root / "Probe.swift", root / "probe"
        harness.write_text(HARNESS)
        subprocess.run(
            [
                "swiftc",
                "-parse-as-library",
                str(source),
                str(harness),
                "-o",
                str(binary),
            ],
            check=True,
        )
        original, outbox, stream = root / "original", root / "outbox", root / "stream"
        original.write_bytes(bytes([1, 2, 3]))
        subprocess.run([str(binary), "stage", str(outbox), str(original)], check=True)
        os.mkfifo(stream)
        writer = os.open(stream, os.O_RDWR | os.O_NONBLOCK)
        child = subprocess.Popen([str(binary), "stage", str(outbox), str(stream)])
        staged_directory = None
        try:
            deadline = time.monotonic() + 10
            while child.poll() is None and time.monotonic() < deadline:
                handles = subprocess.run(
                    ["lsof", "-a", "-p", str(child.pid), "-Fn"],
                    capture_output=True,
                    text=True,
                    check=False,
                ).stdout.splitlines()
                paths = [Path(line[1:]) for line in handles if line.startswith("n")]
                copies = [path.parent for path in paths if path.name == "bytes"]
                if (
                    stream.resolve() in [path.resolve() for path in paths]
                    and len(copies) == 1
                ):
                    staged_directory = copies[0]
                    assert staged_directory.resolve().is_relative_to(
                        root.parent.resolve()
                    )
                    break
                time.sleep(0.01)
            assert child.poll() is None and staged_directory is not None, (
                "Staging was not held"
            )
            child.terminate()
            child.wait(timeout=5)
            subprocess.run([str(binary), "read", str(outbox)], check=True)
        finally:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            os.close(writer)
            if staged_directory is not None and staged_directory.exists():
                shutil.rmtree(staged_directory)


if __name__ == "__main__":
    main()
