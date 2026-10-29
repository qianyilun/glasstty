// glasstty: a Liquid Glass look for Ghostty (light). Rounded reading scrim plus glass pills
// and glass blocks. https://github.com/qianyilun/glasstty
//
// Needs the glasstty-light theme (or its palette 200/204 markers) and, in Ghostty,
// background-blur = macos-glass-clear with background-opacity-cells = false.
//
// Builds on glasstty-scrim.glsl. Besides the #f5f5f7 reading scrim over clear glass, it
// redraws a few kinds of cell-background blocks as glass:
//   - Pills (tmux tab bar): palette 204 = tabs as clear glass, palette 200 = current tab as
//     blue glass. The capsule is 30pt tall, centered on the label row and spilling into the
//     window padding above and a blank status line below. Clear glass follows the dark iOS 26
//     capsule: a thin frosted body, lighter toward the top, so whatever is behind the window
//     shows through; a clearer crescent along the bottom bezel where the glass is thickest;
//     bright rims at the top and bottom edges and a dark hairline. Dark labels get a soft white
//     glow so they stay legible over any backdrop. Blue glass follows the iOS "Chat" button: a
//     translucent body that reads as #5B83ED on screen, with a lighter rim and a faint glow along
//     the bottom inside edge.
//   - Blocks: palette 1/2 (Claude diff removed/added), palette 7 (Claude user message) and the
//     selection. Rounded corners and a top rim; diff and message backgrounds are swapped for
//     light glass tints while glyph colors are kept.
//
// How blocks are found: with background-blur = macos-glass-clear the default background is
// transparent in iChannel0 and, with background-opacity-cells = false, explicit cell
// backgrounds are opaque. Glyphs drawn on an explicit background are opaque too, so scanning
// for the end of the opaque run gives the distance to the block edge regardless of text.
// The block kind comes from an exact palette match somewhere along that run.
//
// Notes on Ghostty 1.3.1 on macOS, found by testing:
//   - iChannel0 holds Display P3 encoded colors while the color uniforms are sRGB, so the
//     reference colors are converted before matching.
//   - iSelectionBackgroundColor and iSelectionForegroundColor arrive swapped; the lighter of
//     the two is taken as the selection background.
//   - iCurrentCursor.w is the cell height in pixels.
//   - iChannel0 is premultiplied RGBA and fragCoord has a top-left origin.
// Ghostty has no backing-scale uniform, so point sizes use a fixed Retina scale.
const float pixelsPerPoint = 2.0;

// Reading scrim, same as glasstty-scrim.glsl.
const float readingStrength = 0.96;
const float cornerRadiusPt = 16.0;   // macOS 26 titled window corner radius
const float edgeMarginPt = 0.0;      // clear band before the scrim starts
const float featherPt = 8.0;         // scrim fades in over this distance
const vec3 readingTint = vec3(0.96078431, 0.96078431, 0.96862745); // #f5f5f7

// Block detection limits, in pixels.
const int scanX = 28;
const float minBlockWidthPx = 12.0;
const float fallbackCellHeightPx = 36.0;

// Pill geometry. tmux pads each label with two spaces inside the colored span.
const int pillScanX = 64;            // enough to measure the rounded ends plus the shadow
const float pillHeightPt = 30.0;
// Lighting, after open-source Liquid Glass recreations (kube.io, Prismal, liquid-glass-studio):
// a specular ring peaking about 1pt inside the edge with |light| lobes, a hairline outline,
// light gathering along the bottom inside edge, and a shadow kept light over light backgrounds.
const vec2 lightDirection = vec2(-0.53, -0.85); // from the top-left; y grows downward
const float ringPeakPt = 1.0;
const float hairlinePt = 0.5;
// Clear pill.
const float clearHaze = 0.08;        // white veil; the rest of the body shows what is behind
const float clearHazeTop = 0.08;     // extra veil toward the top
const float clearBezelPt = 7.0;      // depth of the bottom crescent, about a quarter of the pill
const float clearBezelShade = 0.06;  // the crescent has no veil and a slight shade instead
const float clearRim = 0.90;
const float clearHairline = 0.16;
const float labelHalo = 0.55;        // white glow behind dark label glyphs
const float labelHaloPt = 1.5;       // radius of the inner glow ring; the outer ring is twice that
// Blue pill. The body color is chosen so that at tintAlpha over light content it reads as the
// iOS button blue #5B83ED once Ghostty's color management has lightened it (measured on
// screen); white text on that stays above 3:1.
const vec3 accentGlass = vec3(0.09019608, 0.2745098, 0.90196078); // #1746e6
const float tintAlpha = 0.78;
const float tintSheen = 0.05;
const float tintGlow = 0.10;
const float tintRim = 0.70;
const float tintHairline = 0.18;
// Shadow under pills.
const float shadowOffsetPt = 1.5;
const float shadowBlurPt = 5.0;
const float shadowClear = 0.09;
const float shadowTint = 0.20;

