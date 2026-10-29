// glasstty-scrim: reading scrim over native macOS clear glass, with rounded corners.
// https://github.com/qianyilun/glasstty
//
// The plain variant of glasstty.glsl: a #f5f5f7 scrim behind the text and nothing else.
// A rounded-rectangle SDF makes the scrim corners follow the window's 16pt corner radius,
// while the feathered rim still lets the clear glass refraction show through along every edge.
// iChannel0 is premultiplied RGBA. Ghostty has no backing-scale uniform, so sizes
// below are in points and converted with a fixed Retina scale.
const float pixelsPerPoint = 2.0;
const float readingStrength = 0.96;
const float cornerRadiusPt = 16.0;   // macOS 26 titled window corner radius
const float edgeMarginPt = 0.0;      // clear band before the scrim starts
const float featherPt = 8.0;         // scrim fades in over this distance
const vec3 readingTint = vec3(0.96078431, 0.96078431, 0.96862745); // #f5f5f7

// Signed distance to a rounded box centered at the origin (negative inside).
float roundedBoxDistance(vec2 p, vec2 halfSize, float radius) {
    vec2 q = abs(p) - halfSize + radius;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - radius;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 terminal = texture(iChannel0, uv);

    float margin = edgeMarginPt * pixelsPerPoint;
    float feather = max(featherPt * pixelsPerPoint, 0.0001);
    vec2 halfSize = iResolution.xy * 0.5 - margin;
    // Concentric with the window corner: inset shapes shrink their radius by the inset.
    float radius = max(cornerRadiusPt * pixelsPerPoint - margin, 0.0);
    float inside = -roundedBoxDistance(fragCoord - iResolution.xy * 0.5, halfSize, radius);
    float mask = readingStrength * smoothstep(0.0, feather, inside);

    // Terminal over scrim: opaque glyphs stay intact, uncovered pixels gain tint.
    float uncoveredMask = mask * (1.0 - terminal.a);
    fragColor = vec4(terminal.rgb + readingTint * uncoveredMask,
                     terminal.a + uncoveredMask);
}
