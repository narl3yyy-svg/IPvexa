.pragma library
// Free-form layout model, Nx-style: a grid of cols x rows cells; each item shows one
// camera and covers a w x h block of cells. Pure functions on plain objects so they can
// be unit-tested without the UI. Every mutating function takes a layout and returns a
// NEW layout (or the same one when the change isn't allowed).
//
// layout = { name, cols, rows, aspect: "16:9"|"4:3"|"Fill", items: [{cam, x, y, w, h}],
//            cw: [column widths], rh: [row heights]   (optional relative sizes; equal if absent)
//            fit: "fit"|"fill"|"stretch" }             (how video fills its tile; "fit" if absent)

var MAX_GRID = 12

function clone(o) { return JSON.parse(JSON.stringify(o)) }

function make(name, cols, rows) {
    return { name: name, cols: cols || 2, rows: rows || 2, aspect: "16:9", items: [] }
}

function overlaps(a, b) {
    return a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
}

function inside(l, r) {
    return r.x >= 0 && r.y >= 0 && r.w >= 1 && r.h >= 1 && r.x + r.w <= l.cols && r.y + r.h <= l.rows
}

// Index of the item covering cell (x, y), or -1.
function itemAt(l, x, y) {
    for (var i = 0; i < l.items.length; i++) {
        var it = l.items[i]
        if (x >= it.x && x < it.x + it.w && y >= it.y && y < it.y + it.h) return i
    }
    return -1
}

// True if rect r is inside the grid and overlaps no item except those listed in ignore.
function fits(l, r, ignore) {
    if (!inside(l, r)) return false
    for (var i = 0; i < l.items.length; i++) {
        if (ignore && ignore.indexOf(i) >= 0) continue
        if (overlaps(r, l.items[i])) return false
    }
    return true
}

function firstFree(l) {
    for (var y = 0; y < l.rows; y++)
        for (var x = 0; x < l.cols; x++)
            if (itemAt(l, x, y) < 0) return { x: x, y: y }
    return null
}

// Free cells, in reading order (drawn as empty drop targets).
function freeCells(l) {
    var out = []
    for (var y = 0; y < l.rows; y++)
        for (var x = 0; x < l.cols; x++)
            if (itemAt(l, x, y) < 0) out.push({ x: x, y: y })
    return out
}

function indexOfCam(l, cam) {
    for (var i = 0; i < l.items.length; i++) if (l.items[i].cam === cam) return i
    return -1
}

// Grow the grid by one row or column, keeping it roughly square.
function grow(l) {
    var n = clone(l)
    if (n.cols <= n.rows && n.cols < MAX_GRID) n.cols++
    else if (n.rows < MAX_GRID) n.rows++
    else if (n.cols < MAX_GRID) n.cols++
    return n
}

// Put a camera on the layout. With (x, y): on that cell, replacing whatever camera is
// there. Without: on the first free cell, growing the grid if it's full.
// A camera already on the layout is moved rather than duplicated.
function addCamera(l, cam, x, y) {
    var n = clone(l)
    var existing = indexOfCam(n, cam)
    if (x === undefined || x === null) {
        if (existing >= 0) return n
        var free = firstFree(n)
        while (!free && (n.cols < MAX_GRID || n.rows < MAX_GRID)) {
            n = grow(n)
            free = firstFree(n)
        }
        if (!free) return n
        n.items.push({ cam: cam, x: free.x, y: free.y, w: 1, h: 1 })
        return n
    }
    if (existing >= 0) return moveItem(n, existing, x, y)
    var target = itemAt(n, x, y)
    if (target >= 0) {
        // A different camera: drop the old tile's zoom and quality settings.
        var t = n.items[target]
        n.items[target] = { cam: cam, x: t.x, y: t.y, w: t.w, h: t.h }
        return n
    }
    n.items.push({ cam: cam, x: x, y: y, w: 1, h: 1 })
    return n
}

