# overview

- Apache2 is very flexible and supports many kinds of virtual hosts, but many configurations are repetitive. `a2sitemgr` provides a quick, opinionated way to deploy the most common virtual-host patterns and is designed to make automation easy.
- `a2sitemgr` integrates with ACME (via `certbot`) to obtain TLS certificates automatically.
- `fqdnmgr` complements `a2sitemgr` by interacting with domain registrars' APIs (for example, Namecheap) to check domain status, purchase domains, and set DNS records when needed.
- `fqdncredmgr` standardizes how provider credentials are collected and stored so other tools (like `fqdnmgr`) can use them safely via secure socket.

## Commands
in short: this script makes these commands available  
- `a2sitemgr` — Apache2 site manager
- `fqdnmgr` — FQDN manager to interact with the registrar (purchase a domain, set DNS records etc.)
- `fqdncredmgr` — FQDN credentials manager

## Notes

- `a2sitemgr` integrates with the other tools and will call them when appropriate (for example, checking domain ownership or creating DNS records).
- This project uses `certbot` instead of `lego` for certificate management because `lego` commonly relies on permanent environment variables for provider credentials; that increases the attack surface since those environment variables are harder to protect. Switching to temporary credentials would require pre- and post-cert hooks; `lego` does not provide a built-in mechanism for that in every provider integration.
- The codebase is modular: currently Namecheap is the only provider implemented, but adding new providers is straightforward and PRs are welcome.
- Two helper commands are used internally by `a2sitemgr`:
  - `a2wcrecalc` — Recalculates Apache site configuration files to update wildcard-subdomain configurations. This is useful to enable/disable wildcard subdomains across existing vhosts.
  - `a2wcrecalc-dms` — Similar to `a2wcrecalc`, but additionally generates mapping files used by ([`docker-mailserver`](https://github.com/docker-mailserver/docker-mailserver)).

  Note: set the environment variable `DMS_DIR` to point to your docker-mailserver mount directory; it defaults to `/opt/compose/docker-mailserver` if not set.

## Prerequisites

- Tested on Ubuntu Server `24.04 LTS` (amd64).  
- needs `certbot`, `sqlite3`, `whois`, `libxml2-utils` and `jq` packages installed
```
sudo apt install -y whois certbot sqlite3 libxml2-utils jq
```

## Install

Clone the repository, then run the installer script:

```bash
mkdir a2tools && cd a2tools
git clone https://github.com/TBAIKamine/a2tools.git .
bash ./setup.sh
```

## Supported registrars
- [namecheap.com](https://www.namecheap.com)
- [wedos.com](https://www.wedos.com)

additional providers may be added, PR are also welcome

## Basic usage
#### 1. Add credentials:
```
sudo fqdncredmgr add namecheap.com username
```
you can also use `-k` parameter to supply the key in non-interactive way. for full command usage options use `-h` or `--help`
#### 2. Purchase a domain
```
sudo fqdnmgr purchase example.com namecheap.com
```
for full command usage options use `-h` or `--help`
#### 3. Set necessary DNS records.
```
sudo fqdnmgr setInitDNSRecords -d example1.com example2.com
#set for all of your domains associated with the registrar:
sudo fqdnmgr setInitDNSRecords -r namecheap.com
```
you can use `-v` for verbosity to see the progress, `-o` to override existing DNS records, `--sync` to wait until the propagation is confirmed.  
for full command usage options use `-h` or `--help`

#### 4. Configure the website:

```bash
sudo a2sitemgr -d example.com
```
this would create the necessary directories and config file then request LE certificates using certbot (must be already installed and registered) using ACME challenge for wildcard subdomain certificates and will implicitly check the propagation.
Use `--help` for more details about options.

## Advanced usage examples
SWC (subdomain wildcard):  
- A subdomain wildcard lets a subdomain work for multiple base domains (for example, `mail.*`). If your base domains are `example1.com` and `example2.com`, you can create a wildcard subdomain with:  
```bash
sudo a2sitemgr -d 'mail.*' --mode swc
```
This will create the necessary configuration to serve `mail.example1.com` and `mail.example2.com` and use existing certificates for the relevant base domains automatically.  
ProxyPass (reverse proxy to a container):  
- To expose a container on a single subdomain and use ProxyPass, run:  
```bash
sudo a2sitemgr -d sub.example.com --mode proxypass -p 1234
```
- Use `--secured` (or `-s`) when the proxied service uses HTTPS:  
```bash
sudo a2sitemgr -d sub.example.com --mode proxypass -p 1234 --secured
```
The command will create the ProxyPass site configuration and request certificates as needed.  
for the full list of parameters or if you need help or want to examine usage details for any component, use `--help`.  

technically both `swc` and `proxypass` modes can be combined but as an opinionated tool, this case doesn't seem to be populare (at least for now).  

## Important notes:
- the auth hook for the ACME challenge by certbot uses a smart propagation check that uses exponontially decaying checkpoints until reaching the propagation average time for that specific provider.  
the check is verified against the NameServer and Google DNS `8.8.8.8` then offers a minimum of 10s buffer time (actual buffer time depends on the registrar)  
since certbot will crash if the propagation didn't happen yet, `a2sitemgr` will lower that risk to bare minimum, it almost always guarenteed to have a successful validation.  
- `a2sitemgr` uses a cron job to check certificates expiration on daily bases then renew it 10 days before expiration

#### Uninstall
for convenience, to remove all files generated by `setup.sh` you can execute 
```
sudo /usr/local/bin/a2sitemgr.d/uninstall.sh
```
## License
I vibe coded this entire deal so feel free to use it as you wish