// Block look.
const float blockRadiusPt = 6.0;
const float selectionRadiusPt = 4.0;
const float blockRimTop = 0.40;
const float removedTint = 0.16;      // share of palette 1 kept in the light glass tint
const float addedTint = 0.18;        // share of palette 2 kept in the light glass tint

const int KIND_NONE = 0;
const int KIND_PILL_ACCENT = 1;
const int KIND_PILL_NEUTRAL = 2;
const int KIND_REMOVED = 3;
const int KIND_ADDED = 4;
const int KIND_MESSAGE = 5;
const int KIND_SELECTION = 6;
const int KIND_COUNT = 7;

// Reference colors in the texture's color space, filled once per pixel in mainImage.
vec3 references[KIND_COUNT];

vec3 srgbToLinear(vec3 c) {
    return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c));
}

vec3 linearToSrgb(vec3 c) {
    return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c));
}

vec3 srgbToDisplayP3(vec3 c) {
    const mat3 toP3 = mat3(0.8225, 0.0332, 0.0171,
                           0.1774, 0.9669, 0.0724,
                           0.0000, 0.0000, 0.9108);
    return linearToSrgb(toP3 * srgbToLinear(c));
}

float luminance(vec3 c) {
    return dot(c, vec3(0.2126, 0.7152, 0.0722));
}

void loadReferences() {
    vec3 selection = luminance(iSelectionBackgroundColor) > luminance(iSelectionForegroundColor)
        ? iSelectionBackgroundColor : iSelectionForegroundColor;
    references[KIND_NONE] = vec3(-1.0);
    references[KIND_PILL_ACCENT] = srgbToDisplayP3(iPalette[200]);
    references[KIND_PILL_NEUTRAL] = srgbToDisplayP3(iPalette[204]);
    references[KIND_REMOVED] = srgbToDisplayP3(iPalette[1]);
    references[KIND_ADDED] = srgbToDisplayP3(iPalette[2]);
    references[KIND_MESSAGE] = srgbToDisplayP3(iPalette[7]);
    references[KIND_SELECTION] = srgbToDisplayP3(selection);
}

vec4 texel(vec2 p) {
    return texture(iChannel0, p / iResolution.xy);
}

bool inBounds(vec2 p) {
    return p.x >= 0.0 && p.y >= 0.0 && p.x < iResolution.x && p.y < iResolution.y;
}

bool isOpaque(vec2 p) {
    return inBounds(p) && texel(p).a > 0.98;
}

bool sameColor(vec3 a, vec3 b) {
    vec3 d = abs(a - b);
    return max(d.r, max(d.g, d.b)) < 2.5 / 255.0;
}

int kindOf(vec3 c) {
    for (int kind = 1; kind < KIND_COUNT; kind++) {
        if (sameColor(c, references[kind])) return kind;
    }
    return KIND_NONE;
}

bool isPill(int kind) {
    return kind == KIND_PILL_ACCENT || kind == KIND_PILL_NEUTRAL;
}

// Number of consecutive opaque pixels from p (exclusive) along dir, up to maxSteps.
float opaqueRun(vec2 p, vec2 dir, int maxSteps) {
    float n = 0.0;
    for (int i = 1; i <= maxSteps; i++) {
        if (!isOpaque(p + dir * float(i))) break;
        n = float(i);
    }
    return n;
}

// Finds the block kind from the first palette match on this row within the opaque run.
int blockKind(vec2 p, float left, float right, out vec3 background) {
    background = texel(p).rgb;
    int kind = kindOf(background);
    if (kind != KIND_NONE) return kind;
    for (int i = 1; i <= scanX; i++) {
        float fi = float(i);
        if (fi > left && fi > right) break;
        if (fi <= left) {
            background = texel(p - vec2(fi, 0.0)).rgb;
            kind = kindOf(background);
            if (kind != KIND_NONE) return kind;
        }
        if (fi <= right) {
            background = texel(p + vec2(fi, 0.0)).rgb;
            kind = kindOf(background);
            if (kind != KIND_NONE) return kind;
        }
    }
    return KIND_NONE;
}