// Add a second tile of item idx's camera on the first free cell (growing the grid
// if needed), keeping its digital zoom: "open the zoomed area as its own tile".
function duplicateItem(l, idx) {
    var n = clone(l)
    if (idx < 0 || idx >= n.items.length) return n
    var src = n.items[idx]
    var free = firstFree(n)
    while (!free && (n.cols < MAX_GRID || n.rows < MAX_GRID)) {
        n = grow(n)
        free = firstFree(n)
    }
    if (!free) return n
    var it = { cam: src.cam, x: free.x, y: free.y, w: 1, h: 1 }
    if (src.z) it.z = clone(src.z)
    if (src.q) it.q = src.q
    n.items.push(it)
    return n
}

// Digital zoom of item idx: z = { zoom, x, y } (centre as fractions), or null for none.
function setZoom(l, idx, z) {
    var n = clone(l)
    if (idx < 0 || idx >= n.items.length) return n
    if (z && z.zoom > 1.01) n.items[idx].z = { zoom: z.zoom, x: z.x, y: z.y }
    else delete n.items[idx].z
    return n
}

function removeItem(l, idx) {
    var n = clone(l)
    if (idx >= 0 && idx < n.items.length) n.items.splice(idx, 1)
    return n
}

// Move item idx so its top-left is (x, y). Dropping onto another item swaps the two.
function moveItem(l, idx, x, y) {
    var n = clone(l)
    if (idx < 0 || idx >= n.items.length) return n
    var it = n.items[idx]
    var target = itemAt(n, x, y)
    if (target === idx) return n
    if (target >= 0) {
        var t = n.items[target]
        var a = { x: it.x, y: it.y, w: it.w, h: it.h }
        it.x = t.x; it.y = t.y; it.w = t.w; it.h = t.h
        t.x = a.x; t.y = a.y; t.w = a.w; t.h = a.h
        return n
    }
    // Empty cell: keep the size if it fits there, otherwise shrink to fit.
    var w = Math.min(it.w, n.cols - x), h = Math.min(it.h, n.rows - y)
    for (; h >= 1; h--) {
        for (var ww = w; ww >= 1; ww--) {
            var r = { x: x, y: y, w: ww, h: h }
            if (fits(n, r, [idx])) {
                it.x = x; it.y = y; it.w = ww; it.h = h
                return n
            }
        }
    }
    return clone(l)
}

// Resize item idx to w x h cells (keeping its top-left). Refused if it would overlap.
function resizeItem(l, idx, w, h) {
    var n = clone(l)
    if (idx < 0 || idx >= n.items.length) return n
    var it = n.items[idx]
    w = Math.max(1, Math.min(w, n.cols - it.x))
    h = Math.max(1, Math.min(h, n.rows - it.y))
    if (!fits(n, { x: it.x, y: it.y, w: w, h: h }, [idx])) return clone(l)
    it.w = w; it.h = h
    return n
}

// Smallest grid that still holds every item.
function minGrid(l) {
    var c = 1, r = 1
    for (var i = 0; i < l.items.length; i++) {
        c = Math.max(c, l.items[i].x + l.items[i].w)
        r = Math.max(r, l.items[i].y + l.items[i].h)
    }
    return { cols: c, rows: r }
}

function setGrid(l, cols, rows) {
    var n = clone(l), m = minGrid(l)
    n.cols = Math.max(m.cols, Math.min(MAX_GRID, cols))
    n.rows = Math.max(m.rows, Math.min(MAX_GRID, rows))
    // Custom column/row sizes no longer match: go back to equal sizes.
    if (n.cols !== l.cols) delete n.cw
    if (n.rows !== l.rows) delete n.rh
    return n
}

// Relative column widths ("cols") or row heights ("rows"), summing to 1.
function sizes(l, axis) {
    var count = axis === "cols" ? l.cols : l.rows
    var w = axis === "cols" ? l.cw : l.rh
    var out = [], sum = 0, i
    for (i = 0; i < count; i++) {
        var v = w && w.length === count && w[i] > 0 ? w[i] : 1
        out.push(v); sum += v
    }
    for (i = 0; i < count; i++) out[i] /= sum
    return out
}

