# Cloudflare Dynamic DNS IP Updater

This script is used to update Dynamic DNS (DDNS) service based on Cloudflare. Access your home network remotely via a custom domain name without a static IP. Written in pure BASH.

This was forked from the good work at [https://github.com/K0p1-Git/cloudflare-ddns-updater](https://github.com/K0p1-Git/cloudflare-ddns-updater).

Main Features Included above/beyond that base are:
- Main intent is to use with Docker/Kubernetes as a container -- container build included. Logs to stdout directly for container log viewing ease.
- Date/Severity log format for ease of integration into log capture/reporting
- Takes input from environment variables rather than hard-coded in the script
- No need for cron - can run in a loop and keep updating every x seconds as specified
- Ability to create the base entry for the domain in cloudflare, not just update existing
- Can update multiple cloudflare records, not just the base domain

## Why would I use this / FAQ
- But ddclient does this already? Yes, ddclient is very good and I had been using it for a few years, but recently discovered it wasn't updating my cloudflare records. ddclient has undergone a maintainer change, and the fixes for some of these cloudflare bugs are not yet incorporated into a new release.
- Why not just linuxserver/ddclient? Linuxserver has lots of great images, but the ddclient bug suffered from the issues above in the base ddclient. In addition, it didn't lend well towards running in a kubernetes environment, and was substantial unnecessary overhead for something relatively simple
- In bash? really? Sure, maybe not the best decision, but the script is much shorter than ddclient source, and many people using it could check and see what is really happening and gain full transparency with this approach. I had considered javascript/node, but forcing that to get an IPv4 address instead of IPv6 was much more challenging, rather than a simple "curl -4".
- Why not just the K0p1-Git fork? See above for what features are added, but my main need was for this to be containerized for a docker / kubernetes environment.

## Installation

To use the script directly:
```bash
git clone https://github.com/davideshay/cloudflare-ddns-updater.git
```

To use the script as a container:
```bash
docker run --env-file [file with environment variables] --name cddns -it ghcr.io/davideshay/cloudflare-ddns-updater:latest
```

## Environment Variables Used

```
AUTH_EMAIL - Email address for cloudflare account
AUTH_METHOD - "global" if using global API key, "token" (preferred) if using an API token for 1 zone
AUTH_KEY - API key / token
ZONE_IDENTIFIER - Can be found in the "Overview" tab of your domain
DOMAIN_NAME - non-prefixed domain name to update
RECORD_NAMES - space separated list of records to update. Defaults to just the DOMAIN_NAME single entry. Used for wildcard support or multiple sub-domains. Do not include domain name/suffix, for example "* photos" would, if the DOMAIN_NAME was mydomain.tld, update the base domain name entry mydomain.tld, the wildcard entry *.mydomain.tld and the photos.mydomain.tld entry.
TTL - DNS ttl in seconds (1 = auto)
PROXY - "true" if you want to set new records to cloudflare proxy mode, otherwise existing value is used
UPDATE_IPV6 - currently unsupported - "true" if you want to update the AAAA records for IPV6 as well as the IPv4 A records
MODE - "loop" to keep updating, "once" to run one time (useful if scheduling other ways or for testing)
REPEAT_SECONDS - Number of seconds between updates, defaults to 300
CACHE_FILE - temporary file used for caching. Defaults to a mktemp file in /tmp
```

## Contributing
Pull requests are welcome. For major changes, please open an issue first to discuss what you would like to change.

## License
[MIT](https://github.com/davideshay/cloudflare-ddns-updater/blob/main/LICENSE)
