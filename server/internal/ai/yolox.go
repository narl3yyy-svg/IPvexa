package ai

import (
	"math"
	"sort"
)

// The detector uses a YOLOX model (Apache-2.0, Megvii) trained on the COCO data
// set: 80 kinds of object, of which IPvexa uses people, vehicles and animals.

// Group is the kind of object that motion can be limited to.
type Group string

const (
	People   Group = "person"
	Vehicles Group = "vehicle"
	Animals  Group = "animal"
)

// cocoNames are the model's 80 classes, in order.
var cocoNames = [80]string{
	"person", "bicycle", "car", "motorcycle", "airplane", "bus", "train", "truck", "boat", "traffic light",
	"fire hydrant", "stop sign", "parking meter", "bench", "bird", "cat", "dog", "horse", "sheep", "cow",
	"elephant", "bear", "zebra", "giraffe", "backpack", "umbrella", "handbag", "tie", "suitcase", "frisbee",
	"skis", "snowboard", "sports ball", "kite", "baseball bat", "baseball glove", "skateboard", "surfboard", "tennis racket", "bottle",
	"wine glass", "cup", "fork", "knife", "spoon", "bowl", "banana", "apple", "sandwich", "orange",
	"broccoli", "carrot", "hot dog", "pizza", "donut", "cake", "chair", "couch", "potted plant", "bed",
	"dining table", "toilet", "tv", "laptop", "mouse", "remote", "keyboard", "cell phone", "microwave", "oven",
	"toaster", "sink", "refrigerator", "book", "clock", "vase", "scissors", "teddy bear", "hair drier", "toothbrush",
}

// GroupOf returns the group of a COCO class name ("" for objects IPvexa ignores).
func GroupOf(label string) Group {
	switch label {
	case "person":
		return People
	case "bicycle", "car", "motorcycle", "bus", "truck", "train", "boat":
		return Vehicles
	case "bird", "cat", "dog", "horse", "sheep", "cow", "elephant", "bear", "zebra", "giraffe":
		return Animals
	}
	return ""
}

// Box is a rectangle as fractions (0…1) of the picture's width and height.
type Box struct{ X, Y, W, H float64 }

// IoU is how much two boxes overlap: the shared area over the combined area.
func (a Box) IoU(b Box) float64 {
	x1, y1 := math.Max(a.X, b.X), math.Max(a.Y, b.Y)
	x2, y2 := math.Min(a.X+a.W, b.X+b.W), math.Min(a.Y+a.H, b.Y+b.H)
	if x2 <= x1 || y2 <= y1 {
		return 0
	}
	inter := (x2 - x1) * (y2 - y1)
	return inter / (a.W*a.H + b.W*b.H - inter)
}

// Object is one thing found in a picture.
type Object struct {
	Label string  `json:"label"` // COCO class, e.g. "person", "car", "dog"
	Score float64 `json:"score"` // 0…1
	Box   Box     `json:"box"`
}

// Group is the object's group.
func (o Object) Group() Group { return GroupOf(o.Label) }

// Frame is a picture in 8-bit RGB, row by row.
type Frame struct {
	W, H int
	RGB  []byte
}

// padValue fills the unused part of the model's square input, as in training.
const padValue = 114

// prepare turns a frame into the model's input: a size×size picture, scaled to fit
// (top-left aligned, the rest grey), as 3 planes of blue, green and red values
// 0…255. It returns the scale used.
func prepare(f Frame, size int, dst []float32) float64 {
	r := math.Min(float64(size)/float64(f.W), float64(size)/float64(f.H))
	w, h := int(float64(f.W)*r), int(float64(f.H)*r)
	plane := size * size
	for i := range dst[:3*plane] {
		dst[i] = padValue
	}
	for y := 0; y < h; y++ {
		sy := min(int(float64(y)/r), f.H-1)
		row := sy * f.W * 3
		for x := 0; x < w; x++ {
			sx := min(int(float64(x)/r), f.W-1)
			p := row + sx*3
			i := y*size + x
			dst[i] = float32(f.RGB[p+2])       // blue
			dst[plane+i] = float32(f.RGB[p+1]) // green
			dst[2*plane+i] = float32(f.RGB[p]) // red
		}
	}
	return r
}

// decode reads YOLOX's raw output (one row per grid cell over strides 8, 16 and
// 32: x, y, w, h, objectness, then 80 class scores) into objects in the frame,
// keeping those IPvexa uses with a score of at least minScore.
func decode(out []float32, size int, scale float64, fw, fh int, minScore float64) []Object {
	const stride = 85
	var objs []Object
	k := 0
	for _, st := range []int{8, 16, 32} {
		g := size / st
		for gy := 0; gy < g; gy++ {
			for gx := 0; gx < g; gx++ {
				row := out[k*stride : (k+1)*stride]
				k++
				obj := float64(row[4])
				if obj < minScore {
					continue
				}
				best, bs := -1, 0.0
				for c := 0; c < 80; c++ {
					if s := float64(row[5+c]); s > bs {
						best, bs = c, s
					}
				}
				score := obj * bs
				if best < 0 || score < minScore || GroupOf(cocoNames[best]) == "" {
					continue
				}
				cx := (float64(row[0]) + float64(gx)) * float64(st)
				cy := (float64(row[1]) + float64(gy)) * float64(st)
				w := math.Exp(float64(row[2])) * float64(st)
				h := math.Exp(float64(row[3])) * float64(st)
				x0 := clamp01((cx - w/2) / scale / float64(fw))
				y0 := clamp01((cy - h/2) / scale / float64(fh))
				x1 := clamp01((cx + w/2) / scale / float64(fw))
				y1 := clamp01((cy + h/2) / scale / float64(fh))
				if x1 <= x0 || y1 <= y0 {
					continue
				}
				objs = append(objs, Object{Label: cocoNames[best], Score: score, Box: Box{x0, y0, x1 - x0, y1 - y0}})
			}
		}
	}
	return nms(objs, 0.45)
}

// cells returns how many grid rows the model's output has for an input size.
func cells(size int) int {
	n := 0
	for _, st := range []int{8, 16, 32} {
		n += (size / st) * (size / st)
	}
	return n
}

// nms keeps the best of overlapping boxes of the same group.
func nms(objs []Object, maxIoU float64) []Object {
	sort.Slice(objs, func(i, j int) bool { return objs[i].Score > objs[j].Score })
	var keep []Object
	for _, o := range objs {
		ok := true
		for _, k := range keep {
			if k.Group() == o.Group() && k.Box.IoU(o.Box) > maxIoU {
				ok = false
				break
			}
		}
		if ok {
			keep = append(keep, o)
		}
	}
	return keep
}

func clamp01(v float64) float64 { return math.Max(0, math.Min(1, v)) }
