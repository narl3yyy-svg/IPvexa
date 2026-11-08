.pragma library

// Motion grid helpers, matching the server's package motion: a 16×9 grid, cell
// i = (i % 16, floor(i / 16)), encoded as hex with cell 0 in the top bit of byte 0.

var COLS = 16
var ROWS = 9
var N = COLS * ROWS

function empty() {
    var a = []
    for (var i = 0; i < N; i++) a.push(false)
    return a
}

function decode(hex) {
    var a = empty()
    if (!hex) return a
    for (var i = 0; i < N; i++) {
        var byte = parseInt(hex.substr(Math.floor(i / 8) * 2, 2), 16)
        if (!isNaN(byte) && (byte & (1 << (7 - i % 8)))) a[i] = true
    }
    return a
}

function encode(cells) {
    var out = ""
    for (var b = 0; b < N / 8; b++) {
        var byte = 0
        for (var k = 0; k < 8; k++) if (cells[b * 8 + k]) byte |= 1 << (7 - k)
        out += (byte < 16 ? "0" : "") + byte.toString(16)
    }
    return out
}

function count(cells) {
    var n = 0
    for (var i = 0; i < cells.length; i++) if (cells[i]) n++
    return n
}

// Cells covered by a rectangle given as fractions (0…1) of the picture.
function fromRect(x0, y0, x1, y1) {
    var a = empty()
    var cx0 = Math.max(0, Math.floor(Math.min(x0, x1) * COLS)), cx1 = Math.min(COLS - 1, Math.floor(Math.max(x0, x1) * COLS - 1e-9))
    var cy0 = Math.max(0, Math.floor(Math.min(y0, y1) * ROWS)), cy1 = Math.min(ROWS - 1, Math.floor(Math.max(y0, y1) * ROWS - 1e-9))
    for (var y = cy0; y <= cy1; y++)
        for (var x = cx0; x <= cx1; x++) a[y * COLS + x] = true
    return a
}