// Start offsets of each column/row plus the end (count + 1 values, 0 … 1).
function edges(l, axis) {
    var s = sizes(l, axis), out = [0], acc = 0
    for (var i = 0; i < s.length; i++) { acc += s[i]; out.push(acc) }
    out[out.length - 1] = 1
    return out
}

// Smallest share a column or row can be dragged down to (of an equal share).
var MIN_SHARE = 0.25

// Move the border between column/row i-1 and i to position pos (0 … 1).
function moveBorder(l, axis, i, pos) {
    var count = axis === "cols" ? l.cols : l.rows
    if (i <= 0 || i >= count) return l
    var s = sizes(l, axis), e = edges(l, axis)
    var min = MIN_SHARE / count
    var lo = e[i - 1] + min, hi = e[i + 1] - min
    if (hi <= lo) return l
    pos = Math.max(lo, Math.min(hi, pos))
    s[i - 1] = pos - e[i - 1]
    s[i] = e[i + 1] - pos
    var n = clone(l)
    var rounded = s.map(function (v) { return Math.round(v * 10000) / 10000 })
    if (axis === "cols") n.cw = rounded; else n.rh = rounded
    return n
}

// Equal column and row sizes again.
function evenSizes(l) {
    var n = clone(l)
    delete n.cw
    delete n.rh
    return n
}

function hasCustomSizes(l) { return !!(l.cw || l.rh) }

// Draggable borders: for each inner column (axis "cols") or row border, the runs
// of cells along it where no tile spans across. [{ i, from, to }] in cells.
function borderSegments(l, axis) {
    var out = []
    var count = axis === "cols" ? l.cols : l.rows, along = axis === "cols" ? l.rows : l.cols
    for (var i = 1; i < count; i++) {
        var from = -1
        for (var j = 0; j <= along; j++) {
            var open = false
            if (j < along) {
                var a = axis === "cols" ? itemAt(l, i - 1, j) : itemAt(l, j, i - 1)
                var b = axis === "cols" ? itemAt(l, i, j) : itemAt(l, j, i)
                open = a !== b || a < 0
            }
            if (open && from < 0) from = j
            if (!open && from >= 0) { out.push({ i: i, from: from, to: j }); from = -1 }
        }
    }
    return out
}

// How video fills each tile: "fit" (whole picture, black bars), "fill" (crop the
// edges so the tile is filled: "maximize frames") or "stretch".
function setFit(l, fit) {
    var n = clone(l)
    if (fit === "fill" || fit === "stretch") n.fit = fit
    else delete n.fit
    return n
}

function greatestCommonDivisor(a, b) { return b === 0 ? a : greatestCommonDivisor(b, a % b) }
function leastCommonMultiple(a, b) { return a / greatestCommonDivisor(a, b) * b }

// Rows of tiles that fill the whole screen with k cameras and no empty space:
// e.g. 5 cameras = 2 on top and 3 below, on a 6-column grid (tiles 3 and 2 wide).
function fillSlots(k) {
    if (k <= 0) return { cols: 1, rows: 1, slots: [] }
    var start = Math.max(1, Math.round(Math.sqrt(k)))
    var tries = [start]
    for (var d = 1; d <= k; d++) { tries.push(start + d); if (start - d >= 1) tries.push(start - d) }
    for (var t = 0; t < tries.length; t++) {
        var r = tries[t]
        if (r > k || r > MAX_GRID) continue
        var base = Math.floor(k / r), extra = k % r
        var counts = []
        for (var y = 0; y < r; y++) counts.push(base + (y >= r - extra ? 1 : 0)) // more tiles in the lower rows
        var cols = 1
        for (var j = 0; j < counts.length; j++) cols = leastCommonMultiple(cols, counts[j])
        if (cols > MAX_GRID) continue
        var slots = []
        for (var yy = 0; yy < r; yy++) {
            var w = cols / counts[yy]
            for (var x = 0; x < counts[yy]; x++) slots.push({ x: x * w, y: yy, w: w, h: 1 })
        }
        return { cols: cols, rows: r, slots: slots }
    }
    return presetSlots("4x4")
}

