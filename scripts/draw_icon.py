# Draws the Clicky Study icon at 1024 px: the tutor's blue cursor pointing at a
# hand-drawn diagram on squared paper, on a dark macOS squircle.
import math, random, sys
from AppKit import (NSImage, NSBezierPath, NSColor, NSGraphicsContext, NSBitmapImageRep,
                    NSPNGFileType, NSAffineTransform, NSShadow, NSGradient, NSMakeRect, NSMakePoint, NSMakeSize)

random.seed(7)
S = 1024
out = sys.argv[1]

def rgb(h, a=1.0):
    h = h.lstrip('#'); return NSColor.colorWithSRGBRed_green_blue_alpha_(int(h[0:2],16)/255, int(h[2:4],16)/255, int(h[4:6],16)/255, a)

def wobbly(points, closed=False, jitter=3.0):
    """A pen line through points, with the slight wobble of a hand."""
    path = NSBezierPath.bezierPath()
    pts = [(x + random.uniform(-jitter, jitter), y + random.uniform(-jitter, jitter)) for x, y in points]
    path.moveToPoint_(NSMakePoint(*pts[0]))
    for i in range(1, len(pts)):
        x0, y0 = pts[i-1]; x1, y1 = pts[i]
        mx, my = (x0+x1)/2 + random.uniform(-jitter, jitter), (y0+y1)/2 + random.uniform(-jitter, jitter)
        path.curveToPoint_controlPoint1_controlPoint2_(NSMakePoint(x1, y1), NSMakePoint(mx, my), NSMakePoint(mx, my))
    if closed: path.closePath()
    return path

def hand_rect(x, y, w, h):
    return wobbly([(x, y), (x+w, y+2), (x+w-1, y+h), (x+1, y+h-1), (x+2, y+4)], jitter=3.5)

image = NSImage.alloc().initWithSize_(NSMakeSize(S, S))
image.lockFocus()
ctx = NSGraphicsContext.currentContext()
ctx.setShouldAntialias_(True)

# Squircle tile, macOS icon grid: 824 px with 100 px margin.
tile = NSMakeRect(100, 100, 824, 824)
shadow = NSShadow.alloc().init(); shadow.setShadowColor_(rgb('#000000', 0.45)); shadow.setShadowBlurRadius_(28); shadow.setShadowOffset_(NSMakeSize(0, -12))
NSGraphicsContext.saveGraphicsState(); shadow.set()
squircle = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(tile, 185, 185)
rgb('#10131A').setFill(); squircle.fill()
NSGraphicsContext.restoreGraphicsState()
NSGradient.alloc().initWithStartingColor_endingColor_(rgb('#1E2533'), rgb('#0B0D12')).drawInBezierPath_angle_(squircle, -90)

# Sheet of squared paper, tilted a little.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
t = NSAffineTransform.transform(); t.translateXBy_yBy_(512, 548); t.rotateByDegrees_(-7); t.concat()
paper_rect = NSMakeRect(-300, -230, 600, 460)
paper_shadow = NSShadow.alloc().init(); paper_shadow.setShadowColor_(rgb('#000000', 0.5)); paper_shadow.setShadowBlurRadius_(30); paper_shadow.setShadowOffset_(NSMakeSize(6, -16))
NSGraphicsContext.saveGraphicsState(); paper_shadow.set()
paper = NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(paper_rect, 34, 34)
rgb('#F8F2E4').setFill(); paper.fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState(); paper.addClip()
rgb('#3C5078', 0.10).setStroke()
for gx in range(-300, 301, 40):
    l = NSBezierPath.bezierPath(); l.moveToPoint_(NSMakePoint(gx, -230)); l.lineToPoint_(NSMakePoint(gx, 230)); l.setLineWidth_(2); l.stroke()
for gy in range(-230, 231, 40):
    l = NSBezierPath.bezierPath(); l.moveToPoint_(NSMakePoint(-300, gy)); l.lineToPoint_(NSMakePoint(300, gy)); l.setLineWidth_(2); l.stroke()
NSGraphicsContext.restoreGraphicsState()