// Signed distance to a rounded box centered at the origin (negative inside).
float roundedBoxDistance(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

// Reading scrim over whatever the terminal drew here.
vec4 scrim(vec2 fragCoord, vec4 terminal) {
    float margin = edgeMarginPt * pixelsPerPoint;
    float feather = max(featherPt * pixelsPerPoint, 0.0001);
    vec2 halfSize = iResolution.xy * 0.5 - margin;
    // Concentric with the window corner: inset shapes shrink their radius by the inset.
    float radius = max(cornerRadiusPt * pixelsPerPoint - margin, 0.0);
    float inside = -roundedBoxDistance(fragCoord - iResolution.xy * 0.5, halfSize, radius);
    float mask = readingStrength * smoothstep(0.0, feather, inside);

    // Terminal over scrim: opaque glyphs stay intact, uncovered pixels gain tint.
    float uncoveredMask = mask * (1.0 - terminal.a);
    return vec4(terminal.rgb + readingTint * uncoveredMask, terminal.a + uncoveredMask);
}

struct Pill {
    vec2 center;
    vec2 halfSize;
    float radius;
    int kind;
    vec3 color;   // pill background as stored in iChannel0
};

// Capsule for the label cell containing q, an opaque pixel in a pill row. Horizontal runs are
// capped, which only shortens the box far from q, where it does not change the result near q.
Pill pillAt(vec2 q, int kind, vec3 color, float cellHeight) {
    float left = opaqueRun(q, vec2(-1.0, 0.0), pillScanX);
    float right = opaqueRun(q, vec2(1.0, 0.0), pillScanX);
    float up = opaqueRun(q, vec2(0.0, -1.0), int(cellHeight));
    float rowCenter = q.y - up - 0.5 + cellHeight * 0.5;
    float halfHeight = pillHeightPt * pixelsPerPoint * 0.5;
    vec2 lo = vec2(q.x - left - 0.5, rowCenter - halfHeight);
    vec2 hi = vec2(q.x + right + 0.5, rowCenter + halfHeight);
    Pill pill;
    pill.center = (lo + hi) * 0.5;
    pill.halfSize = (hi - lo) * 0.5;
    pill.radius = min(pill.halfSize.x, pill.halfSize.y);
    pill.kind = kind;
    pill.color = color;
    return pill;
}

// Finds a pill label row above or below p that is close enough for its capsule or shadow to
// reach p. Three columns are probed so glyphs in the label row do not hide the background.
bool pillNear(vec2 p, float cellHeight, out Pill pill) {
    float reach = pillHeightPt * pixelsPerPoint * 0.5 - cellHeight * 0.5
        + (shadowOffsetPt + shadowBlurPt) * pixelsPerPoint + 4.0;
    for (int i = 1; i <= 24; i++) {
        float dy = float(i) * 2.0;
        if (dy > reach) break;
        for (int side = -1; side <= 1; side += 2) {
            for (int column = -1; column <= 1; column++) {
                vec2 q = p + vec2(float(column) * 8.0, float(side) * dy);
                if (!inBounds(q)) continue;
                vec4 t = texel(q);
                if (t.a < 0.98) continue;
                int kind = kindOf(t.rgb);
                if (isPill(kind)) {
                    pill = pillAt(q, kind, t.rgb, cellHeight);
                    return true;
                }
            }
        }
    }
    return false;
}

float pillShadow(vec2 p, Pill pill) {
    vec2 local = p - pill.center - vec2(0.0, shadowOffsetPt * pixelsPerPoint);
    float d = roundedBoxDistance(local, pill.halfSize, pill.radius);
    float strength = pill.kind == KIND_PILL_ACCENT ? shadowTint : shadowClear;
    return strength * exp(-max(d, 0.0) / (shadowBlurPt * pixelsPerPoint * 0.5));
}

// Darkens (or, under the blue pill, tints) premultiplied scrim output by the pill shadow.
vec4 withShadow(vec4 base, float shadow, Pill pill) {
    vec3 shade = pill.kind == KIND_PILL_ACCENT ? srgbToDisplayP3(accentGlass) * 0.55 : vec3(0.0);
    base.rgb = mix(base.rgb, shade * base.a, shadow);
    return base;
}

// Outward normal of the capsule at a point given relative to its center.
vec2 capsuleNormal(vec2 local, Pill pill) {
    float a = max(pill.halfSize.x - pill.radius, 0.0);
    vec2 v = local - vec2(clamp(local.x, -a, a), 0.0);
    float len = length(v);
    return len > 0.001 ? v / len : vec2(0.0, local.y < 0.0 ? -1.0 : 1.0);
}

// Premultiplied composite of a flat color layer over dst.
vec4 over(vec4 dst, vec3 color, float alpha) {
    return vec4(color * alpha, alpha) + dst * (1.0 - alpha);
}

// Glass pill at p, premultiplied. glyph/ink separate the label from the pill background, and
// halo is the glow behind dark labels (0 away from the label row).
vec4 shadePill(vec2 p, Pill pill, vec3 glyph, float ink, float halo, out float coverage) {
    vec2 local = p - pill.center;
    float sdf = roundedBoxDistance(local, pill.halfSize, pill.radius);
    coverage = clamp(0.5 - sdf, 0.0, 1.0);
    float inside = max(-sdf, 0.0);
    float v = clamp(local.y / (2.0 * pill.halfSize.y) + 0.5, 0.0, 1.0); // 0 top, 1 bottom
    vec2 normal = capsuleNormal(local, pill);
    float facing = dot(normal, normalize(lightDirection));
    float lobe = pow(max(facing, 0.0), 3.0) + 0.6 * pow(max(-facing, 0.0), 1.5);
    // Circular ring profile: zero at the edge, peak at ringPeak, zero again at twice that.
    float t = 1.0 - inside / (ringPeakPt * pixelsPerPoint);
    float ring = sqrt(max(0.0, 1.0 - t * t));
    float hairline = 1.0 - smoothstep(0.0, hairlinePt * pixelsPerPoint, inside);
    float bottom = max(normal.y, 0.0);

    vec4 body;
    if (pill.kind == KIND_PILL_ACCENT) {
        vec3 tint = srgbToDisplayP3(accentGlass);
        body = vec4(tint * tintAlpha, tintAlpha);
        body = over(body, vec3(1.0), tintSheen * (1.0 - v) * (1.0 - v));
        float glow = pow(1.0 - smoothstep(0.0, 4.0 * pixelsPerPoint, inside), 2.0) * bottom;
        body = over(body, vec3(1.0), glow * tintGlow);
        body = over(body, mix(tint, vec3(1.0), 0.5), ring * min(0.35 + lobe, 1.0) * tintRim);
        body = over(body, tint * 0.6, hairline * tintHairline);
    } else {
        // The crescent follows the bottom edge and fades out around the rounded ends, with a
        // crisp inner boundary like the thick lower bezel on iOS.
        float bezel = clearBezelPt * pixelsPerPoint;
        float crescent = (1.0 - smoothstep(bezel - 1.5, bezel + 1.5, inside))
            * smoothstep(0.3, 0.8, normal.y);
        float haze = (clearHaze + clearHazeTop * (1.0 - v) * (1.0 - v)) * (1.0 - crescent);
        body = vec4(vec3(haze), haze);
        body = over(body, vec3(0.0), crescent * clearBezelShade);
        body = over(body, vec3(1.0), halo * labelHalo);
        body = over(body, vec3(1.0), ring * lobe * clearRim);
        body = over(body, vec3(0.0), hairline * clearHairline);
    }
    return mix(body, vec4(glyph, 1.0), ink);
}

// Glyph coverage of the label at q, 0 outside the label row.
float labelInk(vec2 q, vec3 background, vec3 label) {
    if (!inBounds(q)) return 0.0;
    vec4 t = texel(q);
    if (t.a < 0.98) return 0.0;
    return clamp(length(t.rgb - background) / max(length(label - background), 0.001), 0.0, 1.0);
}

// Soft glow from glyph coverage on two rings around p.
float labelGlow(vec2 p, vec3 background, vec3 label) {
    float r = labelHaloPt * pixelsPerPoint;
    float sum = 0.0;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.52359878; // 30 degrees
        vec2 d = vec2(cos(a), sin(a)) * r;
        sum += labelInk(p + d, background, label) + 0.5 * labelInk(p + 2.0 * d, background, label);
    }
    return clamp(sum / 6.0, 0.0, 1.0);
}

