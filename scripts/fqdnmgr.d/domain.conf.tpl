# Domain Registration Configuration
# ==================================
# Contact information for domain registration.

# Registration
YEARS=1

# Contact Information
FIRST_NAME=""
LAST_NAME=""
ADDRESS1=""
CITY=""
STATE_PROVINCE=""
POSTAL_CODE=""
# Country: 2-letter ISO code lowercase (e.g., "us", "cz", "de")
COUNTRY=""
# Phone format: +NNN.NNNNNNNNNN (e.g., +1.5551234567)
PHONE=""
EMAIL=""

# Optional (Namecheap-specific)
PROMOTION_CODE=""
ADD_FREE_WHOISGUARD="yes"
WG_ENABLED="yes"

# Wedos-specific
WEDOS_NSSET=""

# Privacy settings for WEDOS contacts (CZ and SK domains)
# WEDOS_PRIVACY: Controls how disclose_* fields are sent in contact-create requests
#   1 = Send all disclose_* fields (hide all contact information) - DEFAULT
#   0 = Do not send any disclose_* fields (make all contact information public)
#   unset/other = Send individual disclose_* fields based on their values below
WEDOS_PRIVACY="1"

# Individual privacy settings (0 = public, 1 = hidden)
# These are only used when WEDOS_PRIVACY is not explicitly set to 0 or 1
# CZ domains support:
disclose_phone="1"           # Hide phone number
disclose_fax="1"             # Hide fax number
disclose_email="1"           # Hide email address
disclose_ident="1"           # Hide ID document number
disclose_notify_email="1"   # Hide notification email

# SK domains support (in addition to CZ fields):
disclose_name="1"            # Hide name
disclose_org="1"             # Hide company name
disclose_addr="1"            # Hide address

# Cleanup policy for local domains DB
# Controls how often the automatic cleanup runs. Value must be a number followed
# by 'D' (days), for example: '7D'. The cleanup job itself deletes any rows
# whose status is not 'owned' (no per-row age checks). Default is weekly (7D).
DOMAIN_CLEANUP_DAYS="7D"

# Average DNS Propagation Time (seconds)
# Used as fallback when no historical data exists in cache.
# Format: AVG_PROPAGATION_TIME_<registrar>=<seconds> (replace dots with underscores)
AVG_PROPAGATION_TIME_namecheap_com=40
AVG_PROPAGATION_TIME_wedos_com=250

# TLD Registrar Priority List
# When WHOIS returns no registrar and no registrar argument is provided,
# fqdnmgr will silently check for credentials for registrars listed here
# based on the domain's TLD. If credentials exist for any listed registrar,
# that registrar will be used automatically (no prompts).
# Format: TLD=registrar1,registrar2,registrar3 (comma-separated, checked in order)
# Example: com=namecheap.com,godaddy,cloudflare
#          cz=wedos.com,namecheap.com
TLD_PRIORITY_com="namecheap.com"
TLD_PRIORITY_cz="wedos.com"
TLD_PRIORITY_net="namecheap.com"
TLD_PRIORITY_org="namecheap.com"
