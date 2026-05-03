# Third-Party Notices

This repository is licensed under the MIT License, as described in `LICENSE`.
The following notices apply to third-party materials referenced by the source
tree, used by tests, or included in binary release packages.

## LZMA SDK

The implementation is aligned with the public LZMA SDK 26.01 behavior and uses
the LZMA SDK as compatibility and test reference material.

- Project: LZMA SDK
- Author: Igor Pavlov
- Website: https://www.7-zip.org/sdk.html
- License: public domain

The LZMA SDK website states that the LZMA SDK is placed in the public domain.

## Skia Runtime for the GUI

The Win64 binary release includes `sk4d.dll` next to `Lzma2_GUI.exe` so the GUI
can run on systems that do not already have the Skia runtime available.

The `sk4d.dll` file is redistributed unmodified from the RAD Studio / Delphi
13.1 Win64 redistributable runtime folder. It is not covered by this
repository's MIT License. Redistribution and use of that runtime file are
governed by the RAD Studio license terms that apply to redistributables and by
the applicable third-party notices for the components it contains.

Related upstream projects:

- Skia4Delphi: https://github.com/skia4delphi/skia4delphi
- Google Skia: https://skia.org/

Skia4Delphi is published under the MIT License. Google Skia is published under
the BSD-3-Clause License.

## External QA Tools

The test and benchmark scripts can download or use external tools listed in
`tests/qa-tools.json`, including 7-Zip/LZMA SDK and xz-utils tools. Those tools
are used only for tests, fixtures, CI, and benchmarks; they are not runtime
dependencies of the library.