# Three boxes joined by arrows, the middle one washed blue: a lesson's diagram.
ink = rgb('#2B2D33')
boxes = [(-250, -50, 130, 100), (-65, -50, 130, 100), (120, -50, 130, 100)]
fills = [rgb('#BFD9FA', 0.9), rgb('#9EC5FA', 0.95), rgb('#C6EBD3', 0.9)]
for (x, y, w, h), fill in zip(boxes, fills):
    fill.setFill(); NSBezierPath.bezierPathWithRoundedRect_xRadius_yRadius_(NSMakeRect(x+4, y+4, w-8, h-8), 10, 10).fill()
    p = hand_rect(x, y, w, h); p.setLineWidth_(9); p.setLineCapStyle_(1); p.setLineJoinStyle_(1); ink.setStroke(); p.stroke()
for x0 in (-120, 65):
    a = wobbly([(x0 + 6, 0), (x0 + 34, 2), (x0 + 50, 0)], jitter=1.5); a.setLineWidth_(8); a.setLineCapStyle_(1); a.stroke()
    head = wobbly([(x0 + 34, 16), (x0 + 52, 0), (x0 + 34, -16)], jitter=1.0); head.setLineWidth_(8); head.setLineCapStyle_(1); head.setLineJoinStyle_(1); head.stroke()
# A heading scribble above, like handwriting.
for i, (wx, ww) in enumerate([(-250, 210), (-20, 120)]):
    s = wobbly([(wx + k * ww / 6, 150 + (6 if k % 2 else -6)) for k in range(7)], jitter=2.5); s.setLineWidth_(10); s.setLineCapStyle_(1); rgb('#2B2D33', 0.8).setStroke(); s.stroke()
s = wobbly([(-250 + k * 280 / 8, -140 + (5 if k % 2 else -5)) for k in range(9)], jitter=2.5); s.setLineWidth_(9); s.setLineCapStyle_(1); rgb('#7D828C', 0.8).setStroke(); s.stroke()

# The tutor's blue ring around the middle box, drawn in one loose stroke.
ring = NSBezierPath.bezierPath()
cx, cy, rx, ry = 0, 0, 115, 82
for i in range(0, 58):
    ang = -2.3 + i / 56 * math.pi * 2 * 1.08
    px, py = cx + math.cos(ang) * rx * (1 + math.sin(i * 0.7) * 0.02), cy + math.sin(ang) * ry * (1 + math.sin(i * 0.9) * 0.025)
    (ring.moveToPoint_ if i == 0 else ring.lineToPoint_)(NSMakePoint(px, py))
glow = NSShadow.alloc().init(); glow.setShadowColor_(rgb('#3380FF', 0.9)); glow.setShadowBlurRadius_(18); glow.setShadowOffset_(NSMakeSize(0, 0))
NSGraphicsContext.saveGraphicsState(); glow.set()
ring.setLineWidth_(13); ring.setLineCapStyle_(1); ring.setLineJoinStyle_(1); rgb('#3380FF').setStroke(); ring.stroke()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.restoreGraphicsState()

# The cursor, bottom right, pointing up at the ring.
NSGraphicsContext.saveGraphicsState()
t2 = NSAffineTransform.transform(); t2.translateXBy_yBy_(690, 300); t2.rotateByDegrees_(35); t2.concat()
cursor = NSBezierPath.bezierPath()
cursor.moveToPoint_(NSMakePoint(0, 120)); cursor.lineToPoint_(NSMakePoint(-78, -70)); cursor.lineToPoint_(NSMakePoint(0, -30)); cursor.lineToPoint_(NSMakePoint(78, -70)); cursor.closePath()
cglow = NSShadow.alloc().init(); cglow.setShadowColor_(rgb('#3380FF', 0.95)); cglow.setShadowBlurRadius_(40); cglow.setShadowOffset_(NSMakeSize(0, 0))
NSGraphicsContext.saveGraphicsState(); cglow.set(); rgb('#3380FF').setFill(); cursor.fill(); NSGraphicsContext.restoreGraphicsState()
NSGradient.alloc().initWithStartingColor_endingColor_(rgb('#6BA4FF'), rgb('#2D6FF0')).drawInBezierPath_angle_(cursor, -90)
cursor.setLineWidth_(5); rgb('#FFFFFF', 0.85).setStroke(); cursor.stroke()
NSGraphicsContext.restoreGraphicsState()

image.unlockFocus()
rep = NSBitmapImageRep.imageRepWithData_(image.TIFFRepresentation())
rep.representationUsingType_properties_(NSPNGFileType, None).writeToFile_atomically_(out, True)
print("drew", out)
