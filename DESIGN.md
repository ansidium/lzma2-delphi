# Desktop GUI

The VCL window uses logical pixels. Its default client area is 896 × 520. The frame, fields, selectors, and main buttons are 36 px high. The content inset is 24 px, the column gap is 16 px, and field labels sit 8 px above their controls.

Segoe UI sizes are 12 px for supporting text and 14 px for controls. The window title uses 16 px Segoe UI Semibold and dialog titles use 18 px. Sizes are recalculated from the logical values on a DPI change. Windows supplies the system menu and its font.

The language picker supports search, keyboard navigation, and wheel or drag scrolling. Its highlighted rows have a 4 px corner radius.

Compression shows the checksum selector for XZ. Extraction shows the container and thread settings. The three modes share the same action baseline when the content fits. At smaller window sizes, the content scrolls below the fixed header. The dots in the lower-right corner mark the native resize area and disappear when the window is maximized.

The application mark is in `assets` and the Windows icon is in `tools/Lzma2_GUI.ico`.
