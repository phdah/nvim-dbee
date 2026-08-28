package adapters

import (
	"context"
	"database/sql"
	"fmt"
	"io"

	"github.com/kndndrj/nvim-dbee/dbee/core"
	"github.com/kndndrj/nvim-dbee/dbee/core/builders"
	"github.com/pkg/browser"
	"github.com/snowflakedb/gosnowflake"
)

func init() {
	_ = register(&Snowflake{}, "snowflake")

	// gosnowflake's "externalbrowser"/Okta authenticator shells out via
	// github.com/pkg/browser, which by default wires the spawned command's
	// stdout/stderr to os.Stdout/os.Stderr. dbee's own os.Stdout is the
	// msgpack-rpc pipe back to Neovim, so any output the browser-opening
	// command (e.g. xdg-open) writes there would corrupt the RPC stream and
	// kill the whole connection to Neovim. Discard it instead.
	browser.Stdout = io.Discard
	browser.Stderr = io.Discard
}

var _ core.Adapter = (*Snowflake)(nil)

type Snowflake struct{}

// Snowflake expects the connection string in dsn format.
// user[:password]@account/database/schema[?param1=value1&paramN=valueN]
// or
// user[:password]@account/database[?param1=value1&paramN=valueN]
// or
// user[:password]@host:port/database/schema?account=user_account[?param1=value1&paramN=valueN]
// or
// host:port/database/schema?account=user_account[?param1=value1&paramN=valueN]
// https://github.com/snowflakedb/gosnowflake/blob/b034584aa6fc171c1fa02e5af1f98234f24538fe/dsn.go#L308-#L314
//
// MFA/SSO (e.g. Okta) is supported via the "authenticator" param, e.g.
// user@account/database?authenticator=externalbrowser
// See https://pkg.go.dev/github.com/snowflakedb/gosnowflake#hdr-Authentication
func (r *Snowflake) Connect(rawURL string) (core.Driver, error) {
	config, err := gosnowflake.ParseDSN(rawURL)
	if err != nil {
		return nil, err
	}
	connector := gosnowflake.NewConnector(gosnowflake.SnowflakeDriver{}, *config)
	db := sql.OpenDB(connector)
	// NOTE: no PingContext timeout here on purpose - browser-based/MFA
	// authenticators (e.g. authenticator=externalbrowser) require interactive
	// user input and are governed by gosnowflake's own LoginTimeout/
	// ExternalBrowserTimeout (configurable via DSN params), not an outer
	// deadline that could kill the local callback listener mid-login.
	if err := db.PingContext(context.Background()); err != nil {
		return nil, fmt.Errorf("unable to ping snowflake: %w", err)
	}

	return &snowflakeDriver{
		c:      builders.NewClient(db),
		config: *config,
	}, nil
}

func (r *Snowflake) GetHelpers(opts *core.TableOptions) map[string]string {
	qualifiedTable := fmt.Sprintf("%s.%s", opts.Schema, opts.Table)
	if opts.Database != "" {
		qualifiedTable = fmt.Sprintf("%s.%s.%s", opts.Database, opts.Schema, opts.Table)
	}

	list := fmt.Sprintf("SELECT * FROM %s LIMIT 500;", qualifiedTable)
	grants := fmt.Sprintf("show grants on %s;", qualifiedTable)
	ddl := fmt.Sprintf("SELECT GET_DDL('TABLE', '%s') as DDL;", qualifiedTable)
	out := map[string]string{
		"List":   list,
		"Grants": grants,
		"DDL":    ddl,
		"Columns": fmt.Sprintf(`SELECT *
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_NAME = '%s' AND TABLE_SCHEMA = '%s'
			ORDER BY ORDINAL_POSITION;`, opts.Table, opts.Schema,
		),
	}

	return out
}
