import QtQuick
import QtQuick.Shapes
import qs.Commons

// Native disk glyph for Proton Drive — a 3.5" diskette: a chamfered square
// body with a shutter window at the top and a label window at the bottom.
// It is the one storage shape everybody still reads instantly, and — unlike
// a platter, a cylinder or a cloud — it is made entirely of straight edges,
// which is what actually survives the bar's ~11px slot.
//
// Two earlier cuts of this icon tried a multi-bump cloud (circles piled over
// a base bar); at bar-icon size the overlapping circles blurred into a
// mushroom or a starburst rather than a cloud. A third cut fell back to a
// single bold teardrop, which held up at size but read as a droplet, not as
// storage. The lesson from all three: at this scale only axis-aligned
// straight-edged polygons keep their identity, so this glyph is built the
// same way DropboxIcon builds its diamonds — flat ShapePaths, no curves, no
// strokes, `antialiasing` + a 4x multisampled layer.
//
// The two windows are real holes in the body path (`OddEvenFill` subpaths)
// with dimmed rectangles sitting exactly underneath them, so the hole edges
// antialias body-to-window instead of body-to-background — no seams.
//
// Exactly two tones, both derived from `color` by alpha alone so the glyph
// follows the theme (dark on light themes, light on dark ones):
//
//   signed in  — solid body, windows filled at `dimAlpha`
//   signed out — whole body at `dimAlpha`, windows left as cut-outs
//
// So the states differ twice over: overall weight AND internal fill. A
// diagonal slash (TailscaleIcon's `crossed`, and this icon's own previous
// cut) was tried here and rejected: at 11px the bar is thicker than the
// body's remaining solid area and swallows both windows, leaving a smudge
// with a stripe. Fading the whole glyph reads as "inactive" just as clearly
// and keeps the diskette recognisable, which is the point of the icon.
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground
  property bool loggedOut: false

  // The single dimmed tone. Used for the windows when signed in, and for the
  // entire body when signed out, so the icon never shows more than the two
  // permitted values of `color`.
  readonly property real dimAlpha: 0.38

  // Body outline, in fractions of iconSize. `chamfer` is the classic
  // clipped top-right corner; keep it well clear of `shutterX1` or the strip
  // of body between shutter and corner disappears at bar size.
  readonly property real bodyX0: 0.03
  readonly property real bodyX1: 0.97
  readonly property real bodyY0: 0.03
  readonly property real bodyY1: 0.97
  readonly property real chamfer: 0.24

  readonly property real shutterX0: 0.30
  readonly property real shutterX1: 0.63
  readonly property real shutterY1: 0.35

  // The label window stops short of the bottom edge on purpose. Running it
  // flush with `bodyY1` looks fine while it is filled, but in the signed-out
  // state the window becomes real negative space and an open-bottomed body
  // reads as an arch — an "H" — rather than as a diskette. The closed rim
  // keeps the silhouette a card in both states; verified at 11-18px.
  readonly property real labelX0: 0.20
  readonly property real labelX1: 0.80
  readonly property real labelY0: 0.56
  readonly property real labelY1: 0.87

  width: iconSize
  height: iconSize
  implicitWidth: width
  implicitHeight: height

  // Window fills, drawn under the body so the cut-outs read as a lighter
  // tone rather than as holes. Hidden when signed out, which turns the same
  // cut-outs into real negative space and makes the faded state unmistakable.
  Rectangle {
    visible: !root.loggedOut
    x: root.width * root.shutterX0
    y: root.height * root.bodyY0
    width: root.width * (root.shutterX1 - root.shutterX0)
    height: root.height * (root.shutterY1 - root.bodyY0)
    color: root.color
    opacity: root.dimAlpha
  }

  Rectangle {
    visible: !root.loggedOut
    x: root.width * root.labelX0
    y: root.height * root.labelY0
    width: root.width * (root.labelX1 - root.labelX0)
    height: root.height * (root.labelY1 - root.labelY0)
    color: root.color
    opacity: root.dimAlpha
  }

  Shape {
    id: body
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4
    opacity: root.loggedOut ? root.dimAlpha : 1.0

    ShapePath {
      fillColor: root.color
      strokeWidth: 0
      fillRule: ShapePath.OddEvenFill

      // Outer body, clockwise from the top-left corner.
      startX: body.width * root.bodyX0
      startY: body.height * root.bodyY0
      PathLine { x: body.width * (root.bodyX1 - root.chamfer); y: body.height * root.bodyY0 }
      PathLine { x: body.width * root.bodyX1; y: body.height * (root.bodyY0 + root.chamfer) }
      PathLine { x: body.width * root.bodyX1; y: body.height * root.bodyY1 }
      PathLine { x: body.width * root.bodyX0; y: body.height * root.bodyY1 }
      PathLine { x: body.width * root.bodyX0; y: body.height * root.bodyY0 }

      // Shutter window, flush with the top edge.
      PathMove { x: body.width * root.shutterX0; y: body.height * root.bodyY0 }
      PathLine { x: body.width * root.shutterX1; y: body.height * root.bodyY0 }
      PathLine { x: body.width * root.shutterX1; y: body.height * root.shutterY1 }
      PathLine { x: body.width * root.shutterX0; y: body.height * root.shutterY1 }
      PathLine { x: body.width * root.shutterX0; y: body.height * root.bodyY0 }

      // Label window, held off the bottom edge by a rim.
      PathMove { x: body.width * root.labelX0; y: body.height * root.labelY0 }
      PathLine { x: body.width * root.labelX1; y: body.height * root.labelY0 }
      PathLine { x: body.width * root.labelX1; y: body.height * root.labelY1 }
      PathLine { x: body.width * root.labelX0; y: body.height * root.labelY1 }
      PathLine { x: body.width * root.labelX0; y: body.height * root.labelY0 }
    }
  }
}