// Coverage of a rounded rectangle given distances to its four edges, plus the inner edge distance.
float roundedCoverage(float eL, float eR, float eU, float eD, float radius, out float edgeDistance) {
    float ex = min(eL, eR);
    float ey = min(eU, eD);
    edgeDistance = min(ex, ey);
    if (ex < radius && ey < radius) {
        float d = length(vec2(radius - ex, radius - ey)) - radius;
        edgeDistance = -d;
        return clamp(0.5 - d, 0.0, 1.0);
    }
    return clamp(edgeDistance + 0.5, 0.0, 1.0);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    loadReferences();
    vec2 p = fragCoord;
    vec4 terminal = texel(p);
    float cellHeight = iCurrentCursor.w > 4.0 ? iCurrentCursor.w : fallbackCellHeightPx;

    if (terminal.a < 0.98) {
        // Cell widths are fractional, so a block's edge column can be partly covered. Drop
        // those pixels; the block itself draws its own anti-aliased edge.
        if (terminal.a > 0.02 && kindOf(terminal.rgb / terminal.a) != KIND_NONE) {
            terminal = vec4(0.0);
        }
        fragColor = scrim(p, terminal);
        Pill near;
        if (pillNear(p, cellHeight, near)) {
            // The capsule reaches beyond its label row, so pixels above and below can be glass.
            float coverage;
            vec4 glass = shadePill(p, near, vec3(0.0), 0.0, 0.0, coverage);
            fragColor = mix(withShadow(fragColor, pillShadow(p, near), near), glass, coverage);
        }
        return;
    }

    float left = opaqueRun(p, vec2(-1.0, 0.0), scanX);
    float right = opaqueRun(p, vec2(1.0, 0.0), scanX);
    vec3 background;
    int kind = blockKind(p, left, right, background);
    if (kind == KIND_NONE || left + right + 1.0 < minBlockWidthPx) {
        fragColor = scrim(p, terminal);
        return;
    }

    // Blocks fill whole cell rows; this skips glyphs drawn in a block color, such as a bullet.
    float up = opaqueRun(p, vec2(0.0, -1.0), int(cellHeight));
    float down = opaqueRun(p, vec2(0.0, 1.0), int(cellHeight));
    if (up + down + 1.0 < cellHeight - 2.0) {
        fragColor = scrim(p, terminal);
        return;
    }

    float eL = left + 0.5;
    float eR = right + 0.5;
    vec3 color = terminal.rgb;
    float coverage;
    float edgeDistance;

    if (isPill(kind)) {
        Pill pill = pillAt(p, kind, background, cellHeight);
        // Separate the label from the pill background: estimate glyph coverage against the
        // label color tmux uses (white on blue, #1d1d1f on clear) and recover the glyph color.
        vec3 label = kind == KIND_PILL_ACCENT ? vec3(1.0) : srgbToDisplayP3(iForegroundColor);
        float ink = clamp(length(color - background) / max(length(label - background), 0.001), 0.0, 1.0);
        vec3 glyph = ink > 0.01 ? clamp((color - background * (1.0 - ink)) / ink, 0.0, 1.0) : color;
        float halo = kind == KIND_PILL_NEUTRAL ? labelGlow(p, background, label) : 0.0;
        vec4 glass = shadePill(p, pill, glyph, ink, halo, coverage);
        // Outside the capsule: scrim with the pill shadow, keeping glyphs that reach past it.
        vec4 outside = withShadow(scrim(p, vec4(0.0)), pillShadow(p, pill), pill);
        outside = mix(outside, vec4(glyph, 1.0), ink);
        fragColor = mix(outside, glass, coverage);
        return;
    }

    float eU = up + 0.5;
    float eD = down + 0.5;
    float radiusPt = kind == KIND_SELECTION ? selectionRadiusPt : blockRadiusPt;
    float radius = min(radiusPt * pixelsPerPoint, min((eL + eR) * 0.5, (eU + eD) * 0.5));
    coverage = roundedCoverage(eL, eR, eU, eD, radius, edgeDistance);

    vec3 glass = color;
    if (kind != KIND_SELECTION) {
        vec3 target;
        if (kind == KIND_REMOVED) target = mix(readingTint, background, removedTint);
        else if (kind == KIND_ADDED) target = mix(readingTint, background, addedTint);
        else target = vec3(0.995);
        // Swap the background while keeping glyph colors: estimate glyph coverage from how far
        // this pixel is from the background, relative to the default foreground.
        float span = max(length(srgbToDisplayP3(iForegroundColor) - background), 0.001);
        float ink = clamp(length(color - background) / span, 0.0, 1.0);
        glass = color + (target - background) * (1.0 - ink);
    }
    float topBand = 1.0 - smoothstep(0.0, 2.4, eU);
    glass = mix(glass, vec3(1.0), blockRimTop * topBand);
    if (kind == KIND_MESSAGE) {
        float hairline = 1.0 - smoothstep(0.0, 1.2, edgeDistance);
        glass *= 1.0 - 0.07 * hairline;
    }

    if (coverage < 1.0) {
        fragColor = mix(scrim(p, vec4(0.0)), vec4(glass, 1.0), coverage);
        return;
    }
    fragColor = vec4(glass, 1.0);
}
