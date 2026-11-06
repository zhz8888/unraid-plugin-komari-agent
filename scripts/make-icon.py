#!/usr/bin/env python3
"""Generate the plugin icon.

The icon is a source asset of the repository, but it is generated rather than
drawn by hand so that it stays reproducible and reviewable: the drawing code is
the specification, and the PNG is what the Unraid WebGUI actually renders.

The image is drawn at four times the target size and downsampled with Lanczos.
Pillow has no antialiasing for lines and polygons, so drawing at 256x256
directly produces visibly jagged strokes on the diagonal of the heartbeat
trace. The supersampled result is identical in composition and smooth on screen.

The shape matches icon.svg: a rounded square in a blue vertical gradient, three
faint horizontal rules and a heartbeat trace across the middle.

Usage:
    python3 scripts/make-icon.py [output.png]
"""

import os
import sys

from PIL import Image, ImageDraw

SIZE = 256
SCALE = 4
RADIUS = 44

# The gradient runs from a lighter blue at the top to a deep blue at the
# bottom. It is dark enough for the white trace to stay readable at the 32 pixel
# size the Plugins tab uses.
TOP = (46, 123, 246)
BOTTOM = (18, 58, 140)

# The heartbeat trace, in the 256x256 coordinate system of icon.svg.
TRACE = [
    (36, 128), (84, 128), (98, 92), (116, 168),
    (134, 110), (148, 140), (162, 128), (220, 128),
]

# The faint grid rules, in the 256x256 coordinate system of icon.svg. The rule
# at y=128 is deliberately absent: it would lie along the flat part of the
# heartbeat trace and swallow it, because a faint line drawn over a white line
# is indistinguishable from a break in the trace.
GRID_Y = (96, 160)
GRID_X = (40, 216)

TRACE_WIDTH = 11
GRID_WIDTH = 3


def lerp_colour(top, bottom, ratio):
    """Interpolate between two RGB colours."""
    return tuple(int(round(top[i] + (bottom[i] - top[i]) * ratio)) for i in range(3))


def rounded_gradient(size, radius, top, bottom):
    """Return an RGBA image with a vertical gradient inside a rounded square."""
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gradient = Image.new("RGBA", (size, size))

    pixels = gradient.load()
    for y in range(size):
        colour = lerp_colour(top, bottom, y / float(size - 1))
        for x in range(size):
            pixels[x, y] = colour + (255,)

    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, size - 1, size - 1), radius=radius, fill=255
    )
    image.paste(gradient, (0, 0), mask)
    return image


def scale_point(point, factor):
    """Scale a point from the 256 unit coordinate system to the canvas."""
    return (point[0] * factor, point[1] * factor)


def draw_grid(draw, factor, size):
    """Draw the faint horizontal rules of the dashboard grid."""
    colour = (255, 255, 255, 46)
    width = max(1, GRID_WIDTH * factor)
    for y in GRID_Y:
        draw.line(
            [
                (GRID_X[0] * factor, y * factor),
                (GRID_X[1] * factor, y * factor),
            ],
            fill=colour,
            width=width,
        )


def draw_trace(draw, factor):
    """Draw the heartbeat trace.

    The trace is a light stroke with a brighter core. Drawing it twice gives the
    soft edge the SVG gets from its gradient without needing a real gradient
    stroke, which Pillow cannot draw.
    """
    points = [scale_point(point, factor) for point in TRACE]

    outer = max(1, TRACE_WIDTH * factor)
    draw.line(points, fill=(255, 255, 255, 150), width=outer, joint="curve")

    inner = max(1, int(TRACE_WIDTH * factor * 0.62))
    draw.line(points, fill=(255, 255, 255, 255), width=inner, joint="curve")

    # A round join at every vertex, so the corners of the trace match the
    # stroke-linejoin="round" of the SVG rather than showing a mitre.
    radius = outer / 2.0
    for point in points:
        draw.ellipse(
            [
                point[0] - radius, point[1] - radius,
                point[0] + radius, point[1] + radius,
            ],
            fill=(255, 255, 255, 255),
        )


def default_output():
    """The icon location inside the package source tree."""
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    return os.path.join(
        root,
        "src",
        "usr",
        "local",
        "emhttp",
        "plugins",
        "unraid-plugin-komari-agent",
        "unraid-plugin-komari-agent.png",
    )


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else default_output()

    canvas = SIZE * SCALE
    image = rounded_gradient(canvas, RADIUS * SCALE, TOP, BOTTOM)
    draw = ImageDraw.Draw(image)

    draw_grid(draw, SCALE, canvas)
    draw_trace(draw, SCALE)

    image = image.resize((SIZE, SIZE), Image.LANCZOS)

    directory = os.path.dirname(os.path.abspath(out_path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    image.save(out_path, format="PNG", optimize=True)

    print("written", out_path)


if __name__ == "__main__":
    main()
