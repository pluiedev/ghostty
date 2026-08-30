//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//

struct Uniforms {
    float4x4 projection_matrix;
    float2   screen_size;
    float2   cell_size;
    uint     grid_size_packed_2u16;
    float4   grid_padding;
    PaddingExtend padding_extend;
    float    min_contrast;
    uint     cursor_pos_packed_2u16;
    uint     cursor_color_packed_4u8;
    uint     bg_color_packed_4u8;
    BoolFlags bools;
};

[[vk::binding(0, 0)]] Sampler2D           imageTexture;
[[vk::binding(1, 0)]] ConstantBuffer<Uniforms> uniforms;
[[vk::binding(2, 0)]] StructuredBuffer<uint> bg_cells;
[[vk::binding(3, 0)]] Sampler2D           atlasGrayscale;
[[vk::binding(4, 0)]] Sampler2D           atlasColor;

//----------------------------------------------------------------------------//
// Constants / Enums
//----------------------------------------------------------------------------//

// Bools
[Flags]
enum BoolFlags : uint {
    None = 0,
    CursorWide,
    UseDisplayP3,
    UseLinearBlending,
    UseLinearCorrection,
};

// Padding extend enum
[Flags]
enum PaddingExtend : uint {
    None = 0,
    Left,
    Right,
    Up,
    Down,
};

// Values `atlas` can take.
enum CellTextAtlas : uint {
    Grayscale = 0u,
    Color     = 1u,
};

// Masks for the `glyph_bools` attribute
[Flags]
enum GlyphBools : uint {
    None = 0,
    NoMinContrast,
    IsCursorGlyph,
};

// 4 bits of info.
enum BgImagePosition : uint {
    TopLeft      = 0u,
    TopCenter    = 1u,
    TopRight     = 2u,
    MiddleLeft   = 3u,
    MiddleCenter = 4u,
    MiddleRight  = 5u,
    BottomLeft   = 6u,
    BottomCenter = 7u,
    BottomRight  = 8u,
}

// 2 bits of info shifted 4.
enum BgImageFit : uint {
    Contain = 0u << 4,
    Cover   = 1u << 4,
    Stretch = 2u << 4,
    None    = 3u << 4,
}

// 1 bit of info shifted 6.
static const uint BG_IMAGE_POSITION_MASK = 15u;
static const uint BG_IMAGE_FIT_MASK      = 3u << 4;
static const uint BG_IMAGE_REPEAT        = 1u << 6;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.
//       If this ever becomes a problem... oh dear!

uint4 unpack4u8(uint packed_value) {
    return uint4(
        uint(packed_value >> 0) & uint(0xFF),
        uint(packed_value >> 8) & uint(0xFF),
        uint(packed_value >> 16) & uint(0xFF),
        uint(packed_value >> 24) & uint(0xFF)
    );
}

