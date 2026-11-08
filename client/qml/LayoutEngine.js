.pragma library
// Free-form layout model, Nx-style: a grid of cols x rows cells; each item shows one
// camera and covers a w x h block of cells. Pure functions on plain objects so they can
// be unit-tested without the UI. Every mutating function takes a layout and returns a
// NEW layout (or the same one when the change isn't allowed).
//
// layout = { name, cols, rows, aspect: "16:9"|"4:3"|"Fill", items: [{cam, x, y, w, h}] }

var MAX_GRID = 8

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

// A sensible first layout for a list of camera ids.
function autoLayout(name, cams) {
    var k = cams.length
    var p = k <= 1 ? "1" : k <= 4 ? "2x2" : k <= 6 ? "1+5" : k <= 9 ? "3x3" : k <= 13 ? "1+12" : "4x4"
    var l = make(name, 2, 2)
    l.items = cams.map(function (c, i) { return { cam: c, x: i, y: 0, w: 1, h: 1 } })
    return applyPreset(l, p)
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
