# pack/LICENSE: photon's licence verbatim, then the third-party notice its atmosphere code carries
import sys

photon = open(sys.argv[1], encoding='utf-8').read().rstrip() + '\n'
bruneton = """
--------------------------------------------------------------------------------
This port is a derivative work of Photon Shaders, distributed under the licence
above. It contains no code of Horizon's; it runs on Horizon's shader API.

The atmosphere mapping functions in common.wgsl come from Eric Bruneton's
precomputed atmospheric scattering, under this licence:

Copyright (c) 2017 Eric Bruneton
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
this list of conditions and the following disclaimer in the documentation
and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
may be used to endorse or promote products derived from this software without
specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

The textures/scattering.png, textures/worley.png, textures/noise.png and
textures/galaxy.png files are Photon's own images re-encoded for Horizon. The
galaxy image is from NASA's Scientific Visualization Studio
(https://svs.gsfc.nasa.gov/4851); the blue noise is from momentsingraphics.de.
"""
open(sys.argv[2], 'w', encoding='utf-8', newline='\n').write(photon + bruneton)