uint2 unpack2u16(uint packed_value) {
    return uint2(
        uint(packed_value >> 0) & uint(0xFFFF),
        uint(packed_value >> 16) & uint(0xFFFF)
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// D50-adapted sRGB to XYZ conversion matrix.
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
static const float3x3 sRGB_XYZ = transpose(float3x3(
    0.4360747, 0.3850649, 0.1430804,
    0.2225045, 0.7168786, 0.0606169,
    0.0139322, 0.0971045, 0.7141733
));

// XYZ to Display P3 conversion matrix.
// http://endavid.com/index.php?entry=79
static const float3x3 XYZ_DP3 = transpose(float3x3(
     2.40414768, -0.99010704, -0.39759019,
    -0.84239098,  1.79905954,  0.01597023,
     0.04838763, -0.09752546,  1.27393636
));

// By composing the two above matrices we get
// our sRGB to Display P3 conversion matrix.
static const float3x3 sRGB_DP3 = mul(XYZ_DP3, sRGB_XYZ);

// Converts a color in linear sRGB to linear Display P3
//
// TODO: The color matrix should probably be computed
//       dynamically and passed as a uniform, rather
//       than being hard coded above.
float3 srgb_to_display_p3(float3 srgb) {
    return mul(sRGB_DP3, srgb);
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
    bool3 cutoff = srgb.rgb <= 0.04045;
    float3 lower = srgb.rgb / 12.92;
    float3 higher = pow((srgb.rgb + 0.055) / 1.055, float3(2.4, 2.4, 2.4));
    srgb.rgb = lerp(higher, lower, float3(cutoff));
    return srgb;
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear) {
    bool3 cutoff = linear.rgb <= 0.0031308;
    float3 lower = linear.rgb * 12.92;
    float3 higher = pow(linear.rgb, float3(1.0 / 2.4, 1.0 / 2.4, 1.0 / 2.4)) * 1.055 - 0.055;
    linear.rgb = lerp(higher, lower, float3(cutoff));
    return linear;
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(float3 color) {
    return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(float3 color1, float3 color2) {
    float l1 = luminance(color1);
    float l2 = luminance(color2);
    return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float4 contrasted_color(float min_ratio, float4 fg, float4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(float3(1.0f), bg.rgb);
        float black_ratio = contrast_ratio(float3(0.0f), bg.rgb);
        if (white_ratio > black_ratio) {
            return float4(1.0f);
        } else {
            return float4(0.0f, 0.0f, 0.0f, 1.0f);
        }
    }

    return fg;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// Returns a color in the Display P3 color space.
//
// If `display_p3` is true, then the provided color is assumed to
// already be in the Display P3 color space, otherwise it's treated
// as an sRGB color and is appropriately converted to Display P3.
//
// `linear` controls whether the returned color is linear or gamma encoded.
float4 load_color(
    uint4 in_color,
    bool display_p3,
    bool linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    float4 color = float4(in_color) / 255.0f;

    // If our color is already in Display P3 and
    // we aren't doing linear blending, then we
    // already have the correct color here and
    // can premultiply and return it.
    if (display_p3 && !linear) {
        color.rgb *= color.a;
        return color;
    }

    // The color is in either the sRGB or Display P3 color space,
    // so in either case, it's a color space which uses the sRGB
    // transfer function, so we can use one function in order to
    // linearize it in either case.
    //
    // Even if we aren't doing linear blending, the color
    // needs to be in linear space to convert color spaces.
    color = linearize(color);

    // If we're *NOT* using display P3 colors, then we're dealing
    // with an sRGB color, in which case we need to convert it in
    // to the Display P3 color space, since our output is always
    // Display P3.
    __target_switch
    {
        case metal:
        {
            if (!display_p3) {
                color.rgb = srgb_to_display_p3(color.rgb);
            }
        }
        default:
            break;
    }

    // If we're not doing linear blending, then we need to
    // unlinearize after doing the color space conversion.
    if (!linear) {
        color = unlinearize(color);
    }

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

// Convenience overload for callers that don't pass display_p3 explicitly.
float4 load_color(uint4 in_color, bool linear) {
    return load_color(in_color, (uniforms.bools & BoolFlags.UseDisplayP3) != BoolFlags.None, linear);
}

//----------------------------------------------------------------------------//
// Full Screen Vertex Shader
//----------------------------------------------------------------------------//

struct FullScreenVertexOut {
    float4 position : SV_Position;
};

[shader("vertex")]
FullScreenVertexOut full_screen_vertex(uint vid : SV_VertexID) {
    FullScreenVertexOut out;

    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;

    // Single triangle is clipped to viewport.
    //
    // X <- vid == 0: (-1, -3)
    // |\
    // | \
    // |  \
    // |###\
    // |#+# \ `+` is (0, 0). `#`s are viewport area.
    // |###  \
    // X------X <- vid == 2: (3, 1)
    // ^
    // vid == 1: (-1, 1)

    out.position = position;
    return out;
}

//----------------------------------------------------------------------------//
// Background Color Shader
//----------------------------------------------------------------------------//

[shader("fragment")]
float4 bg_color_fragment(FullScreenVertexOut in) : SV_Target0 {
    return load_color(
        unpack4u8(uniforms.bg_color_packed_4u8),
        (uniforms.bools & BoolFlags.UseDisplayP3) != BoolFlags.None,
        (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None
    );
}

//----------------------------------------------------------------------------//
// Background Image Shader
//----------------------------------------------------------------------------//

struct BgImageVertexIn {
    float  opacity : ATTR0;
    uint   info    : ATTR1;
};

struct BgImageVertexOut {
    float4 position  : SV_Position;
    nointerpolation float4 bg_color;
    nointerpolation float2 offset;
    nointerpolation float2 scale;
    nointerpolation float  opacity;
    nointerpolation uint   repeat;
};

[shader("vertex")]
BgImageVertexOut bg_image_vertex(
    uint vid : SV_VertexID,
    BgImageVertexIn in
) {
    BgImageVertexOut out;

    float4 position;
    position.x = (vid == 2) ? 3.0 : -1.0;
    position.y = (vid == 0) ? -3.0 : 1.0;
    position.z = 1.0;
    position.w = 1.0;

    // Single triangle is clipped to viewport.
    //
    // X <- vid == 0: (-1, -3)
    // |\
    // | \
    // |  \
    // |###\
    // |#+# \ `+` is (0, 0). `#`s are viewport area.
    // |###  \
    // X------X <- vid == 2: (3, 1)
    // ^
    // vid == 1: (-1, 1)

    out.position = position;
    out.opacity = in.opacity;
    out.repeat = in.info & BG_IMAGE_REPEAT;

    float2 screen_size = uniforms.screen_size;
    uint tex_w, tex_h;
    imageTexture.GetDimensions(tex_w, tex_h);
    float2 tex_size = float2(float(tex_w), float(tex_h));

    float2 dest_size = tex_size;
    BgImageFit fit = BgImageFit(in.info & BG_IMAGE_FIT_MASK);
    switch (fit) {
        // For `contain` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is smaller.
        case BgImageFit.Contain: {
            float scale = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
            dest_size = tex_size * scale;
        } break;

        // For `cover` we scale by a factor that makes the image
        // width match the screen width or makes the image height
        // match the screen height, whichever is larger.
        case BgImageFit.Cover: {
            float scale = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
            dest_size = tex_size * scale;
        } break;

        // For `stretch` we stretch the image to the size of
        // the screen without worrying about aspect ratio.
        case BgImageFit.Stretch: {
            dest_size = screen_size;
        } break;

        // For `none` we just use the original texture size.
        case BgImageFit.None: {
            dest_size = tex_size;
        } break;
    }

    float2 start = float2(0.0);
    float2 mid = (screen_size - dest_size) / float2(2.0);
    float2 end = screen_size - dest_size;

    float2 dest_offset = mid;
    BgImagePosition img_position = BgImagePosition(in.info & BG_IMAGE_POSITION_MASK);
    switch (img_position) {
        case BgImagePosition.TopLeft: {
            dest_offset = float2(start.x, start.y);
        } break;
        case BgImagePosition.TopCenter: {
            dest_offset = float2(mid.x, start.y);
        } break;
        case BgImagePosition.TopRight: {
            dest_offset = float2(end.x, start.y);
        } break;
        case BgImagePosition.MiddleLeft: {
            dest_offset = float2(start.x, mid.y);
        } break;
        case BgImagePosition.MiddleCenter: {
            dest_offset = float2(mid.x, mid.y);
        } break;
        case BgImagePosition.MiddleRight: {
            dest_offset = float2(end.x, mid.y);
        } break;
        case BgImagePosition.BottomLeft: {
            dest_offset = float2(start.x, end.y);
        } break;
        case BgImagePosition.BottomCenter: {
            dest_offset = float2(mid.x, end.y);
        } break;
        case BgImagePosition.BottomRight: {
            dest_offset = float2(end.x, end.y);
        } break;
    }

    out.offset = dest_offset;
    out.scale = tex_size / dest_size;

    // We load a fully opaque version of the bg color and combine it with
    // the alpha separately, because we need these as separate values in
    // the framgment shader.
    bool use_display_p3 = (uniforms.bools & BoolFlags.UseDisplayP3) != BoolFlags.None;
    bool use_linear_blending = (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None;
    uint4 u_bg_color = unpack4u8(uniforms.bg_color_packed_4u8);
    out.bg_color = float4(load_color(
                uint4(u_bg_color.rgb, 255),
                use_display_p3,
                use_linear_blending
            ).rgb, float(u_bg_color.a) / 255.0);
    return out;
}

[shader("fragment")]
float4 bg_image_fragment(BgImageVertexOut in) : SV_Target0 {
    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size, which effectively scales the original
    // size of the texture to the dest rect size.
    float2 tex_coord = (in.position.xy - in.offset) * in.scale;

    uint  tex_w, tex_h;
    imageTexture.GetDimensions(tex_w, tex_h);
    float2 tex_size = float2(float(tex_w), float(tex_h));

    // If we need to repeat the texture, wrap the coordinates.
    if (in.repeat != 0u) {
        tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(tex_coord < float2(0.0)) ||
            any(tex_coord >= tex_size))
    {
        rgba = float4(0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        rgba = imageTexture.Sample(tex_coord / tex_size);

        if (!((uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None)) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity, but cap it at
    // the value that will make it fully opaque relative to
    // the background color alpha, so it isn't overexposed.
    rgba *= min(in.opacity, 1.0 / in.bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(float4(0.0), float4(in.bg_color.rgb, 1.0) * float4(1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= in.bg_color.a;

    return rgba;
}

//----------------------------------------------------------------------------//
// Cell Background Shader
//----------------------------------------------------------------------------//

[shader("fragment")]
float4 cell_bg_fragment(FullScreenVertexOut in) : SV_Target0 {
    uint2 grid_size = unpack2u16(uniforms.grid_size_packed_2u16);
    int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));

    float4 bg = float4(0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((uniforms.padding_extend & PaddingExtend.Left) != PaddingExtend.None) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > int(grid_size.x) - 1) {
        if ((uniforms.padding_extend & PaddingExtend.Right) != PaddingExtend.None) {
            grid_pos.x = int(grid_size.x) - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of bounds.
    if (grid_pos.y < 0) {
        if ((uniforms.padding_extend & PaddingExtend.Up) != PaddingExtend.None) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > int(grid_size.y) - 1) {
        if ((uniforms.padding_extend & PaddingExtend.Down) != PaddingExtend.None) {
            grid_pos.y = int(grid_size.y) - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell.
    uint packed = bg_cells[grid_pos.y * int(grid_size.x) + grid_pos.x];
    uint4 cell_color = unpack4u8(packed);

    return load_color(
        cell_color,
        (uniforms.bools & BoolFlags.UseDisplayP3) != BoolFlags.None,
        (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None
    );
}

//----------------------------------------------------------------------------//
// Cell Text Shader
//----------------------------------------------------------------------------//

struct CellTextVertexIn {
    // The position of the glyph in the texture (x, y)
    uint2  glyph_pos   : ATTR0;
    // The size of the glyph in the texture (w, h)
    uint2  glyph_size  : ATTR1;
    // The left and top bearings for the glyph (x, y)
    int2   bearings    : ATTR2;
    // The grid coordinates (x, y) where x < columns and y < rows
    uint2  grid_pos    : ATTR3;
    // The color of the rendered text glyph.
    uint4  color       : ATTR4;
    // Which atlas this glyph is in.
    uint   atlas       : ATTR5;
    // Misc glyph properties.
    uint   glyph_bools : ATTR6;
};

struct CellTextVertexOut {
    float4 position : SV_Position;
    nointerpolation uint   atlas;
    nointerpolation float4 color;
    nointerpolation float4 bg_color;
    float2 tex_coord;
};

[shader("vertex")]
CellTextVertexOut cell_text_vertex(
    uint vid : SV_VertexID,
    CellTextVertexIn in
) {
    uint2 grid_size = unpack2u16(uniforms.grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(uniforms.cursor_pos_packed_2u16);
    bool cursor_wide = (uniforms.bools & BoolFlags.CursorWide) != BoolFlags.None;
    bool use_display_p3 = (uniforms.bools & BoolFlags.UseDisplayP3) != BoolFlags.None;
    bool use_linear_blending = (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None;
    GlyphBools glyph_bools = GlyphBools(in.glyph_bools);

    // Convert the grid x, y into world space x, y by accounting for cell size
    float2 cell_pos = uniforms.cell_size * float2(in.grid_pos);

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    CellTextVertexOut out;
    out.atlas = in.atlas;

    //              === Grid Cell ===
    //      +X
    // 0,0--...->
    //   |
    //   . offset.x = bearings.x
    // +Y.               .|.
    //   .               | |
    //   |   cell_pos -> +-------+   _.
    //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
    //                 | | .###. | |
    //                 | | #...# | |
    //   glyph_size.y -+ | ##### | |
    //                 | | #.... | +- bearings.y
    //                 |_| .#### | |
    //                   |       |_|
    //                   +-------+
    //                     |_._|
    //                       |
    //                  glyph_size.x
    //
    // In order to get the top left of the glyph, we compute an offset based on
    // the bearings. The Y bearing is the distance from the bottom of the cell
    // to the top of the glyph, so we subtract it from the cell height to get
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.

    float2 size = float2(in.glyph_size);
    float2 offset = float2(in.bearings);

    offset.y = uniforms.cell_size.y - offset.y;

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    out.position = mul(uniforms.projection_matrix,
                       float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture will
    // be sampled with pixel coordinate mode.
    out.tex_coord = float2(in.glyph_pos) + float2(in.glyph_size) * corner;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    out.color = load_color(in.color, use_display_p3, true);
    // Get the BG color
    out.bg_color = load_color(
            unpack4u8(bg_cells[int(in.grid_pos.y) * int(grid_size.x) + int(in.grid_pos.x)]),
            use_display_p3,
            true
        );
    // Blend it with the global bg color
    float4 global_bg = load_color(
            unpack4u8(uniforms.bg_color_packed_4u8),
            use_display_p3,
            true
        );
    out.bg_color += global_bg * float4(1.0 - out.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    if (uniforms.min_contrast > 1.0f && (glyph_bools & GlyphBools.NoMinContrast) == GlyphBools.None) {
        // Ensure our minimum contrast
        out.color = contrasted_color(uniforms.min_contrast, out.color, out.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((in.grid_pos.x == cursor_pos.x) || (cursor_wide && (in.grid_pos.x == (cursor_pos.x + 1u)))) && (in.grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, but we're not processing
    // the cursor glyph itself, then we need to change the color.
    if ((glyph_bools & GlyphBools.IsCursorGlyph) == GlyphBools.None && is_cursor_pos) {
        out.color = load_color(unpack4u8(uniforms.cursor_color_packed_4u8), use_display_p3, use_linear_blending);
    }

    return out;
}

[shader("fragment")]
float4 cell_text_fragment(CellTextVertexOut in) : SV_Target0 {
    bool use_linear_blending = (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None;
    bool use_linear_correction = (uniforms.bools & BoolFlags.UseLinearCorrection) != BoolFlags.None;

    switch (in.atlas) {
        default:
        case CellTextAtlas.Grayscale:
        {
            // Our input color is always linear.
            float4 color = in.color;

            // If we're not doing linear blending, then we need to
            // re-apply the gamma encoding to our color manually.
            //
            // Since the alpha is premultiplied, we need to divide
            // it out before unlinearizing and re-multiply it after.
            if (!use_linear_blending) {
                color.rgb /= float3(color.a);
                color = unlinearize(color);
                color.rgb *= float3(color.a);
            }

            // Fetch our alpha mask for this pixel.
            uint  atlas_w, atlas_h;
            atlasGrayscale.GetDimensions(atlas_w, atlas_h);
            float2 atlas_size = float2(float(atlas_w), float(atlas_h));
            float a = atlasGrayscale.Sample(in.tex_coord / atlas_size).r;

            // Linear blending weight correction corrects the alpha value to
            // produce blending results which match gamma-incorrect blending.
            if (use_linear_correction) {
                // Short explanation of how this works:
                //
                // We get the luminances of the foreground and background colors,
                // and then unlinearize them and perform blending on them. This
                // gives us our desired luminance, which we derive our new alpha
                // value from by mapping the range [bg_l, fg_l] to [0, 1], since
                // our final blend will be a linear interpolation from bg to fg.
                //
                // This yields virtually identical results for grayscale blending,
                // and very similar but non-identical results for color blending.
                float4 bg = in.bg_color;
                float fg_l = luminance(color.rgb);
                float bg_l = luminance(bg.rgb);
                // To avoid numbers going haywire, we don't apply correction
                // when the bg and fg luminances are within 0.001 of each other.
                if (abs(fg_l - bg_l) > 0.001) {
                    float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
                    a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
                }
            }

            // Multiply our whole color by the alpha mask.
            // Since we use premultiplied alpha, this is
            // the correct way to apply the mask.
            color *= a;

            return color;
        }

        case CellTextAtlas.Color:
        {
            // For now, we assume that color glyphs
            // are already premultiplied linear colors.
            uint  atlas_w, atlas_h;
            atlasColor.GetDimensions(atlas_w, atlas_h);
            float2 atlas_size = float2(float(atlas_w), float(atlas_h));
            float4 color = atlasColor.Sample(in.tex_coord / atlas_size);

            // If we are doing linear blending, we can return this right away.
            if (use_linear_blending) {
                return color;
            }

            // Otherwise we need to unlinearize the color. Since the alpha is
            // premultiplied, we need to divide it out before unlinearizing.
            color.rgb /= float3(color.a);
            color = unlinearize(color);
            color.rgb *= float3(color.a);

            return color;
        }
    }
}

//----------------------------------------------------------------------------//
// Image Shader
//----------------------------------------------------------------------------//

struct ImageVertexIn {
    float2 grid_pos    : ATTR0;
    float2 cell_offset : ATTR1;
    float4 source_rect : ATTR2;
    float2 dest_size   : ATTR3;
};

struct ImageVertexOut {
    float4 position  : SV_Position;
    float2 tex_coord;
};

[shader("vertex")]
ImageVertexOut image_vertex(
    uint vid : SV_VertexID,
    ImageVertexIn in
) {
    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    float2 tex_coord = in.source_rect.xy;
    tex_coord += in.source_rect.zw * corner;

    // Normalize the coordinates.
    uint  tex_w, tex_h;
    imageTexture.GetDimensions(tex_w, tex_h);
    tex_coord /= float2(float(tex_w), float(tex_h));

    ImageVertexOut out;

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    float2 image_pos = (uniforms.cell_size * in.grid_pos) + in.cell_offset;
    image_pos += in.dest_size * corner;

    out.position = mul(uniforms.projection_matrix,
                        float4(image_pos.xy, 1.0, 1.0));
    out.tex_coord = tex_coord;
    return out;
}

[shader("fragment")]
float4 image_fragment(ImageVertexOut in) : SV_Target0 {
    bool use_linear_blending = (uniforms.bools & BoolFlags.UseLinearBlending) != BoolFlags.None;

    float4 rgba = imageTexture.Sample(in.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= float3(rgba.a);

    return rgba;
}
