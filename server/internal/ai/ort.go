//go:build linux || darwin

package ai

import (
	"errors"
	"fmt"
	"runtime"
	"unsafe"

	"github.com/ebitengine/purego"
)

// A small binding to the ONNX Runtime C API, loaded at run time (no C compiler is
// needed to build the server, and the server runs normally without the library).
//
// The positions below are the functions' places in the OrtApi table of
// onnxruntime_c_api.h. New functions are only ever added at the end of that table,
// so these stay valid for every later ONNX Runtime version.
const (
	fnGetErrorMessage                  = 2
	fnCreateEnv                        = 3
	fnDisableTelemetryEvents           = 6
	fnCreateSession                    = 7
	fnRun                              = 9
	fnCreateSessionOptions             = 10
	fnSetSessionGraphOptimizationLevel = 23
	fnSetIntraOpNumThreads             = 24
	fnSetInterOpNumThreads             = 25
	fnSessionGetInputName              = 36
	fnSessionGetOutputName             = 37
	fnCreateTensorWithDataAsOrtValue   = 49
	fnGetTensorMutableData             = 51
	fnGetDimensionsCount               = 61
	fnGetDimensions                    = 62
	fnGetTensorTypeAndShape            = 65
	fnCreateCpuMemoryInfo              = 69
	fnAllocatorFree                    = 76
	fnGetAllocatorWithDefaultOptions   = 78
	fnReleaseStatus                    = 93
	fnReleaseMemoryInfo                = 94
	fnReleaseSession                   = 95
	fnReleaseValue                     = 96
	fnReleaseTensorTypeAndShapeInfo    = 99
	fnReleaseSessionOptions            = 100
	fnCount                            = 101

	// The API version asked for: ONNX Runtime 1.14 or newer works.
	ortAPIVersion = 14

	ortLoggingWarning   = 2
	ortArenaAllocator   = 1
	ortMemTypeDefault   = 0
	ortTensorFloat      = 1
	ortEnableAll        = 99
	ptrSize             = unsafe.Sizeof(uintptr(0))
	maxOutputDims       = 8
	maxCStringLen       = 4096
	defaultInferThreads = 2
)

type ortLib struct {
	fn  [fnCount]uintptr
	env uintptr
	mem uintptr // CPU memory info for input tensors
}

// call runs an OrtApi function. go:uintptrescapes keeps the Go memory that the
// arguments point to in place for the call, as for purego.SyscallN itself.
//
//go:uintptrescapes
func (o *ortLib) call(i int, args ...uintptr) uintptr {
	r, _, _ := purego.SyscallN(o.fn[i], args...)
	return r
}

// check turns an OrtStatus into an error (and frees it).
func (o *ortLib) check(st uintptr) error {
	if st == 0 {
		return nil
	}
	msg := cString(o.call(fnGetErrorMessage, st))
	o.call(fnReleaseStatus, st)
	if msg == "" {
		msg = "ONNX Runtime error"
	}
	return errors.New(msg)
}

// ptr turns an address returned by C into a pointer. The memory belongs to C, so
// the garbage collector doesn't track it.
func ptr(addr uintptr) unsafe.Pointer {
	return *(*unsafe.Pointer)(unsafe.Pointer(&addr))
}

func cString(addr uintptr) string {
	if addr == 0 {
		return ""
	}
	p := ptr(addr)
	n := 0
	for n < maxCStringLen && *(*byte)(unsafe.Add(p, n)) != 0 {
		n++
	}
	return string(unsafe.Slice((*byte)(p), n))
}

func cStr(s string) *byte {
	b := append([]byte(s), 0)
	return &b[0]
}

// loadORT opens the ONNX Runtime library at path.
func loadORT(path string) (*ortLib, error) {
	h, err := purego.Dlopen(path, purego.RTLD_NOW|purego.RTLD_GLOBAL)
	if err != nil {
		return nil, err
	}
	base, err := purego.Dlsym(h, "OrtGetApiBase")
	if err != nil {
		return nil, fmt.Errorf("%s is not ONNX Runtime: %w", path, err)
	}
	r, _, _ := purego.SyscallN(base)
	if r == 0 {
		return nil, errors.New("ONNX Runtime gave no API")
	}
	// struct OrtApiBase { GetApi(version); GetVersionString(); }
	getAPI := *(*uintptr)(ptr(r))
	api, _, _ := purego.SyscallN(getAPI, ortAPIVersion)
	if api == 0 {
		return nil, errors.New("this ONNX Runtime is too old (1.14 or newer is needed)")
	}
	o := &ortLib{}
	table := ptr(api)
	for i := range o.fn {
		o.fn[i] = *(*uintptr)(unsafe.Add(table, uintptr(i)*ptrSize))
	}
	var env uintptr
	if err := o.check(o.call(fnCreateEnv, ortLoggingWarning, uintptr(unsafe.Pointer(cStr("ipvexa"))), uintptr(unsafe.Pointer(&env)))); err != nil {
		return nil, err
	}
	o.env = env
	o.call(fnDisableTelemetryEvents, env)
	var mem uintptr
	if err := o.check(o.call(fnCreateCpuMemoryInfo, ortArenaAllocator, ortMemTypeDefault, uintptr(unsafe.Pointer(&mem)))); err != nil {
		return nil, err
	}
	o.mem = mem
	return o, nil
}

