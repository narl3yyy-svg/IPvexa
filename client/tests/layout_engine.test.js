// Unit tests for qml/LayoutEngine.js. Run with: build/layout_tests
var failures = 0, passed = 0
function check(name, cond) {
    if (cond) passed++
    else { failures++; print("FAIL: " + name) }
}
function at(l, cam) { for (var i = 0; i < l.items.length; i++) if (l.items[i].cam === cam) return l.items[i]; return null }

// addCamera fills free cells in reading order and grows the grid when full
var l = make("t", 2, 2)
l = addCamera(l, 1); l = addCamera(l, 2); l = addCamera(l, 3); l = addCamera(l, 4)
check("four cams fill 2x2", l.items.length === 4 && l.cols === 2 && l.rows === 2)
check("reading order", at(l, 2).x === 1 && at(l, 2).y === 0 && at(l, 3).x === 0 && at(l, 3).y === 1)
l = addCamera(l, 5)
check("grid grows when full", l.cols * l.rows > 4 && at(l, 5) !== null)
check("no duplicate when re-adding", addCamera(l, 5).items.length === l.items.length)

// moving onto another tile swaps them
var s = make("s", 2, 2)
s = addCamera(s, 1); s = addCamera(s, 2)
s = moveItem(s, 0, 1, 0)
check("swap moves cam1 right", at(s, 1).x === 1 && at(s, 2).x === 0)

// moving to an empty cell
var m = make("m", 3, 3)
m = addCamera(m, 1)
m = moveItem(m, 0, 2, 2)
check("move to empty cell", at(m, 1).x === 2 && at(m, 1).y === 2)

// a big tile shrinks to fit near the edge
var b = make("b", 3, 3)
b = addCamera(b, 1)
b = resizeItem(b, 0, 2, 2)
check("resize to 2x2", at(b, 1).w === 2 && at(b, 1).h === 2)
b = moveItem(b, 0, 2, 2)
check("2x2 moved to corner shrinks to 1x1", at(b, 1).x === 2 && at(b, 1).y === 2 && at(b, 1).w === 1)

// resize is refused when it would overlap another tile
var r = make("r", 2, 2)
r = addCamera(r, 1); r = addCamera(r, 2)
var r2 = resizeItem(r, 0, 2, 1)
check("overlapping resize refused", at(r2, 1).w === 1)
check("resize clamps to grid", resizeItem(make("c", 2, 2), -1, 5, 5).items.length === 0)

// dropping a new camera onto a tile replaces it; dropping an existing one moves it
var d = make("d", 2, 2)
d = addCamera(d, 1); d = addCamera(d, 2)
d = addCamera(d, 9, 0, 0)
check("drop replaces camera", at(d, 9) !== null && at(d, 1) === null && d.items.length === 2)
d = addCamera(d, 2, 0, 0)
check("drop existing camera swaps", at(d, 2).x === 0 && at(d, 9).x === 1)

// remove
check("remove item", removeItem(d, 0).items.length === 1)

// grid can't shrink below its items
var g = make("g", 3, 3)
g = addCamera(g, 1, 2, 2)
g = setGrid(g, 1, 1)
check("setGrid keeps items", g.cols === 3 && g.rows === 3)
check("setGrid grows", setGrid(make("h", 2, 2), 4, 3).cols === 4)

// presets keep cameras in reading order
var p = make("p", 2, 2)
p = addCamera(p, 1); p = addCamera(p, 2); p = addCamera(p, 3)
p = applyPreset(p, "1+5")
check("1+5 big tile first", at(p, 1).w === 2 && at(p, 1).h === 2 && p.cols === 3)
check("1+5 others 1x1", at(p, 2).w === 1 && at(p, 3).w === 1)

// migration from 0.1 layouts
var old = { name: "Default", preset: "2x2", aspect: "Fill", cams: [4, 3, 0, 0] }
var mg = migrate(old)
check("migrate keeps cams", mg.items.length === 2 && at(mg, 4).x === 0 && at(mg, 3).x === 1 && mg.aspect === "Fill")
check("autoLayout fills the screen", autoLayout("a", [1, 2, 3, 4, 5]).items.length === 5 && freeCells(autoLayout("a", [1, 2, 3, 4, 5])).length === 0)

// freeCells
check("freeCells", freeCells(addCamera(make("f", 2, 2), 1)).length === 3)

