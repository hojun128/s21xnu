# Patches taken from PixOS (pixelios-kernel)

The patches named `01xx-pixos-*.patch` are unchanged copies of patches from
https://github.com/PixOS-Project/pixelios-kernel (`xnu/patches/`), which share
this tree's sweet base (0025/0035/0036/0050 are byte-identical). Patch 0135
re-implements the idea of their 0123 (publish IORTC) for this tree.
Patch 0137 (frame pacing) re-implements ideas of their 0101 (vsync period),
0149 (absolute vsync deadlines) and 0343 (present gate) for this tree's
SweetMetal fences; patch 0138 re-implements their 0270/0344 (recommended cores).

| here | PixOS original |
|------|----------------|
| 0129-pixos-sweet-sandbox-container-path-appex | 0085 |
| 0130-pixos-sweet-amfi-dyld-policy | 0106 |
| 0131-pixos-sweet-sandbox-extension-ops | 0119 |
| 0132-pixos-sweet-sandbox-priv-net | 0126 |
| 0133-pixos-sweet-sandbox-skywalk-entitlements | 0291 |
| 0134-pixos-sweet-sandbox-selfcheck | 0329 |

MIT License

Copyright (c) 2026 PixOS-Project contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