// ortSession is one loaded model with one float input and one float output.
type ortSession struct {
	o       *ortLib
	s       uintptr
	inName  string
	outName string
}

func (o *ortLib) newSession(model string, threads int) (*ortSession, error) {
	if threads <= 0 {
		threads = defaultInferThreads
	}
	var opts uintptr
	if err := o.check(o.call(fnCreateSessionOptions, uintptr(unsafe.Pointer(&opts)))); err != nil {
		return nil, err
	}
	defer o.call(fnReleaseSessionOptions, opts)
	if err := o.check(o.call(fnSetIntraOpNumThreads, opts, uintptr(threads))); err != nil {
		return nil, err
	}
	if err := o.check(o.call(fnSetInterOpNumThreads, opts, 1)); err != nil {
		return nil, err
	}
	if err := o.check(o.call(fnSetSessionGraphOptimizationLevel, opts, ortEnableAll)); err != nil {
		return nil, err
	}
	var s uintptr
	if err := o.check(o.call(fnCreateSession, o.env, uintptr(unsafe.Pointer(cStr(model))), opts, uintptr(unsafe.Pointer(&s)))); err != nil {
		return nil, err
	}
	sess := &ortSession{o: o, s: s}
	var err error
	if sess.inName, err = sess.name(fnSessionGetInputName); err != nil {
		sess.close()
		return nil, err
	}
	if sess.outName, err = sess.name(fnSessionGetOutputName); err != nil {
		sess.close()
		return nil, err
	}
	return sess, nil
}

func (s *ortSession) name(fn int) (string, error) {
	o := s.o
	var alloc uintptr
	if err := o.check(o.call(fnGetAllocatorWithDefaultOptions, uintptr(unsafe.Pointer(&alloc)))); err != nil {
		return "", err
	}
	var p uintptr
	if err := o.check(o.call(fn, s.s, 0, alloc, uintptr(unsafe.Pointer(&p)))); err != nil {
		return "", err
	}
	name := cString(p)
	o.call(fnAllocatorFree, alloc, p)
	return name, nil
}

func (s *ortSession) close() {
	if s.s != 0 {
		s.o.call(fnReleaseSession, s.s)
		s.s = 0
	}
}

// run feeds input (of the given shape) to the model and returns a copy of its
// output and the output's shape.
func (s *ortSession) run(input []float32, shape []int64) ([]float32, []int64, error) {
	o := s.o
	var in uintptr
	if err := o.check(o.call(fnCreateTensorWithDataAsOrtValue, o.mem,
		uintptr(unsafe.Pointer(&input[0])), uintptr(len(input)*4),
		uintptr(unsafe.Pointer(&shape[0])), uintptr(len(shape)), ortTensorFloat,
		uintptr(unsafe.Pointer(&in)))); err != nil {
		return nil, nil, err
	}
	defer o.call(fnReleaseValue, in)

	inName, outName := cStr(s.inName), cStr(s.outName)
	inNames, outNames := []*byte{inName}, []*byte{outName}
	ins := []uintptr{in}
	outs := []uintptr{0}
	err := o.check(o.call(fnRun, s.s, 0,
		uintptr(unsafe.Pointer(&inNames[0])), uintptr(unsafe.Pointer(&ins[0])), 1,
		uintptr(unsafe.Pointer(&outNames[0])), 1, uintptr(unsafe.Pointer(&outs[0]))))
	runtime.KeepAlive(input)
	runtime.KeepAlive(shape)
	runtime.KeepAlive(inNames)
	runtime.KeepAlive(outNames)
	runtime.KeepAlive(ins)
	if err != nil {
		return nil, nil, err
	}
	out := outs[0]
	defer o.call(fnReleaseValue, out)

	var info uintptr
	if err := o.check(o.call(fnGetTensorTypeAndShape, out, uintptr(unsafe.Pointer(&info)))); err != nil {
		return nil, nil, err
	}
	var nd uintptr
	err = o.check(o.call(fnGetDimensionsCount, info, uintptr(unsafe.Pointer(&nd))))
	if err == nil && (nd == 0 || nd > maxOutputDims) {
		err = fmt.Errorf("unexpected model output with %d dimensions", nd)
	}
	dims := make([]int64, maxOutputDims)
	if err == nil {
		err = o.check(o.call(fnGetDimensions, info, uintptr(unsafe.Pointer(&dims[0])), nd))
	}
	o.call(fnReleaseTensorTypeAndShapeInfo, info)
	if err != nil {
		return nil, nil, err
	}
	dims = dims[:nd]
	n := int64(1)
	for _, d := range dims {
		n *= d
	}
	var data uintptr
	if err := o.check(o.call(fnGetTensorMutableData, out, uintptr(unsafe.Pointer(&data)))); err != nil {
		return nil, nil, err
	}
	res := make([]float32, n)
	copy(res, unsafe.Slice((*float32)(ptr(data)), n))
	return res, dims, nil
}