// per-tile quality survives moves and presets, and can be cleared
var qq = addCamera(addCamera(make("q", 2, 2), 1), 2)
qq = setQuality(qq, 0, "high")
check("setQuality sets", qq.items[0].q === "high")
qq = moveItem(qq, 0, 1, 1)
check("quality survives move", at(qq, 1).q === "high")
qq = applyPreset(qq, "3x3")
check("quality survives preset", at(qq, 1).q === "high" && at(qq, 2).q === undefined)
qq = setQuality(qq, qq.items.indexOf(at(qq, 1)), "")
check("quality cleared", at(qq, 1).q === undefined)

// digital zoom is saved per tile, copied by duplicateItem, dropped when the camera changes
var zz = addCamera(make("z", 1, 1), 5)
zz = setZoom(zz, 0, { zoom: 3, x: 0.2, y: 0.7 })
check("setZoom", zz.items[0].z.zoom === 3)
zz = duplicateItem(zz, 0)
check("duplicate keeps zoom and grows grid", zz.items.length === 2 && zz.items[1].cam === 5 && zz.items[1].z.x === 0.2 && zz.cols * zz.rows >= 2)
zz = addCamera(zz, 9, zz.items[1].x, zz.items[1].y)
check("replacing a tile's camera clears its zoom", zz.items[1].cam === 9 && zz.items[1].z === undefined)
check("setZoom(1) clears", setZoom(zz, 0, { zoom: 1, x: 0.5, y: 0.5 }).items[0].z === undefined)

// fill the screen: no empty cells for any camera count, nothing overlaps
for (var k = 1; k <= 24; k++) {
    var cams = []
    for (var c = 1; c <= k; c++) cams.push(c)
    var f = autoLayout("f", cams)
    var ok = f.items.length === k && freeCells(f).length === 0 && f.cols <= MAX_GRID && f.rows <= MAX_GRID
    for (var a = 0; a < f.items.length && ok; a++)
        for (var b = a + 1; b < f.items.length; b++) if (overlaps(f.items[a], f.items[b])) ok = false
    check("fill screen with " + k + " cameras", ok)
}
var five = fillScreen(addCamera(addCamera(addCamera(addCamera(addCamera(make("5", 3, 3), 1), 2), 3), 4), 5))
check("5 cameras: 2 on top, 3 below", five.rows === 2 && five.cols === 6 && at(five, 1).w === 3 && at(five, 3).w === 2 && five.aspect === "Fill")
check("4 cameras stay a 2x2 grid", fillScreen(autoLayout("x", [1, 2, 3, 4])).cols === 2 && autoLayout("x", [1, 2, 3, 4]).aspect === "16:9")

// column and row sizes
var g = make("g", 3, 2)
var e0 = edges(g, "cols")
check("equal sizes by default", Math.abs(e0[1] - 1 / 3) < 1e-9 && e0[3] === 1)
g = moveBorder(g, "cols", 1, 0.5)
check("moveBorder widens column 0", Math.abs(sizes(g, "cols")[0] - 0.5) < 1e-3 && Math.abs(sizes(g, "cols")[2] - 1 / 3) < 1e-3)
g = moveBorder(g, "cols", 1, 0.99)
check("moveBorder keeps a minimum width", sizes(g, "cols")[1] >= MIN_SHARE / 3 - 1e-3)
check("moveBorder ignores the outer edges", moveBorder(g, "cols", 0, 0.2) === g && moveBorder(g, "cols", 3, 0.2) === g)
check("adding a column resets widths", setGrid(g, 4, 2).cw === undefined && setGrid(g, 3, 3).cw !== undefined)
check("evenSizes", !hasCustomSizes(evenSizes(moveBorder(g, "rows", 1, 0.3))) && hasCustomSizes(g))

// draggable borders skip tiles that span across them
var bs = borderSegments(five, "cols")
check("borders between tiles only", bs.length === 3 && bs[0].i === 2 && bs[0].from === 1 && bs[0].to === 2 && bs[1].i === 3 && bs[1].from === 0 && bs[1].to === 1)
check("row border runs the full width", borderSegments(five, "rows").length === 1 && borderSegments(five, "rows")[0].to === 6)

// maximize frames
check("setFit fill", setFit(g, "fill").fit === "fill" && setFit(setFit(g, "fill"), "fit").fit === undefined)

print("layout engine: " + passed + " passed, " + failures + " failed")
failures
