//
// JPM GUI — Dark Mode Theme & Metrics
//

#import "Basic";
#import "Simp";

Vector4 :: struct {
    x, y, z, w: float32;
}

COLOR_BG            :: Vector4.{0.08, 0.09, 0.11, 1.0};
COLOR_SURFACE       :: Vector4.{0.12, 0.14, 0.17, 1.0};
COLOR_SURFACE_HOVER :: Vector4.{0.16, 0.18, 0.22, 1.0};
COLOR_CARD          :: Vector4.{0.14, 0.16, 0.20, 1.0};

COLOR_HEADER        :: Vector4.{0.15, 0.17, 0.22, 1.0};
COLOR_ROW_EVEN      :: Vector4.{0.11, 0.12, 0.15, 1.0};
COLOR_ROW_ODD       :: Vector4.{0.13, 0.14, 0.18, 1.0};
COLOR_ROW_SELECTED  :: Vector4.{0.18, 0.25, 0.38, 1.0};

COLOR_BORDER        :: Vector4.{0.22, 0.25, 0.30, 1.0};
COLOR_BORDER_LIGHT  :: Vector4.{0.30, 0.34, 0.40, 1.0};

COLOR_TEXT_MAIN     :: Vector4.{0.92, 0.94, 0.96, 1.0};
COLOR_TEXT_MUTED    :: Vector4.{0.55, 0.60, 0.66, 1.0};
COLOR_TEXT_DIM      :: Vector4.{0.40, 0.44, 0.50, 1.0};

COLOR_ACCENT        :: Vector4.{0.20, 0.50, 0.95, 1.0}; // Blue
COLOR_ACCENT_HOVER  :: Vector4.{0.28, 0.58, 1.00, 1.0};

COLOR_RUNNING       :: Vector4.{0.18, 0.80, 0.44, 1.0}; // Green
COLOR_CRASHED       :: Vector4.{0.92, 0.26, 0.26, 1.0}; // Red
COLOR_STOPPED       :: Vector4.{0.50, 0.54, 0.58, 1.0}; // Gray
COLOR_WARNING       :: Vector4.{0.95, 0.65, 0.15, 1.0}; // Amber

COLOR_CHART_CPU     :: Vector4.{0.25, 0.70, 0.95, 1.0}; // Cyan
COLOR_CHART_RAM     :: Vector4.{0.85, 0.45, 0.95, 1.0}; // Purple
COLOR_CHART_GRID    :: Vector4.{0.20, 0.22, 0.28, 1.0};

// Drawing helper
draw_rect :: (x: float32, y: float32, w: float32, h: float32, color: Vector4) {
    Simp.set_shader_for_color();
    p0 := Vector2.{x, y};
    p1 := Vector2.{x + w, y};
    p2 := Vector2.{x + w, y + h};
    p3 := Vector2.{x, y + h};
    c := Vector4.{color.x, color.y, color.z, color.w};
    Simp.immediate_quad(p0, p1, p2, p3, c);
}

draw_rect_outline :: (x: float32, y: float32, w: float32, h: float32, thickness: float32, color: Vector4) {
    // Top
    draw_rect(x, y + h - thickness, w, thickness, color);
    // Bottom
    draw_rect(x, y, w, thickness, color);
    // Left
    draw_rect(x, y, thickness, h, color);
    // Right
    draw_rect(x + w - thickness, y, thickness, h, color);
}
