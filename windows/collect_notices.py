"""Install the license texts that come with the exact bundled packages."""

from importlib.metadata import distribution
from pathlib import Path
import re
import shutil
import sys


PACKAGES = (
    "Pillow", "pillow-heif", "py7zr", "pyzipper", "pycryptodomex", "Brotli", "psutil", "pyppmd", "pybcj",
    "multivolumefile", "inflate64", "backports.zstd", "texttable", "PyInstaller",
    "ctranslate2", "sentencepiece", "py3langid", "numpy", "PyYAML", "setuptools",
)


def main(directory: Path, inno: Path) -> None:
    directory.mkdir(parents=True, exist_ok=True)
    notices = ["搞操作 Windows 第三方组件", "", "以下软件包可从 PyPI 获取发行文件和对应源码。"]
    for name in PACKAGES:
        package = distribution(name)
        notices.append(f"{name} {package.version}  https://pypi.org/project/{name}/{package.version}/")
        target = directory / name
        target.mkdir(exist_ok=True)
        for file in package.files or []:
            if (".dist-info" not in str(file) or not re.match(r"(?:copying|licen[cs]e|notice)", file.name, re.I)
                    or file.name.endswith("~")):
                continue
            shutil.copyfile(package.locate_file(file), target / file.name)
    for name in ("LICENSE.txt", "LICENSE_PYTHON.txt", "LICENSE"):
        python_license = Path(sys.base_prefix) / name
        if python_license.is_file():
            shutil.copyfile(python_license, directory / "Python.txt")
            break
    notices.extend(["", f"Python {sys.version.split()[0]}  https://www.python.org/downloads/source/",
                    "Tcl/Tk  https://www.tcl-lang.org/software/tcltk/",
                    "Inno Setup  https://github.com/jrsoftware/issrc/releases", "",
                    "如需更换随包分发的组件，可从搞操作源码的 windows 目录修改依赖列表，并重新执行 build.ps1。"])
    for name in ("license.txt", "LICENSE.txt", "README.TXT"):
        inno_notice = inno / name
        if inno_notice.is_file():
            shutil.copyfile(inno_notice, directory / "InnoSetup.txt")
            break
    vendor = Path(__file__).resolve().parent / "src" / "gaocaozuo" / "assets" / "vendor"
    for notice in vendor.glob("*.txt"):
        shutil.copyfile(notice, directory / notice.name)
    shutil.copytree(Path(__file__).resolve().parent / "licenses" / "translation", directory / "Translation", dirs_exist_ok=True)
    (directory / "Third-Party.txt").write_text("\n".join(notices) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main(Path(sys.argv[1]), Path(sys.argv[2]))
