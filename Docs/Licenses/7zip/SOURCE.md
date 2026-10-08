# 7-Zip 26.04 redistribution record

GaoCaoZuo invokes the unmodified official `7zz` executable as a separate process. It does not link 7-Zip code into the application.

- Upstream: https://github.com/ip7z/7zip and https://www.7-zip.org/
- Version: 26.04, published 2026-10-05
- macOS universal binary archive: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-mac.tar.xz
- Official binary archive SHA-256: `bee04358cbcbc7106273cee0e8d72916db2696c48067a3538c34d8cd6fd16578`
- Exact corresponding source: https://github.com/ip7z/7zip/releases/download/26.04/7z2604-src.tar.xz
- Official source archive SHA-256: `9691944c0fe0d01bb49373a704fb983fd33bc98b1738695179dfbf99ac1734f6`
- Both digests were verified after download against the official GitHub release asset metadata.

The full corresponding source archive is included beside this notice as `7z2604-src.tar.xz`. The upstream distribution license is reproduced in `License.txt`, and the GNU LGPL 2.1 text in `LGPL-2.1.txt`. The unRAR restriction and BSD notices are included in `License.txt`. The official build instructions and source license files are inside the source archive. RAR creation is not offered by GaoCaoZuo.

The application packaging step may apply a local code signature to the executable; it does not modify the upstream source or program behavior. Distribute this entire directory with the application and source repository. The separate 7-Zip executable can be replaced by a compatible upstream build; no application license restricts the rights granted by 7-Zip's licenses.
