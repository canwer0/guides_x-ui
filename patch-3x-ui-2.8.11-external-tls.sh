#!/usr/bin/env bash
set -Eeuo pipefail

# Fixes VLESS+XHTTP share links and JSON subscriptions in 3x-ui v2.8.11
# when the inbound itself uses security=none and External Proxy forces TLS.
# The patch makes generated client configs explicitly contain:
#   sni=<external domain>, fp=chrome, alpn=h2

readonly PATCH_VERSION="v2.8.11"
readonly GO_VERSION="go1.26.0"
readonly INSTALL_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
readonly PANEL_BIN="${INSTALL_DIR}/x-ui"
readonly STATE_DIR="/var/lib/3x-ui-patches"
readonly STATE_FILE="${STATE_DIR}/external-tls-links-v2.8.11.state"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "run this script as root"
[[ -x "${PANEL_BIN}" ]] || die "3x-ui binary not found: ${PANEL_BIN}"
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

rollback() {
    [[ -f "${STATE_FILE}" ]] || die "patch state file not found: ${STATE_FILE}"
    local backup
    backup="$(awk -F= '$1 == "backup" {print substr($0, index($0, "=") + 1)}' "${STATE_FILE}")"
    [[ -n "${backup}" && -f "${backup}" ]] || die "backup binary not found"

    say "Restoring ${backup}"
    systemctl stop x-ui
    install -m 0755 "${backup}" "${PANEL_BIN}"
    systemctl start x-ui
    systemctl is-active --quiet x-ui || die "x-ui did not start after rollback"
    rm -f "${STATE_FILE}"
    say "Rollback complete. Refresh the panel with Ctrl+F5."
}

if [[ "${1:-}" == "--rollback" ]]; then
    rollback
    exit 0
fi

current_version="$(${PANEL_BIN} -v 2>/dev/null | tr -d '[:space:]' || true)"
case "${current_version}" in
    2.8.11|v2.8.11) ;;
    *) die "this patch is only for 3x-ui v2.8.11; installed version: ${current_version:-unknown}" ;;
esac

if [[ -f "${STATE_FILE}" ]]; then
    installed_sha="$(sha256sum "${PANEL_BIN}" | awk '{print $1}')"
    saved_sha="$(awk -F= '$1 == "sha256" {print $2}' "${STATE_FILE}")"
    if [[ -n "${saved_sha}" && "${installed_sha}" == "${saved_sha}" ]]; then
        say "Patch is already installed. Nothing to do."
        exit 0
    fi
fi

export DEBIAN_FRONTEND=noninteractive
say "Installing build prerequisites"
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl git jq build-essential pkg-config libsqlite3-dev

work_dir="$(mktemp -d /tmp/3x-ui-link-patch.XXXXXXXX)"
cleanup() { rm -rf -- "${work_dir}"; }
trap cleanup EXIT

case "$(uname -m)" in
    x86_64|amd64) go_arch="amd64" ;;
    aarch64|arm64) go_arch="arm64" ;;
    *) die "supported architectures: amd64, arm64" ;;
esac

say "Downloading and verifying ${GO_VERSION}"
curl -fsSL 'https://go.dev/dl/?mode=json&include=all' -o "${work_dir}/go-releases.json"
go_file="$(jq -r --arg version "${GO_VERSION}" --arg arch "${go_arch}" '
    .[] | select(.version == $version) | .files[] |
    select(.os == "linux" and .arch == $arch and .kind == "archive") | .filename
' "${work_dir}/go-releases.json" | head -n1)"
go_sha="$(jq -r --arg version "${GO_VERSION}" --arg arch "${go_arch}" '
    .[] | select(.version == $version) | .files[] |
    select(.os == "linux" and .arch == $arch and .kind == "archive") | .sha256
' "${work_dir}/go-releases.json" | head -n1)"
[[ -n "${go_file}" && "${go_file}" != "null" && -n "${go_sha}" && "${go_sha}" != "null" ]] || \
    die "could not resolve ${GO_VERSION} archive for linux/${go_arch}"

curl -fL "https://go.dev/dl/${go_file}" -o "${work_dir}/${go_file}"
printf '%s  %s\n' "${go_sha}" "${work_dir}/${go_file}" | sha256sum -c -
tar -C "${work_dir}" -xzf "${work_dir}/${go_file}"
go_bin="${work_dir}/go/bin/go"

say "Downloading exact 3x-ui ${PATCH_VERSION} sources"
git clone --quiet --depth 1 --branch "${PATCH_VERSION}" https://github.com/MHSanaei/3x-ui.git "${work_dir}/src"

say "Applying External Proxy TLS patch"
python3 - "${work_dir}/src" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_once(relative, old, new):
    path = root / relative
    text = path.read_text(encoding="utf-8")
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{relative}: expected one patch location, found {count}")
    path.write_text(text.replace(old, new, 1), encoding="utf-8")

# Links copied directly from the web panel.
replace_once(
    "web/assets/js/model/inbound.js",
'''                if (type == "tcp" && !ObjectUtil.isEmpty(flow)) {
                    params.set("flow", flow);
                }
            }
        }

        else if (security === 'reality') {''',
'''                if (type == "tcp" && !ObjectUtil.isEmpty(flow)) {
                    params.set("flow", flow);
                }
            } else if (forceTls === 'tls' && type === 'xhttp') {
                // XUI_EXTERNAL_TLS_PATCH: TLS is terminated by the external reverse proxy.
                params.set("sni", address);
                params.set("fp", UTLS_FINGERPRINT.UTLS_CHROME);
                params.set("alpn", ALPN_OPTION.H2);
            }
        }

        else if (security === 'reality') {'''
)

