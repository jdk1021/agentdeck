# Third-party notices

AgentDeck's own Swift, Python and documentation sources are under the MIT License in `LICENSE`.
The release archives also contain the components below. Their full license texts ship in
`AgentDeck.app/Contents/Resources/Licenses/`.

## Upstream collectors (MIT)

- Source: GitHub repository ID `994093166` (<https://api.github.com/repositories/994093166>),
  tag `v4.5.0`, commit `ac2690cd7be4f47e4a255f5e2e78d904d436b068`.
- Used: the 23 usage collectors, their shared module, fixtures and reference account scripts under
  `Vendor/Upstream`. Per-file SHA-256 digests of the original bytes are in `docs/upstream-inventory.json`.
- Changes: product and command names were mechanically renamed, and the macOS adaptations listed in
  `docs/upstream-analysis.md` are applied as named patches by `scripts/prepare-runtime.py`.
- License: `Vendor/Upstream/LICENSE`, reproduced here:

```
Copyright (c) David Heinemeier Hansson

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
```

## CPython 3.14.10 (PSF License Agreement and bundled-library licenses)

- Distribution: python-build-standalone release `20261110`, `install_only_stripped` build for
  `aarch64-apple-darwin`. URLs and pinned SHA-256 digests: `scripts/dependencies.json`.
- License: the Python Software Foundation License Version 2 and the licenses of the libraries
  CPython incorporates (OpenSSL, SQLite, zlib, libffi, expat, mpdecimal, xz, bzip2, zstd and others) are in
  `Licenses/PYTHON-LICENSE.txt` (the distribution's own `lib/python3.14/LICENSE.txt`).
- The app removes unused parts (`idlelib`, `tkinter`, `turtledemo`, `ensurepip`, headers) from the bundle.

## ripgrep 15.2.0 (MIT or Unlicense)

- Distribution: official release archive for `aarch64-apple-darwin`,
  pinned in `scripts/dependencies.json`.
- License: dual MIT / Unlicense; texts in `Licenses/RIPGREP-LICENSE-MIT`, `Licenses/RIPGREP-UNLICENSE`
  and `Licenses/RIPGREP-COPYING`.

## Provider icons

- 20 provider icons in `Resources/ProviderIcons` come from LobeHub Icons
  (`@lobehub/icons-static-png` 2.6.0, <https://github.com/lobehub/lobe-icons>), MIT License,
  Copyright (c) 2023 LobeHub. The license text is `Resources/ProviderIcons/LICENSE-lobe-icons.txt`.
- The Kimchi and Synthetic icons are the favicons published on their official sites (kimchi.dev,
  synthetic.new).
- All product names, logos and brands are property of their respective owners. They are used only to
  identify the service each collector reads; AgentDeck is not affiliated with or endorsed by them.
- The AgentDeck app icon and menu bar glyph are original artwork (`scripts/make-icon.swift`).

## Not distributed

No agent CLI (Claude Code, Codex, Grok or others) is bundled or installed; AgentDeck uses the copies
already installed on the Mac. The Bash 4+ interpreter used only to run upstream fixtures in development
and CI is not part of any release archive.
