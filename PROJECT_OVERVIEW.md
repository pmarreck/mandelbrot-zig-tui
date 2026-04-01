# Mandelbrot TUI Explorer

An interactive terminal-based Mandelbrot set explorer written in pure Zig.

## Goals
- Render the Mandelbrot set in a terminal using 256 ANSI colors and ASCII density characters
- Navigate via mouse (click to zoom) and keyboard (arrows, +/-, etc.)
- Hexagonal architecture: pure computational core with no I/O, TUI adapter for all I/O
- f128 precision for deep zooms (~10^-33)

## Terminology
- **Escape time**: The number of iterations before |z|² > 4; determines color/character
- **Viewport**: The rectangular region of the complex plane currently displayed
- **Density characters**: The 10-level ASCII set ` .:-=+*#%@` mapping luminance
- **Interior point**: A point in the Mandelbrot set (never escapes); rendered as black space
