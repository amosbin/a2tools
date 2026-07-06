# a2tools unit tests

Bash-based unit tests for the a2tools codebase. No external test framework
is required; the runner is a single `run.sh` script that invokes each
`test_*.sh` in its own subshell and reports TAP-style output.

The tests are designed to run on the target platform: **Ubuntu 24.04 LTS**.
On that platform they assume only the standard `bash`, `sqlite3`, `sed`,
`awk`, `grep`, `mktemp`, and `date` utilities are available - all of which
are runtime or build dependencies of a2tools itself, or part of the
`bash`/`coreutils` baseline that the package transitively depends on.

The tests do **not** assume Apache, certbot, jq, curl, or a real DNS
resolver is installed; if a future test ever needs one of those, it must
guard the call with `command -v` and skip when missing.

## Layout

```
tests/
├── run.sh                       # runner (run all or a subset)
├── lib/
│   └── test_helpers.sh          # shared assertion library, sandbox helpers
├── test_common_validators.sh    # lib/common.sh: is_valid_fqdn, is_valid_ipv4, sql_escape
├── test_common_creds.sh         # lib/common.sh: creds_get, has_creds_for
├── test_common_providers.sh     # lib/common.sh: provider_file, list_providers, _provider_source_safe
├── test_fqdnmgr_helpers.sh      # fqdnmgr.sh: get_effective_ownership_domain, get_tld, propagation helpers
├── test_fqdnmgr_cache.sh        # fqdnmgr.sh: cache_get/set/cleanup_expired_cache
├── test_fqdncredmgr_mask.sh     # fqdncredmgr.sh: mask_username
├── test_namecheap_urlencode.sh  # namecheap.com.provider: url_encode (RFC 3986)
├── test_cleanup_domains.sh      # cleanup-domains.sh: DOMAIN_CLEANUP_DAYS parsing
├── test_a2sitemgr_templates.sh  # template substitution (no script invocation)
├── test_a2sitemgr_argparse.sh   # regex / port-range / FQDN mode logic
├── test_flag_only_cli.sh        # every entry script refuses positional args
└── test_deploy_hook.sh          # deploy-hook.sh: cert_date update + apache reload
```

## Running

```bash
./tests/run.sh
```

Run a subset (filename glob):

```bash
./tests/run.sh test_common_*
./tests/run.sh test_fqdnmgr_cache.sh
```

Each individual test file is also runnable standalone:

```bash
./tests/test_common_validators.sh
```

## Design notes

### What the tests cover

* **Pure validation primitives** (`is_valid_fqdn`, `is_valid_ipv4`,
  `sql_escape`, FQDN-mode regexes, port-range check).
* **Credentials database accessors** (`creds_get` return codes 0/11/12/15,
  `has_creds_for`, SQL-injection safety for provider names).
* **Provider plugin discovery + the security check** (`provider_file`,
  `list_providers`, dedup, the `_provider_source_safe` ownership /
  permission gate).
* **Cache layer** (`cache_set`, `cache_get`, TTL handling, dns_change
  entries, `cleanup_expired_cache`, the ap "never expires" type).
* **Propagation timing helpers** (`get_avg_propagation_time` cache /
  domain.conf / hardcoded default cascade, `calculate_next_wait` floor,
  `update_avg_propagation_time` averaging).
* **Username masking** for `fqdncredmgr list` output (so the raw
  credential never appears in a list).
* **`url_encode`** in the Namecheap provider (RFC 3986 conformance;
  uppercase %HH).
* **Template rendering** for all five vhost templates.
* **Deploy hook** behaviour (cert_date update, apache reload, invalid
  lineage handling).
* **Cleanup interval** parsing (`7D`, `30D`, malformed values).
* **Flag-only CLI convention** (every entry script rejects positional
  args in favour of named flags: `a2sitemgr -d FQDN`, `fqdncredmgr
  <action> -p PROVIDER -u USERNAME [-k -]`, `fqdnmgr <subcmd>
  -d DOMAIN [-r REG]`). This was the August 2026 refactor.

### What the tests do NOT cover (and why)

* **End-to-end invocations** of the entry scripts against a live
  system. They mutate `/etc/apache2`, call `certbot`, talk to
  Namecheap, etc. The one exception is `test_flag_only_cli.sh`, which
  runs each entry script with a `PATH`-shadowing stub bin (apache2ctl,
  systemctl, certbot, sqlite3, fqdnmgr, fqdncredmgr, dig, curl, whois,
  jq all return rc 99). That lets the parser run, the dispatcher
  fail fast, and the test assert on the parser's "invalid argument" /
  "no subcommand" error - which is the only behaviour under test.
* **Network reachability**, **real DNS resolution**, **certbot
  renewals**. These are integration concerns for the manual install
  flow, not unit tests.
* **Lintian / dpkg-buildpackage** packaging checks. Those are a separate
  concern covered by the release flow.

### Sourcing strategy

The bash entry scripts mutate globals (`A2TOOLS_ROOT`, `A2TOOLS_STATE`,
FD 3, etc.) when sourced. Tests work around this in two ways:

1. **Source the whole lib + extract function region only.** The lib
   (`scripts/lib/common.sh`) is safe to source - it only sets variables,
   it doesn't execute business logic. For `fqdnmgr.sh` and
   `cleanup-domains.sh`, which DO execute logic at top level
   (`init_cache`, `cleanup_expired_cache`, interval parsing), tests
   either:
   * source a trimmed copy ending at the first `usage()` definition
     (which loads the helpers but not the main dispatch), or
   * extract the helper function in isolation with `awk` and source
     just the function block.
2. **Sandbox FHS paths.** The shim pattern (`COMMON_SHIM`) sets
   `A2TOOLS_ETC`, `A2TOOLS_STATE`, etc. to point at the scratch dir
   BEFORE the lib overwrites them, so all DB / log / cache writes go
   to the scratch dir. The scratch dir is auto-cleaned on EXIT.

### Adding a new test

1. Create `tests/test_<topic>.sh` with `#!/bin/bash` and
   `. "$(dirname "$0")/lib/test_helpers.sh"` at the top.
2. Use the assertion helpers (`assert_eq`, `assert_true`, `assert_rc`,
   `assert_contains`, `assert_file_exists`, etc.) - they emit TAP and
   update the pass/fail counters automatically.
3. End the file with `test_summary` (returns 0 on pass, 1 on fail).
4. If the test needs a clean shell, source the lib in a subshell and
   `eval` the function call, capturing stdout and `$?`. This is the
   pattern used by `test_common_*.sh`.

The runner auto-discovers every `test_*.sh` in the directory; no
registration step is required.
