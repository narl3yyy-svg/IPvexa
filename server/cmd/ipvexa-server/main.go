// ipvexa-server records IP cameras and serves live and recorded video to IPvexa clients.
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/base32"
	"flag"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/crypto/bcrypt"

	"ipvexa/internal/api"
	"ipvexa/internal/camera"
	"ipvexa/internal/notify"
	"ipvexa/internal/storage"
	"ipvexa/internal/store"
)

func defaultDataDir() string {
	if d := os.Getenv("IPVEXA_DATA"); d != "" {
		return d
	}
	if os.Geteuid() == 0 {
		return "/var/lib/ipvexa"
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".local", "share", "ipvexa")
}

func main() {
	dataDir := flag.String("data", defaultDataDir(), "data directory (database + recordings)")
	recDir := flag.String("recordings", "", "recordings directory (default: <data>/recordings)")
	listen := flag.String("listen", ":7480", "HTTP listen address")
	ffmpeg := flag.String("ffmpeg", "ffmpeg", "path to ffmpeg")
	ffprobe := flag.String("ffprobe", "ffprobe", "path to ffprobe")
	minFree := flag.Float64("min-free", 10, "minimum free disk space (percent) before oldest footage is deleted")
	debug := flag.Bool("debug", false, "verbose logging")
	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "Usage:\n  ipvexa-server [flags]\n  ipvexa-server [flags] passwd <username>   set a user's password (creates an admin if missing)\n\nFlags:\n")
		flag.PrintDefaults()
	}
	flag.Parse()

	level := slog.LevelInfo
	if *debug {
		level = slog.LevelDebug
	}
	slog.SetDefault(slog.New(slog.NewTextHandler(os.Stderr, &slog.HandlerOptions{Level: level})))

	if *recDir == "" {
		*recDir = filepath.Join(*dataDir, "recordings")
	}
	for _, d := range []string{*dataDir, *recDir} {
		if err := os.MkdirAll(d, 0o750); err != nil {
			fatal("cannot create directory", "dir", d, "err", err)
		}
	}
	db, err := store.Open(filepath.Join(*dataDir, "ipvexa.db"))
	if err != nil {
		fatal("open database", "err", err)
	}
	defer db.Close()

	if flag.Arg(0) == "passwd" {
		setPassword(db, flag.Arg(1))
		return
	}

	for _, bin := range []string{*ffmpeg, *ffprobe} {
		if _, err := exec.LookPath(bin); err != nil {
			fatal("required program not found (install ffmpeg)", "program", bin)
		}
	}
	ensureAdmin(db, *dataDir)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	mgr := &camera.Manager{Store: db, RecRoot: *recDir, FFmpeg: *ffmpeg, FFprobe: *ffprobe}
	notifier := notify.New(db)
	thumbDir := filepath.Join(*dataDir, "thumbs")
	apiServer := &api.Server{Store: db, Cams: mgr, RecRoot: *recDir, DataDir: *dataDir, FFmpeg: *ffmpeg, MinFreePct: *minFree,
		Notify: notifier, ThumbDir: thumbDir}
	notifier.Snapshot = func(ctx context.Context, camID int64) ([]byte, error) { return apiServer.LiveJPEG(ctx, camID, "sub") }
	camName := func(id int64) string {
		if c, err := db.Camera(id); err == nil {
			return c.Name
		}
		return fmt.Sprintf("camera %d", id)
	}
	mgr.OnEvent = func(e store.Event, started bool) {
		if started && e.Kind == "motion" {
			go apiServer.SaveThumb(e)
			notifier.Handle(notify.Event{Trigger: "motion", CameraID: e.CameraID, Camera: camName(e.CameraID), Time: time.UnixMilli(e.Start)})
		}
	}
	if err := mgr.Start(ctx); err != nil {
		fatal("start cameras", "err", err)
	}
	ret := &storage.Retention{Store: db, RecRoot: *recDir, MinFreePct: *minFree, ThumbDir: thumbDir}
	go ret.Run(ctx)
	go notifier.Watch(ctx, func() []notify.CameraState {
		cams, _ := db.Cameras()
		out := make([]notify.CameraState, 0, len(cams))
		for _, c := range cams {
			st := mgr.Status(c.ID)
			cs := notify.CameraState{ID: c.ID, Name: c.Name, Enabled: c.Enabled}
			if st.Main != nil {
				// An idle on-demand main stream is fine; judge by the substream then.
				cs.Online = st.Main.State == "online" || (st.Main.State == "idle" && st.Sub != nil && st.Sub.State == "online")
				cs.Error = st.Main.LastError
			}
			out = append(out, cs)
		}
		return out
	}, func() float64 {
		free, err := storage.FreePct(*recDir)
		if err != nil {
			return 100
		}
		return free
	}, func() float64 { return db.Server(*minFree).MinFreePct })
	go func() {
		t := time.NewTicker(time.Hour)
		defer t.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-t.C:
				db.PurgeSessions()
			}
		}
	}()

	srv := &http.Server{
		Addr:              *listen,
		Handler:           apiServer.Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}
	go func() {
		<-ctx.Done()
		sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		srv.Shutdown(sctx)
	}()
	slog.Info("IPvexa server started", "version", api.Version, "listen", *listen, "data", *dataDir, "recordings", *recDir)
	if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		fatal("http server", "err", err)
	}
	slog.Info("shutting down, finishing recordings")
	mgr.StopAll()
}

func fatal(msg string, args ...any) {
	slog.Error(msg, args...)
	os.Exit(1)
}

func randomPassword() string {
	b := make([]byte, 10)
	rand.Read(b)
	return strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

// ensureAdmin creates an "admin" account on first run and writes its password to a file
// only the server's user can read.
func ensureAdmin(db *store.Store, dataDir string) {
	n, err := db.UserCount()
	if err != nil || n > 0 {
		return
	}
	pw := randomPassword()
	hash, _ := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	if err := db.CreateUser(&store.User{Username: "admin", Hash: string(hash), Role: "admin"}); err != nil {
		fatal("create admin", "err", err)
	}
	f := filepath.Join(dataDir, "initial-admin-password")
	os.WriteFile(f, []byte(pw+"\n"), 0o600)
	slog.Warn("created first user 'admin'; password saved to file (change it with: ipvexa-server passwd admin)", "file", f)
}

func setPassword(db *store.Store, user string) {
	if user == "" {
		fatal("usage: ipvexa-server passwd <username>")
	}
	fmt.Fprintf(os.Stderr, "New password for %s: ", user)
	line, _ := bufio.NewReader(os.Stdin).ReadString('\n')
	pw := strings.TrimRight(line, "\r\n")
	if len(pw) < 8 {
		fatal("password must be at least 8 characters")
	}
	hash, _ := bcrypt.GenerateFromPassword([]byte(pw), bcrypt.DefaultCost)
	if err := db.SetUserHash(user, string(hash)); err == store.ErrNotFound {
		if err := db.CreateUser(&store.User{Username: user, Hash: string(hash), Role: "admin"}); err != nil {
			fatal("create user", "err", err)
		}
		fmt.Fprintln(os.Stderr, "created admin user", user)
	} else if err != nil {
		fatal("set password", "err", err)
	} else {
		fmt.Fprintln(os.Stderr, "password updated")
	}
}
