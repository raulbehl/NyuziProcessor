// 
// Copyright (C) 2011-2014 Jeff Bush
// 
// This program is free software; you can redistribute it and/or
// modify it under the terms of the GNU General Public License
// as published by the Free Software Foundation; either version 2
// of the License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, write to the Free Software
// Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
//  

#pragma once

#include <VertexShader.h>
#include <PixelShader.h>

using namespace librender;

class ColorVertexShader : public librender::VertexShader
{
public:
	ColorVertexShader()
		:	VertexShader(7, 8)
	{
	}

	void shadeVertices(vecf16_t *outParams, const vecf16_t *inAttribs, const void *,
        int) const override
	{
		// Position
		outParams[kParamX] = inAttribs[0];
		outParams[kParamY] = inAttribs[1];
		outParams[kParamZ] = inAttribs[2];
		outParams[kParamW] = splatf(1.0);

		// Color
		outParams[4] = inAttribs[3];
		outParams[5] = inAttribs[4];
		outParams[6] = inAttribs[5];
		outParams[7] = inAttribs[6];
	}
};

class ColorPixelShader : public librender::PixelShader
{
public:
	void shadePixels(const vecf16_t inParams[16], vecf16_t outColor[4],
		const void *, const Texture * const [kMaxTextures],
		unsigned short) const override
	{
		outColor[0] = inParams[0] * inParams[3];
		outColor[1] = inParams[1] * inParams[3];
		outColor[2] = inParams[2] * inParams[3];
		outColor[3] = inParams[3];
	}
};
