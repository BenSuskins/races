// Command races-server is the Races backend: it collects cards, markets and
// results, rates and seals tips, and serves the app over HTTP.
//
// Configuration is entirely environment variables, supplied by Ansible from
// the vault:
//
//	RACES_API_TOKEN        bearer token the app sends (required)
//	RACES_DB_PATH          SQLite file (default /data/races.db)
//	LISTEN_ADDR            (default :8080)
//	RACING_API_USERNAME, RACING_API_PASSWORD
//	BETFAIR_APP_KEY, BETFAIR_USERNAME, BETFAIR_PASSWORD   (optional)
//	RACING_API_BASE_URL, BETFAIR_IDENTITY_URL, BETFAIR_BETTING_URL
//	                       overrides, for pointing at a fake
//	RACES_SCHEDULER        "off" to serve without collecting (default on)
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/bensuskins/races/server/internal/api"
	"github.com/bensuskins/races/server/internal/betfair"
	"github.com/bensuskins/races/server/internal/httpx"
	"github.com/bensuskins/races/server/internal/racingapi"
	"github.com/bensuskins/races/server/internal/recovery"
	"github.com/bensuskins/races/server/internal/service"
	"github.com/bensuskins/races/server/internal/store"
)

// version is set at build time with -ldflags "-X main.version=…".
var version = "dev"

func env(name, fallback string) string {
	if v := os.Getenv(name); v != "" {
		return v
	}
	return fallback
}

func main() {
	log := slog.New(slog.NewJSONHandler(os.Stdout, nil))
	var err error
	if len(os.Args) > 1 && os.Args[1] == "recover-seal-cards" {
		err = runSealCardRecovery(os.Args[2:])
	} else {
		err = run(log)
	}
	if err != nil {
		log.Error("fatal", "error", err)
		os.Exit(1)
	}
}

func runSealCardRecovery(args []string) error {
	flags := flag.NewFlagSet("recover-seal-cards", flag.ContinueOnError)
	databasePath := flags.String("db", env("RACES_DB_PATH", "/data/races.db"), "SQLite database path")
	apply := flags.Bool("apply", false, "insert cards that reproduce their stored tips exactly")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if flags.NArg() > 0 {
		return errors.New("recover-seal-cards accepts no positional arguments")
	}
	ctx := context.Background()
	st, err := store.Open(ctx, *databasePath)
	if err != nil {
		return err
	}
	defer st.Close()
	report, err := recovery.SealCards(ctx, st, *apply, time.Now())
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	return encoder.Encode(report)
}

func run(log *slog.Logger) error {
	token := os.Getenv("RACES_API_TOKEN")
	if len(token) < 16 {
		return errors.New("RACES_API_TOKEN must be set, and at least 16 characters")
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, env("RACES_DB_PATH", "/data/races.db"))
	if err != nil {
		return err
	}
	defer st.Close()

	record := func(provider string) httpx.Recorder {
		return func(method, path, query string, status int, body []byte) {
			if err := st.SavePayload(context.Background(), provider, method, path, query, status, body, time.Now()); err != nil {
				log.Warn("saving payload", "error", err)
			}
		}
	}

	racingHTTP := httpx.New(env("RACING_API_BASE_URL", racingapi.ProductionBaseURL), racingapi.FreeTierRPS, nil)
	racingHTTP.Recorder = record("racingapi")
	racing := racingapi.New("", os.Getenv("RACING_API_USERNAME"), os.Getenv("RACING_API_PASSWORD"), racingHTTP)
	racingConfigured := os.Getenv("RACING_API_USERNAME") != "" && os.Getenv("RACING_API_PASSWORD") != ""

	creds := betfair.Credentials{AppKey: os.Getenv("BETFAIR_APP_KEY"), Username: os.Getenv("BETFAIR_USERNAME"), Password: os.Getenv("BETFAIR_PASSWORD")}
	var bf *betfair.Client
	var markets service.MarketData
	if creds.Complete() {
		identity := httpx.New(env("BETFAIR_IDENTITY_URL", betfair.IdentityBaseURL), 1, nil)
		betting := httpx.New(env("BETFAIR_BETTING_URL", betfair.BettingBaseURL), betfair.RequestsPerSecond, nil)
		betting.Recorder = record("betfair")
		bf = betfair.New(creds, identity, betting, nil)
		markets = bf
	}

	svc := service.New(st, racing, markets, time.Now, log)
	if err := svc.Bootstrap(ctx); err != nil {
		return err
	}

	srv := &http.Server{
		Addr: env("LISTEN_ADDR", ":8080"),
		Handler: (&api.Server{Service: svc, Token: token, Betfair: bf, RacingConfigured: racingConfigured,
			BetfairConfigured: creds.Complete(), Version: version, Log: log}).Handler(),
		ReadHeaderTimeout: 10 * time.Second,
	}

	if env("RACES_SCHEDULER", "on") != "off" && racingConfigured {
		go svc.Run(ctx)
		if bf != nil {
			go keepAlive(ctx, bf, log)
		}
	} else {
		log.Warn("scheduler off: nothing will be collected", "racingConfigured", racingConfigured)
	}

	errs := make(chan error, 1)
	go func() {
		log.Info("listening", "addr", srv.Addr, "version", version, "betfair", creds.Complete())
		errs <- srv.ListenAndServe()
	}()
	select {
	case err := <-errs:
		return err
	case <-ctx.Done():
	}
	shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	return srv.Shutdown(shutdown)
}

// keepAlive extends the Betfair session every half hour once it is old
// enough to need it. Renewal on INVALID_SESSION is the real mechanism.
func keepAlive(ctx context.Context, bf *betfair.Client, log *slog.Logger) {
	ticker := time.NewTicker(30 * time.Minute)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if _, err := bf.Session.KeepAliveIfNeeded(ctx); err != nil {
				log.Warn("betfair keep-alive", "error", err)
			}
		}
	}
}