# Raw VLESS links returned by the subscription server.
replace_once(
    "sub/subService.go",
'''\t\t\tlink := fmt.Sprintf("vless://%s@%s:%d", uuid, dest, port)

\t\t\tif newSecurity != "same" {
\t\t\t\tparams["security"] = newSecurity
\t\t\t} else {
\t\t\t\tparams["security"] = security
\t\t\t}
\t\t\turl, _ := url.Parse(link)
\t\t\tq := url.Query()

\t\t\tfor k, v := range params {''',
'''\t\t\tlink := fmt.Sprintf("vless://%s@%s:%d", uuid, dest, port)

\t\t\t// XUI_EXTERNAL_TLS_PATCH: never mutate the shared parameter map.
\t\t\tlinkParams := make(map[string]string, len(params)+3)
\t\t\tfor k, v := range params {
\t\t\t\tlinkParams[k] = v
\t\t\t}
\t\t\tif newSecurity != "same" {
\t\t\t\tlinkParams["security"] = newSecurity
\t\t\t} else {
\t\t\t\tlinkParams["security"] = security
\t\t\t}
\t\t\tif newSecurity == "tls" && security != "tls" && streamNetwork == "xhttp" {
\t\t\t\tlinkParams["sni"] = dest
\t\t\t\tlinkParams["fp"] = "chrome"
\t\t\t\tlinkParams["alpn"] = "h2"
\t\t\t}
\t\t\turl, _ := url.Parse(link)
\t\t\tq := url.Query()

\t\t\tfor k, v := range linkParams {'''
)

# Full Xray JSON subscriptions.
replace_once(
    "sub/subJsonService.go",
'''\t\tnewStream := stream
\t\tswitch extPrxy["forceTls"].(string) {
\t\tcase "tls":
\t\t\tif newStream["security"] != "tls" {
\t\t\t\tnewStream["security"] = "tls"
\t\t\t\tnewStream["tlsSettings"] = map[string]any{}
\t\t\t}
''',
'''\t\t// XUI_EXTERNAL_TLS_PATCH: clone the map because every external proxy
\t\t// needs independent client-side transport settings.
\t\tstreamBytes, _ := json.Marshal(stream)
\t\tnewStream := make(map[string]any)
\t\t_ = json.Unmarshal(streamBytes, &newStream)
\t\tswitch extPrxy["forceTls"].(string) {
\t\tcase "tls":
\t\t\tif newStream["security"] != "tls" {
\t\t\t\tnewStream["security"] = "tls"
\t\t\t\ttlsSettings := map[string]any{}
\t\t\t\tif network, _ := newStream["network"].(string); network == "xhttp" {
\t\t\t\t\ttlsSettings["serverName"] = inbound.Listen
\t\t\t\t\ttlsSettings["alpn"] = []string{"h2"}
\t\t\t\t\ttlsSettings["fingerprint"] = "chrome"
\t\t\t\t}
\t\t\t\tnewStream["tlsSettings"] = tlsSettings
\t\t\t}
'''
)

print("All three generators patched successfully")
PY

"${work_dir}/go/bin/gofmt" -w "${work_dir}/src/sub/subService.go" "${work_dir}/src/sub/subJsonService.go"

say "Building patched panel; this can take several minutes"
(
    cd "${work_dir}/src"
    export CGO_ENABLED=1
    export GOTOOLCHAIN=local
    "${go_bin}" build -trimpath -ldflags='-s -w' -o "${work_dir}/x-ui.patched" main.go
)

patched_version="$(${work_dir}/x-ui.patched -v 2>/dev/null | tr -d '[:space:]' || true)"
case "${patched_version}" in
    2.8.11|v2.8.11) ;;
    *) die "built binary reported an unexpected version: ${patched_version:-unknown}" ;;
esac

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
backup_bin="${INSTALL_DIR}/x-ui.before-external-tls-patch.${timestamp}"
backup_db="/etc/x-ui/x-ui.db.before-external-tls-patch.${timestamp}"

say "Backing up the current binary and database"
cp -a "${PANEL_BIN}" "${backup_bin}"
if [[ -f /etc/x-ui/x-ui.db ]]; then
    cp -a /etc/x-ui/x-ui.db "${backup_db}"
fi

say "Installing patched binary"
systemctl stop x-ui
install -m 0755 "${work_dir}/x-ui.patched" "${PANEL_BIN}"
systemctl start x-ui
sleep 3

if ! systemctl is-active --quiet x-ui; then
    say "Patched panel failed to start; restoring the original binary"
    systemctl stop x-ui || true
    install -m 0755 "${backup_bin}" "${PANEL_BIN}"
    systemctl start x-ui
    die "patch rolled back automatically; inspect: journalctl -u x-ui -n 100 --no-pager"
fi

mkdir -p "${STATE_DIR}"
patched_sha="$(sha256sum "${PANEL_BIN}" | awk '{print $1}')"
{
    printf 'version=%s\n' "${PATCH_VERSION}"
    printf 'sha256=%s\n' "${patched_sha}"
    printf 'backup=%s\n' "${backup_bin}"
    printf 'database_backup=%s\n' "${backup_db}"
} > "${STATE_FILE}"
chmod 0600 "${STATE_FILE}"

say ""
say "Patch installed successfully."
say "All VLESS+XHTTP inbounds with External Proxy=TLS will now export:"
say "  SNI = external proxy domain"
say "  ALPN = h2"
say "  uTLS fingerprint = chrome"
say ""
say "Refresh the panel with Ctrl+F5 before copying a new link."
say "Rollback command: bash $0 --rollback"
