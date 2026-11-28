"""Compile the production Quick Look extension with an isolated test main."""

from pathlib import Path
import shutil
import subprocess


def compile_quicklook_harness(project: Path, root: Path, runner: Path, executable: Path) -> None:
    extension = root / "QuickLookExtension"
    shutil.copytree(project / "QuickLookExtension", extension)
    shared = root / "Shared"
    shared.mkdir()
    # Match the Quick Look Swift sources and frameworks used by Scripts/build.sh.
    for name in ("GaoLocalization.swift", "QuickLookArchiveEditProtocol.swift", "QuickLookArchiveBroker.swift"):
        shutil.copyfile(project / "Shared" / name, shared / name)
    sources = sorted(extension.glob("*.swift")) + sorted(shared.glob("*.swift"))
    subprocess.run([
        "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox", "-O",
        "-application-extension", "-target", "arm64-apple-macos14.0",
        "-module-cache-path", str(root / "cache"), *map(str, sources), str(runner),
        "-framework", "AppKit", "-framework", "QuickLookUI", "-framework", "PDFKit",
        "-framework", "ImageIO", "-framework", "CryptoKit", "-framework", "Security",
        "-o", str(executable),
    ], check=True, timeout=180)