// Re-arrange the layout's cameras (in their current order) to fill the screen.
// Uneven rows need tiles of different widths, so the tiles then stretch to the
// screen ("Fill"); cropping the video ("maximize frames") hides the black bars.
function fillScreen(l) {
    var n = clone(l)
    var old = n.items.slice().sort(function (a, b) { return a.y - b.y || a.x - b.x })
    var fs = fillSlots(old.length)
    n.cols = fs.cols; n.rows = fs.rows; n.items = []
    delete n.cw
    delete n.rh
    var uneven = false
    for (var i = 0; i < old.length && i < fs.slots.length; i++) {
        var s = fs.slots[i]
        if (s.w !== 1) uneven = true
        var it = { cam: old[i].cam, x: s.x, y: s.y, w: s.w, h: s.h }
        if (old[i].q) it.q = old[i].q
        if (old[i].z) it.z = old[i].z
        n.items.push(it)
    }
    if (uneven) n.aspect = "Fill"
    return n
}

// Preset grids. Big presets start with one large tile in the top-left.
var PRESETS = ["1", "2x2", "3x3", "4x4", "1+5", "1+7", "1+12"]

function presetSlots(p) {
    var cols, big = 0
    switch (p) {
    case "1": cols = 1; break
    case "3x3": cols = 3; break
    case "4x4": cols = 4; break
    case "1+5": cols = 3; big = 2; break
    case "1+7": cols = 4; big = 3; break
    case "1+12": cols = 4; big = 2; break
    default: cols = 2
    }
    var slots = []
    if (big > 0) slots.push({ x: 0, y: 0, w: big, h: big })
    for (var y = 0; y < cols; y++)
        for (var x = 0; x < cols; x++)
            if (!(x < big && y < big)) slots.push({ x: x, y: y, w: 1, h: 1 })
    return { cols: cols, rows: cols, slots: slots }
}

// Re-arrange the layout's cameras (in their current order) into a preset.
function applyPreset(l, p) {
    var n = clone(l), ps = presetSlots(p)
    var old = n.items.slice().sort(function (a, b) { return a.y - b.y || a.x - b.x })
    n.cols = ps.cols; n.rows = ps.rows; n.items = []
    for (var i = 0; i < old.length && i < ps.slots.length; i++) {
        var s = ps.slots[i]
        var it = { cam: old[i].cam, x: s.x, y: s.y, w: s.w, h: s.h }
        if (old[i].q) it.q = old[i].q
        if (old[i].z) it.z = old[i].z
        n.items.push(it)
    }
    return n
}

// Per-tile stream quality: "" (follow the layout), "high" or "low".
function setQuality(l, idx, q) {
    var n = clone(l)
    if (idx < 0 || idx >= n.items.length) return n
    if (q === "high" || q === "low") n.items[idx].q = q
    else delete n.items[idx].q
    return n
}

// A sensible first layout for a list of camera ids: every camera, no empty tiles.
function autoLayout(name, cams) {
    var l = make(name, 2, 2)
    l.items = cams.map(function (c, i) { return { cam: c, x: i, y: 0, w: 1, h: 1 } })
    return fillScreen(l)
}

// Convert a layout saved by version 0.1 ({preset, cams[]}).
function migrate(old) {
    if (old && old.items) return old
    var l = make(old && old.name ? old.name : "Layout", 2, 2)
    l.aspect = old && old.aspect ? old.aspect : "16:9"
    var ps = presetSlots(old && old.preset ? old.preset : "2x2")
    l.cols = ps.cols; l.rows = ps.rows
    var cams = old && old.cams ? old.cams : []
    for (var i = 0; i < cams.length && i < ps.slots.length; i++)
        if (cams[i] > 0) {
            var s = ps.slots[i]
            l.items.push({ cam: cams[i], x: s.x, y: s.y, w: s.w, h: s.h })
        }
    return l
}
