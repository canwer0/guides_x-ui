#!/usr/bin/env bash
set -Eeuo pipefail

PATCH_ID="xhttp-vlessenc-vision-2811-v4"
UPSTREAM_COMMIT="52fdf5d4296b4534e25d6221d82ec7d819a9b952"
SOURCE_URL="https://codeload.github.com/MHSanaei/3x-ui/tar.gz/${UPSTREAM_COMMIT}"
EXPECTED_VERSION="2.8.11"
GO_VERSION="1.26.0"

XUI_DIR="${XUI_MAIN_FOLDER:-/usr/local/x-ui}"
PANEL_BIN="${XUI_DIR}/x-ui"
DB_PATH="${XUI_DB_PATH:-/etc/x-ui/x-ui.db}"
SERVICE_NAME="${XUI_SERVICE_NAME:-x-ui}"
MARKER_PATH="${XUI_DIR}/.patch-xhttp-2811"
BACKUP_ROOT="${XUI_BACKUP_ROOT:-/var/backups/x-ui-xhttp-2811}"

APPLY_PROFILE=false
ASSUME_YES=false
ROLLBACK_DIR=""
PRINT_DIFF=false
TEMP_DIR=""
BACKUP_DIR=""
STATE_CHANGED=false
ROLLBACK_RUNNING=false

log() { printf '[xhttp-2811] %s\n' "$*"; }
warn() { printf '[xhttp-2811] WARNING: %s\n' "$*" >&2; }
die() { printf '[xhttp-2811] ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage:
  bash patch-xhttp-2.8.11.sh [--apply-base62-profile] [--yes]
  bash patch-xhttp-2.8.11.sh --rollback BACKUP_DIR
  bash patch-xhttp-2.8.11.sh --print-diff

Options:
  --apply-base62-profile  Apply the requested Base62 profile to every existing
                          XHTTP inbound after an explicit confirmation.
  --yes                   Skip the profile confirmation (for automation).
  --rollback DIR          Restore the panel binary and optional DB from DIR.
  --print-diff            Print the exact source patch embedded in this script.
  -h, --help              Show this help.

Environment overrides:
  XUI_MAIN_FOLDER, XUI_DB_PATH, XUI_SERVICE_NAME, XUI_BACKUP_ROOT
USAGE
}

while (($#)); do
    case "$1" in
        --apply-base62-profile) APPLY_PROFILE=true ;;
        --yes) ASSUME_YES=true ;;
        --rollback)
            shift
            (($#)) || die "--rollback requires a backup directory"
            ROLLBACK_DIR="$1"
            ;;
        --print-diff) PRINT_DIFF=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument: $1" ;;
    esac
    shift
done

emit_patch() {
    sed -n '/^__XHTTP_PATCH_BEGIN__$/,/^__XHTTP_PATCH_END__$/p' "$0" | sed '1d;$d'
    sed -n '/^__EXTERNAL_TLS_PATCH_BEGIN__$/,/^__EXTERNAL_TLS_PATCH_END__$/p' "$0" | sed '1d;$d'
    sed -n '/^__VLESSENC_VISION_PATCH_BEGIN__$/,/^__VLESSENC_VISION_PATCH_END__$/p' "$0" | sed '1d;$d'
}

if "$PRINT_DIFF"; then
    emit_patch
    exit 0
fi

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this script as root"
[[ -z "$ROLLBACK_DIR" || "$APPLY_PROFILE" == false ]] || die "--rollback cannot be combined with --apply-base62-profile"

service_active() {
    systemctl is-active --quiet "$SERVICE_NAME"
}

start_and_verify_service() {
    systemctl restart "$SERVICE_NAME"
    local attempt
    for attempt in {1..20}; do
        if service_active; then
            sleep 1
            service_active && return 0
        fi
        sleep 1
    done
    systemctl status "$SERVICE_NAME" --no-pager -l >&2 || true
    journalctl -u "$SERVICE_NAME" -n 80 --no-pager >&2 || true
    return 1
}

restore_from_backup() {
    local dir="$1"
    [[ -d "$dir" ]] || die "backup directory does not exist: $dir"
    [[ -f "$dir/manifest" ]] || die "invalid backup (manifest is missing): $dir"
    [[ -f "$dir/x-ui" ]] || die "invalid backup (x-ui is missing): $dir"

    ROLLBACK_RUNNING=true
    systemctl stop "$SERVICE_NAME" || true
    install -m 0755 "$dir/x-ui" "$PANEL_BIN"
    if [[ -f "$dir/x-ui.db" ]]; then
        install -m 0600 "$dir/x-ui.db" "$DB_PATH"
    fi
    if [[ -f "$dir/marker" ]]; then
        install -m 0644 "$dir/marker" "$MARKER_PATH"
    else
        rm -f -- "$MARKER_PATH"
    fi
    start_and_verify_service || die "rollback files were restored, but $SERVICE_NAME did not start"
    ROLLBACK_RUNNING=false
    log "rollback complete: $dir"
}

if [[ -n "$ROLLBACK_DIR" ]]; then
    restore_from_backup "$ROLLBACK_DIR"
    exit 0
fi

cleanup() {
    if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
        rm -rf -- "$TEMP_DIR"
    fi
}

rollback_on_error() {
    local exit_code=$?
    trap - ERR
    if "$STATE_CHANGED" && ! "$ROLLBACK_RUNNING" && [[ -n "$BACKUP_DIR" ]]; then
        warn "installation failed; restoring backup $BACKUP_DIR"
        restore_from_backup "$BACKUP_DIR" || true
    fi
    cleanup
    exit "$exit_code"
}
trap rollback_on_error ERR
trap cleanup EXIT

command -v systemctl >/dev/null || die "systemctl is required"
command -v curl >/dev/null || die "curl is required"
command -v tar >/dev/null || die "tar is required"
command -v sha256sum >/dev/null || die "sha256sum is required"
[[ -x "$PANEL_BIN" ]] || die "panel binary not found: $PANEL_BIN"
[[ -d "$XUI_DIR/bin" ]] || die "incompatible 3X-UI layout: $XUI_DIR/bin is missing"
systemctl cat "$SERVICE_NAME" >/dev/null 2>&1 || die "systemd service not found: $SERVICE_NAME"

installed_version="$($PANEL_BIN -v 2>/dev/null | tr -d '\r' | tail -n1)"
[[ "$installed_version" == "$EXPECTED_VERSION" ]] || die "expected 3X-UI $EXPECTED_VERSION, found '${installed_version:-unknown}'"

current_sha="$(sha256sum "$PANEL_BIN" | awk '{print $1}')"
already_patched=false
if [[ -f "$MARKER_PATH" ]] && grep -qx "patch_id=$PATCH_ID" "$MARKER_PATH"; then
    marker_sha="$(sed -n 's/^binary_sha256=//p' "$MARKER_PATH" | head -n1)"
    if [[ "$marker_sha" == "$current_sha" ]]; then
        already_patched=true
        log "patch is already installed; binary rebuild is not required"
    else
        warn "patch marker exists, but the panel binary changed; rebuilding the patch"
    fi
fi

if "$APPLY_PROFILE"; then
    command -v sqlite3 >/dev/null || die "sqlite3 is required for --apply-base62-profile"
    [[ -f "$DB_PATH" ]] || die "database not found: $DB_PATH"
    xhttp_count="$(sqlite3 "$DB_PATH" "SELECT count(*) FROM inbounds WHERE json_extract(stream_settings, '$.network')='xhttp';")"
    log "XHTTP inbounds selected for the optional profile: $xhttp_count"
    if [[ "$xhttp_count" != "0" && "$ASSUME_YES" == false ]]; then
        read -r -p "Apply the Base62 profile to all $xhttp_count XHTTP inbound(s)? [y/N] " answer
        case "$answer" in y|Y|yes|YES) ;; *) die "profile application cancelled" ;; esac
    fi
fi

inspect_installed_xray() {
    local xray_bin version_line
    xray_bin="$(find "$XUI_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' -print -quit 2>/dev/null || true)"
    if [[ -z "$xray_bin" || ! -x "$xray_bin" ]]; then
        warn "the installed Xray binary could not be located under $XUI_DIR/bin"
        warn "the script will not install or update Xray Core automatically"
        return 0
    fi
    version_line="$("$xray_bin" version 2>/dev/null | head -n1 || true)"
    log "using installed ${version_line:-Xray binary: $xray_bin}"
    if [[ "$version_line" =~ Xray[[:space:]]+([0-9]+)\.([0-9]+)\.([0-9]+) ]]; then
        local major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}
        if (( major < 26 || (major == 26 && minor < 6) || (major == 26 && minor == 6 && patch < 22) )); then
            warn "${version_line}: sessionIDTable/sessionIDLength require Xray-core 26.6.22 or newer"
            warn "the script will not update Xray Core automatically"
        fi
    fi

    if ! "$xray_bin" vlessenc >/dev/null 2>&1; then
        warn "${version_line:-$xray_bin} does not provide a working 'xray vlessenc' command"
        warn "VLESS Encryption key generation and runtime support require a compatible installed Xray Core"
        warn "the script will not update Xray Core automatically; manual key entry remains available in the panel"
    else
        log "installed Xray Core supports the vlessenc generator"
    fi
}
inspect_installed_xray

if "$already_patched" && ! "$APPLY_PROFILE"; then
    log "nothing to do"
    log "installed marker: $MARKER_PATH"
    log "last backup: $(sed -n 's/^backup_dir=//p' "$MARKER_PATH" | head -n1)"
    exit 0
fi

install_build_packages() {
    local packages=()
    command -v gcc >/dev/null || packages+=(gcc)
    command -v patch >/dev/null || packages+=(patch)
    ((${#packages[@]})) || return 0

    if command -v apt-get >/dev/null; then
        DEBIAN_FRONTEND=noninteractive apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential patch
    elif command -v dnf >/dev/null; then
        dnf install -y gcc glibc-devel patch
    elif command -v yum >/dev/null; then
        yum install -y gcc glibc-devel patch
    elif command -v pacman >/dev/null; then
        pacman -Sy --noconfirm base-devel patch
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install -y gcc glibc-devel patch
    else
        die "gcc/patch are missing and the package manager is unsupported"
    fi
    command -v gcc >/dev/null || die "gcc installation failed"
    command -v patch >/dev/null || die "patch installation failed"
}

prepare_go() {
    local machine go_arch go_sha archive
    machine="$(uname -m)"
    case "$machine" in
        x86_64|amd64)
            go_arch="amd64"
            go_sha="aac1b08a0fb0c4e0a7c1555beb7b59180b05dfc5a3d62e40e9de90cd42f88235"
            ;;
        aarch64|arm64)
            go_arch="arm64"
            go_sha="bd03b743eb6eb4193ea3c3fd3956546bf0e3ca5b7076c8226334afe6b75704cd"
            ;;
        i386|i486|i586|i686)
            go_arch="386"
            go_sha="35e2ec7a7ae6905a1fae5459197b70e3fcbc5e0a786a7d6ba8e49bcd38ad2e26"
            ;;
        armv6l|armv7l)
            go_arch="armv6l"
            go_sha="3f6b48d96f0d8dff77e4625aa179e0449f6bbe79b6986bfa711c2cfc1257ebd8"
            ;;
        *) die "unsupported build architecture: $machine" ;;
    esac

    archive="$TEMP_DIR/go${GO_VERSION}.linux-${go_arch}.tar.gz"
    log "downloading the temporary Go $GO_VERSION toolchain for $go_arch"
    curl -fL --retry 3 --connect-timeout 20 -o "$archive" "https://go.dev/dl/go${GO_VERSION}.linux-${go_arch}.tar.gz"
    printf '%s  %s\n' "$go_sha" "$archive" | sha256sum -c -
    tar -C "$TEMP_DIR" -xzf "$archive"
    export PATH="$TEMP_DIR/go/bin:$PATH"
    export GOTOOLCHAIN=local
}

if ! "$already_patched"; then
    install_build_packages
    TEMP_DIR="$(mktemp -d -t xhttp-2811.XXXXXX)"
    prepare_go

    source_archive="$TEMP_DIR/source.tar.gz"
    log "downloading pinned MHSanaei/3x-ui $EXPECTED_VERSION source ($UPSTREAM_COMMIT)"
    curl -fL --retry 3 --connect-timeout 20 -o "$source_archive" \
        "$SOURCE_URL"
    tar -C "$TEMP_DIR" -xzf "$source_archive"
    source_dir="$(find "$TEMP_DIR" -mindepth 1 -maxdepth 1 -type d -name '3x-ui-*' -print -quit)"
    [[ -n "$source_dir" && -f "$source_dir/go.mod" ]] || die "downloaded source layout is invalid"
    [[ "$(tr -d '[:space:]' < "$source_dir/config/version")" == "$EXPECTED_VERSION" ]] || die "downloaded source version mismatch"

    emit_patch > "$TEMP_DIR/xhttp-2811.patch"
    (cd "$source_dir" && patch --batch --forward -p1 < "$TEMP_DIR/xhttp-2811.patch")
    grep -q 'sessionIDTable' "$source_dir/web/assets/js/model/inbound.js" || die "GUI model patch verification failed"
    grep -q 'sessionIDPlacement: this.sessionIDPlacement' "$source_dir/web/assets/js/model/inbound.js" || die "XHTTP serialization patch verification failed"
    grep -q 'json.sessionIDPlacement ?? json.sessionPlacement' "$source_dir/web/assets/js/model/inbound.js" || die "XHTTP legacy migration patch verification failed"
    grep -q 'Session ID Length' "$source_dir/web/html/form/stream/stream_xhttp.html" || die "GUI form patch verification failed"
    grep -q 'xhttp-vlessenc-vision-v4' "$source_dir/web/html/inbounds.html" || die "GUI cache-buster patch verification failed"
    grep -q 'buildXHTTPLinkParams' "$source_dir/sub/subService.go" || die "subscription patch verification failed"
    grep -q "External Proxy terminates TLS" "$source_dir/web/assets/js/model/inbound.js" || die "GUI External Proxy TLS patch verification failed"
    grep -q 'effectiveSecurity == "tls".*streamNetwork == "xhttp"' "$source_dir/sub/subService.go" || die "raw subscription External Proxy TLS patch verification failed"
    grep -q 'tlsSettings\["serverName"\] = inbound.Listen' "$source_dir/sub/subJsonService.go" || die "JSON subscription External Proxy TLS patch verification failed"
    grep -q 'hasVlessEncryption()' "$source_dir/web/assets/js/model/inbound.js" || die "GUI VLESS Encryption capability patch verification failed"
    grep -q "this.network === 'xhttp'.*this.hasVlessEncryption()" "$source_dir/web/assets/js/model/inbound.js" || die "GUI XHTTP Vision gate verification failed"
    grep -q 'vlessFlowAllowed(streamNetwork, security, settings)' "$source_dir/sub/subService.go" || die "raw subscription XHTTP Vision patch verification failed"
    grep -q 'clearVlessFlowIfUnsupported' "$source_dir/web/html/modals/inbound_modal.html" || die "disabled VLESS Encryption flow cleanup verification failed"
    [[ -f "$source_dir/sub/vless_flow_test.go" ]] || die "VLESS Encryption regression tests are missing"

    log "compiling the patched panel (Xray binary is not rebuilt or replaced)"
    (cd "$source_dir" && CGO_ENABLED=1 go test ./sub)
    (cd "$source_dir" && CGO_ENABLED=1 go build -trimpath -ldflags '-s -w' -o "$TEMP_DIR/x-ui.patched" main.go)
    [[ "$($TEMP_DIR/x-ui.patched -v | tr -d '\r' | tail -n1)" == "$EXPECTED_VERSION" ]] || die "patched binary version check failed"
fi

mkdir -p "$BACKUP_ROOT"
BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -m 0700 "$BACKUP_DIR"
cp -a "$PANEL_BIN" "$BACKUP_DIR/x-ui"
if [[ -f "$MARKER_PATH" ]]; then
    cp -a "$MARKER_PATH" "$BACKUP_DIR/marker"
fi
if "$APPLY_PROFILE"; then
    sqlite3 "$DB_PATH" ".backup '$BACKUP_DIR/x-ui.db'"
fi
{
    printf 'patch_id=%s\n' "$PATCH_ID"
    printf 'created_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'panel_binary=%s\n' "$PANEL_BIN"
    printf 'database_backed_up=%s\n' "$APPLY_PROFILE"
} > "$BACKUP_DIR/manifest"

STATE_CHANGED=true
systemctl stop "$SERVICE_NAME"
if ! "$already_patched"; then
    install -m 0755 "$TEMP_DIR/x-ui.patched" "$PANEL_BIN.new"
    mv -f -- "$PANEL_BIN.new" "$PANEL_BIN"
fi

if "$APPLY_PROFILE" && [[ "$xhttp_count" != "0" ]]; then
    sqlite3 "$DB_PATH" <<'SQL'
BEGIN IMMEDIATE;
UPDATE inbounds
SET stream_settings = json_remove(json_set(
    stream_settings,
    '$.xhttpSettings.sessionIDPlacement', 'header',
    '$.xhttpSettings.sessionIDKey', 'X-Session-ID',
    '$.xhttpSettings.sessionIDTable', 'Base62',
    '$.xhttpSettings.sessionIDLength', '24-32',
    '$.xhttpSettings.seqPlacement', 'header',
    '$.xhttpSettings.seqKey', 'X-Sequence',
    '$.xhttpSettings.uplinkHTTPMethod', 'POST',
    '$.xhttpSettings.uplinkDataPlacement', 'header',
    '$.xhttpSettings.uplinkDataKey', 'X-Payload',
    '$.xhttpSettings.xPaddingBytes', '32-96',
    '$.xhttpSettings.xPaddingObfsMode', json('true'),
    '$.xhttpSettings.xPaddingPlacement', 'header',
    '$.xhttpSettings.xPaddingKey', 'X-Request-ID',
    '$.xhttpSettings.xPaddingMethod', 'tokenish'
),
    '$.xhttpSettings.sessionPlacement',
    '$.xhttpSettings.sessionKey'
)
WHERE json_extract(stream_settings, '$.network') = 'xhttp';
COMMIT;
SQL
fi

new_sha="$(sha256sum "$PANEL_BIN" | awk '{print $1}')"
{
    printf 'patch_id=%s\n' "$PATCH_ID"
    printf 'source_commit=%s\n' "$UPSTREAM_COMMIT"
    printf 'binary_sha256=%s\n' "$new_sha"
    printf 'backup_dir=%s\n' "$BACKUP_DIR"
    printf 'installed_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
} > "$MARKER_PATH"
chmod 0644 "$MARKER_PATH"

start_and_verify_service

xray_bin="$(find "$XUI_DIR/bin" -maxdepth 1 -type f -name 'xray-linux-*' -print -quit 2>/dev/null || true)"
xray_config="$XUI_DIR/bin/config.json"
if [[ -x "$xray_bin" && -s "$xray_config" ]]; then
    log "validating the generated Xray config with the installed core"
    "$xray_bin" run -test -config "$xray_config"
else
    warn "generated Xray config check skipped: binary or $xray_config is unavailable"
fi
STATE_CHANGED=false
trap - ERR

log "patch installed successfully"
log "changed files:"
if ! "$already_patched"; then printf '  %s\n' "$PANEL_BIN"; fi
if "$APPLY_PROFILE" && [[ "$xhttp_count" != "0" ]]; then printf '  %s\n' "$DB_PATH"; fi
printf '  %s\n' "$MARKER_PATH"
log "backup: $BACKUP_DIR"
log "rollback: bash $0 --rollback $BACKUP_DIR"
log "Xray Core was not changed"
exit 0

: <<'__XHTTP_PATCH_EOF__'
__XHTTP_PATCH_BEGIN__
diff --git a/sub/subService.go b/sub/subService.go
index 818f193b..5fe551b7 100644
--- a/sub/subService.go
+++ b/sub/subService.go
@@ -319,6 +319,98 @@ func (s *SubService) genVmessLink(inbound *model.Inbound, email string) string {
 	return "vmess://" + base64.StdEncoding.EncodeToString(jsonStr)
 }
 
+// buildXHTTPLinkParams returns the URL parameters defined by the Xray XHTTP
+// share-link convention. Advanced, client-relevant settings are serialized as
+// raw JSON in `extra`; server-only knobs are intentionally left out.
+func buildXHTTPLinkParams(xhttp map[string]any) map[string]string {
+	params := make(map[string]string)
+	if path, ok := xhttp["path"].(string); ok {
+		params["path"] = path
+	}
+	if host, ok := xhttp["host"].(string); ok && host != "" {
+		params["host"] = host
+	} else if headers, ok := xhttp["headers"].(map[string]any); ok {
+		params["host"] = searchHost(headers)
+	}
+	if mode, ok := xhttp["mode"].(string); ok {
+		params["mode"] = mode
+	}
+
+	extra := make(map[string]any)
+	addString := func(key string) {
+		if value, ok := xhttp[key].(string); ok && value != "" {
+			extra[key] = value
+		}
+	}
+
+	addString("mode")
+	addString("xPaddingBytes")
+	if enabled, ok := xhttp["xPaddingObfsMode"].(bool); ok && enabled {
+		extra["xPaddingObfsMode"] = true
+		for _, key := range []string{"xPaddingKey", "xPaddingHeader", "xPaddingPlacement", "xPaddingMethod"} {
+			addString(key)
+		}
+	}
+	for _, key := range []string{
+		"uplinkHTTPMethod",
+		"sessionIDPlacement",
+		"sessionIDKey",
+		"sessionIDTable",
+		"sessionIDLength",
+		"seqPlacement",
+		"seqKey",
+		"uplinkDataPlacement",
+		"uplinkDataKey",
+		"scMaxEachPostBytes",
+	} {
+		addString(key)
+	}
+	if value, ok := xhttp["uplinkChunkSize"]; ok {
+		switch typed := value.(type) {
+		case string:
+			if typed != "" && typed != "0" {
+				extra["uplinkChunkSize"] = typed
+			}
+		case float64:
+			if typed > 0 {
+				extra["uplinkChunkSize"] = typed
+			}
+		case int:
+			if typed > 0 {
+				extra["uplinkChunkSize"] = typed
+			}
+		}
+	}
+
+	// Xray-core #6258 renamed these fields. The runtime config remains
+	// canonical; aliases are emitted only in share links for older clients.
+	if value, ok := extra["sessionIDPlacement"]; ok {
+		extra["sessionPlacement"] = value
+	}
+	if value, ok := extra["sessionIDKey"]; ok {
+		extra["sessionKey"] = value
+	}
+
+	if headers, ok := xhttp["headers"].(map[string]any); ok {
+		sharedHeaders := make(map[string]any)
+		for name, value := range headers {
+			if !strings.EqualFold(name, "host") {
+				sharedHeaders[name] = value
+			}
+		}
+		if len(sharedHeaders) > 0 {
+			extra["headers"] = sharedHeaders
+		}
+	}
+
+	if len(extra) > 0 {
+		if encoded, err := json.Marshal(extra); err == nil {
+			params["extra"] = string(encoded)
+		}
+	}
+	return params
+}
+
 func (s *SubService) genVlessLink(inbound *model.Inbound, email string) string {
 	var address string
 	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
@@ -398,14 +490,9 @@ func (s *SubService) genVlessLink(inbound *model.Inbound, email string) string {
 		}
 	case "xhttp":
 		xhttp, _ := stream["xhttpSettings"].(map[string]any)
-		params["path"] = xhttp["path"].(string)
-		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
-			params["host"] = host
-		} else {
-			headers, _ := xhttp["headers"].(map[string]any)
-			params["host"] = searchHost(headers)
+		for key, value := range buildXHTTPLinkParams(xhttp) {
+			params[key] = value
 		}
-		params["mode"] = xhttp["mode"].(string)
 	}
 	security, _ := stream["security"].(string)
 	if security == "tls" {
@@ -594,14 +681,9 @@ func (s *SubService) genTrojanLink(inbound *model.Inbound, email string) string
 		}
 	case "xhttp":
 		xhttp, _ := stream["xhttpSettings"].(map[string]any)
-		params["path"] = xhttp["path"].(string)
-		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
-			params["host"] = host
-		} else {
-			headers, _ := xhttp["headers"].(map[string]any)
-			params["host"] = searchHost(headers)
+		for key, value := range buildXHTTPLinkParams(xhttp) {
+			params[key] = value
 		}
-		params["mode"] = xhttp["mode"].(string)
 	}
 	security, _ := stream["security"].(string)
 	if security == "tls" {
@@ -793,14 +875,9 @@ func (s *SubService) genShadowsocksLink(inbound *model.Inbound, email string) st
 		}
 	case "xhttp":
 		xhttp, _ := stream["xhttpSettings"].(map[string]any)
-		params["path"] = xhttp["path"].(string)
-		if host, ok := xhttp["host"].(string); ok && len(host) > 0 {
-			params["host"] = host
-		} else {
-			headers, _ := xhttp["headers"].(map[string]any)
-			params["host"] = searchHost(headers)
+		for key, value := range buildXHTTPLinkParams(xhttp) {
+			params[key] = value
 		}
-		params["mode"] = xhttp["mode"].(string)
 	}
 
 	security, _ := stream["security"].(string)
diff --git a/web/assets/js/model/inbound.js b/web/assets/js/model/inbound.js
index b6059cf7..d3111eef 100644
--- a/web/assets/js/model/inbound.js
+++ b/web/assets/js/model/inbound.js
@@ -493,8 +493,10 @@ class xHTTPStreamSettings extends XrayCommonClass {
         xPaddingPlacement = '',
         xPaddingMethod = '',
         uplinkHTTPMethod = '',
-        sessionPlacement = '',
-        sessionKey = '',
+        sessionIDPlacement = '',
+        sessionIDKey = '',
+        sessionIDTable = '',
+        sessionIDLength = '',
         seqPlacement = '',
         seqKey = '',
         uplinkDataPlacement = '',
@@ -517,8 +519,10 @@ class xHTTPStreamSettings extends XrayCommonClass {
         this.xPaddingPlacement = xPaddingPlacement;
         this.xPaddingMethod = xPaddingMethod;
         this.uplinkHTTPMethod = uplinkHTTPMethod;
-        this.sessionPlacement = sessionPlacement;
-        this.sessionKey = sessionKey;
+        this.sessionIDPlacement = sessionIDPlacement;
+        this.sessionIDKey = sessionIDKey;
+        this.sessionIDTable = sessionIDTable;
+        this.sessionIDLength = sessionIDLength;
         this.seqPlacement = seqPlacement;
         this.seqKey = seqKey;
         this.uplinkDataPlacement = uplinkDataPlacement;
@@ -551,8 +555,10 @@ class xHTTPStreamSettings extends XrayCommonClass {
             json.xPaddingPlacement,
             json.xPaddingMethod,
             json.uplinkHTTPMethod,
-            json.sessionPlacement,
-            json.sessionKey,
+            json.sessionIDPlacement ?? json.sessionPlacement,
+            json.sessionIDKey ?? json.sessionKey,
+            json.sessionIDTable,
+            json.sessionIDLength,
             json.seqPlacement,
             json.seqKey,
             json.uplinkDataPlacement,
@@ -578,8 +584,10 @@ class xHTTPStreamSettings extends XrayCommonClass {
             xPaddingPlacement: this.xPaddingPlacement,
             xPaddingMethod: this.xPaddingMethod,
             uplinkHTTPMethod: this.uplinkHTTPMethod,
-            sessionPlacement: this.sessionPlacement,
-            sessionKey: this.sessionKey,
+            sessionIDPlacement: this.sessionIDPlacement,
+            sessionIDKey: this.sessionIDKey,
+            sessionIDTable: this.sessionIDTable,
+            sessionIDLength: this.sessionIDLength,
             seqPlacement: this.seqPlacement,
             seqKey: this.seqKey,
             uplinkDataPlacement: this.uplinkDataPlacement,
@@ -587,6 +595,58 @@ class xHTTPStreamSettings extends XrayCommonClass {
             uplinkChunkSize: this.uplinkChunkSize,
         };
     }
+
+    // Xray share links carry client-relevant XHTTP options in a URL-escaped
+    // JSON `extra` value. Keep legacy session names in the link
+    // only, so old and new clients can consume it while DB/runtime config uses
+    // the canonical sessionID* names introduced by Xray-core #6258.
+    toShareExtra() {
+        const extra = {};
+        const addString = (key) => {
+            const value = this[key];
+            if (typeof value === 'string' && value.length > 0) {
+                extra[key] = value;
+            }
+        };
+
+        addString('mode');
+        addString('xPaddingBytes');
+        if (this.xPaddingObfsMode === true) {
+            extra.xPaddingObfsMode = true;
+            ['xPaddingKey', 'xPaddingHeader', 'xPaddingPlacement', 'xPaddingMethod'].forEach(addString);
+        }
+
+        [
+            'uplinkHTTPMethod',
+            'sessionIDPlacement',
+            'sessionIDKey',
+            'sessionIDTable',
+            'sessionIDLength',
+            'seqPlacement',
+            'seqKey',
+            'uplinkDataPlacement',
+            'uplinkDataKey',
+            'scMaxEachPostBytes',
+        ].forEach(addString);
+
+        if ((typeof this.uplinkChunkSize === 'string' && this.uplinkChunkSize.length > 0)
+            || (typeof this.uplinkChunkSize === 'number' && this.uplinkChunkSize > 0)) {
+            extra.uplinkChunkSize = this.uplinkChunkSize;
+        }
+
+        if (extra.sessionIDPlacement) extra.sessionPlacement = extra.sessionIDPlacement;
+        if (extra.sessionIDKey) extra.sessionKey = extra.sessionIDKey;
+
+        const headers = {};
+        this.headers.forEach((header) => {
+            if (header.name && header.name.toLowerCase() !== 'host') {
+                headers[header.name] = header.value;
+            }
+        });
+        if (Object.keys(headers).length > 0) extra.headers = headers;
+
+        return Object.keys(extra).length > 0 ? extra : null;
+    }
 }
 
 class TlsStreamSettings extends XrayCommonClass {
@@ -1465,6 +1525,8 @@ class Inbound extends XrayCommonClass {
                 params.set("path", xhttp.path);
                 params.set("host", xhttp.host?.length > 0 ? xhttp.host : this.getHeader(xhttp, 'host'));
                 params.set("mode", xhttp.mode);
+                const xhttpExtra = xhttp.toShareExtra();
+                if (xhttpExtra) params.set("extra", JSON.stringify(xhttpExtra));
                 break;
         }
 
@@ -1565,6 +1627,8 @@ class Inbound extends XrayCommonClass {
                 params.set("path", xhttp.path);
                 params.set("host", xhttp.host?.length > 0 ? xhttp.host : this.getHeader(xhttp, 'host'));
                 params.set("mode", xhttp.mode);
+                const xhttpExtra = xhttp.toShareExtra();
+                if (xhttpExtra) params.set("extra", JSON.stringify(xhttpExtra));
                 break;
         }
 
@@ -1641,6 +1705,8 @@ class Inbound extends XrayCommonClass {
                 params.set("path", xhttp.path);
                 params.set("host", xhttp.host?.length > 0 ? xhttp.host : this.getHeader(xhttp, 'host'));
                 params.set("mode", xhttp.mode);
+                const xhttpExtra = xhttp.toShareExtra();
+                if (xhttpExtra) params.set("extra", JSON.stringify(xhttpExtra));
                 break;
         }
 
diff --git a/web/html/form/stream/stream_xhttp.html b/web/html/form/stream/stream_xhttp.html
index 447612c9..80a0d646 100644
--- a/web/html/form/stream/stream_xhttp.html
+++ b/web/html/form/stream/stream_xhttp.html
@@ -90,8 +90,8 @@
             <a-select-option value="GET">GET (packet-up only)</a-select-option>
         </a-select>
     </a-form-item>
-    <a-form-item label="Session Placement">
-        <a-select v-model="inbound.stream.xhttp.sessionPlacement"
+    <a-form-item label="Session ID Placement">
+        <a-select v-model="inbound.stream.xhttp.sessionIDPlacement"
             :dropdown-class-name="themeSwitcher.currentTheme">
             <a-select-option value>Default (path)</a-select-option>
             <a-select-option value="path">path</a-select-option>
@@ -100,11 +100,23 @@
             <a-select-option value="query">query</a-select-option>
         </a-select>
     </a-form-item>
-    <a-form-item label="Session Key"
-        v-if="inbound.stream.xhttp.sessionPlacement && inbound.stream.xhttp.sessionPlacement !== 'path'">
-        <a-input v-model.trim="inbound.stream.xhttp.sessionKey"
+    <a-form-item label="Session ID Key"
+        v-if="inbound.stream.xhttp.sessionIDPlacement && inbound.stream.xhttp.sessionIDPlacement !== 'path'">
+        <a-input v-model.trim="inbound.stream.xhttp.sessionIDKey"
             placeholder="x_session"></a-input>
     </a-form-item>
+    <a-form-item label="Session ID Table">
+        <a-auto-complete v-model.trim="inbound.stream.xhttp.sessionIDTable"
+            :data-source="['ALPHABET', 'Alphabet', 'BASE36', 'Base62', 'HEX', 'alphabet', 'base36', 'hex', 'number']"
+            placeholder="Base62"
+            :filter-option="(input, option) => option.componentOptions.children[0].text.toLowerCase().indexOf(input.toLowerCase()) >= 0">
+        </a-auto-complete>
+    </a-form-item>
+    <a-form-item label="Session ID Length"
+        v-if="inbound.stream.xhttp.sessionIDTable">
+        <a-input v-model.trim="inbound.stream.xhttp.sessionIDLength"
+            placeholder="24-32"></a-input>
+    </a-form-item>
     <a-form-item label="Sequence Placement">
         <a-select v-model="inbound.stream.xhttp.seqPlacement"
             :dropdown-class-name="themeSwitcher.currentTheme">
@@ -137,11 +149,11 @@
     </a-form-item>
     <a-form-item label="Uplink Chunk Size"
         v-if="inbound.stream.xhttp.mode === 'packet-up' && inbound.stream.xhttp.uplinkDataPlacement && inbound.stream.xhttp.uplinkDataPlacement !== 'body'">
-        <a-input-number v-model.number="inbound.stream.xhttp.uplinkChunkSize"
-            :min="0" placeholder="0 (unlimited)"></a-input-number>
+        <a-input v-model.trim="inbound.stream.xhttp.uplinkChunkSize"
+            placeholder="0 or 2048-3072"></a-input>
     </a-form-item>
     <a-form-item label="No SSE Header">
         <a-switch v-model="inbound.stream.xhttp.noSSEHeader"></a-switch>
     </a-form-item>
 </a-form>
-{{end}}
\ No newline at end of file
+{{end}}
diff --git a/web/html/inbounds.html b/web/html/inbounds.html
index 8f5c1891..90401e72 100644
--- a/web/html/inbounds.html
+++ b/web/html/inbounds.html
@@ -595,7 +595,7 @@
 <script src="{{ .base_path }}assets/qrcode/qrious2.min.js?{{ .cur_ver }}"></script>
 <script src="{{ .base_path }}assets/uri/URI.min.js?{{ .cur_ver }}"></script>
 <script src="{{ .base_path }}assets/js/model/reality_targets.js?{{ .cur_ver }}"></script>
-<script src="{{ .base_path }}assets/js/model/inbound.js?{{ .cur_ver }}"></script>
+<script src="{{ .base_path }}assets/js/model/inbound.js?{{ .cur_ver }}-xhttp-external-tls-v3"></script>
 <script src="{{ .base_path }}assets/js/model/dbinbound.js?{{ .cur_ver }}"></script>
 {{template "component/aSidebar" .}}
 {{template "component/aThemeSwitch" .}}
__XHTTP_PATCH_END__
__EXTERNAL_TLS_PATCH_BEGIN__
diff --git a/sub/subService.go b/sub/subService.go
index 5fe551b..1a9c055 100644
--- a/sub/subService.go
+++ b/sub/subService.go
@@ -571,16 +571,27 @@ func (s *SubService) genVlessLink(inbound *model.Inbound, email string) string {
 			port := int(ep["port"].(float64))
 			link := fmt.Sprintf("vless://%s@%s:%d", uuid, dest, port)
 
+			// Keep every External Proxy independent: params is shared by all
+			// generated links and must never be modified in place.
+			linkParams := make(map[string]string, len(params)+3)
+			for k, v := range params {
+				linkParams[k] = v
+			}
+			effectiveSecurity := security
 			if newSecurity != "same" {
-				params["security"] = newSecurity
-			} else {
-				params["security"] = security
+				effectiveSecurity = newSecurity
+			}
+			linkParams["security"] = effectiveSecurity
+			if effectiveSecurity == "tls" && security != "tls" && streamNetwork == "xhttp" {
+				linkParams["sni"] = dest
+				linkParams["fp"] = "chrome"
+				linkParams["alpn"] = "h2"
 			}
 			url, _ := url.Parse(link)
 			q := url.Query()
 
-			for k, v := range params {
-				if !(newSecurity == "none" && (k == "alpn" || k == "sni" || k == "fp")) {
+			for k, v := range linkParams {
+				if !(effectiveSecurity == "none" && (k == "alpn" || k == "sni" || k == "fp")) {
 					q.Add(k, v)
 				}
 			}
diff --git a/sub/subJsonService.go b/sub/subJsonService.go
index 72c5c6f..53eb1c3 100644
--- a/sub/subJsonService.go
+++ b/sub/subJsonService.go
@@ -170,12 +170,21 @@ func (s *SubJsonService) getConfig(inbound *model.Inbound, client model.Client,
 		extPrxy := ep.(map[string]any)
 		inbound.Listen = extPrxy["dest"].(string)
 		inbound.Port = int(extPrxy["port"].(float64))
-		newStream := stream
+		// Each External Proxy needs an independent client-side stream map.
+		streamBytes, _ := json.Marshal(stream)
+		newStream := make(map[string]any)
+		_ = json.Unmarshal(streamBytes, &newStream)
 		switch extPrxy["forceTls"].(string) {
 		case "tls":
 			if newStream["security"] != "tls" {
 				newStream["security"] = "tls"
-				newStream["tlsSettings"] = map[string]any{}
+				tlsSettings := map[string]any{}
+				if network, _ := newStream["network"].(string); network == "xhttp" {
+					tlsSettings["serverName"] = inbound.Listen
+					tlsSettings["alpn"] = []string{"h2"}
+					tlsSettings["fingerprint"] = "chrome"
+				}
+				newStream["tlsSettings"] = tlsSettings
 			}
 		case "none":
 			if newStream["security"] != "none" {
diff --git a/web/assets/js/model/inbound.js b/web/assets/js/model/inbound.js
index d3111ee..0c57f9d 100644
--- a/web/assets/js/model/inbound.js
+++ b/web/assets/js/model/inbound.js
@@ -1544,6 +1544,11 @@ class Inbound extends XrayCommonClass {
                 if (type == "tcp" && !ObjectUtil.isEmpty(flow)) {
                     params.set("flow", flow);
                 }
+            } else if (forceTls === 'tls' && type === 'xhttp') {
+                // External Proxy terminates TLS in front of the plain XHTTP inbound.
+                params.set("sni", address);
+                params.set("fp", UTLS_FINGERPRINT.UTLS_CHROME);
+                params.set("alpn", ALPN_OPTION.H2);
             }
         }
 
__EXTERNAL_TLS_PATCH_END__
__VLESSENC_VISION_PATCH_BEGIN__
diff --git a/web/assets/js/model/inbound.js b/web/assets/js/model/inbound.js
index a411706..cf6e83e 100644
--- a/web/assets/js/model/inbound.js
+++ b/web/assets/js/model/inbound.js
@@ -1375,18 +1375,24 @@ class Inbound extends XrayCommonClass {
         return exp > 0 ? exp < new Date().getTime() : false;
     }
 
-    canEnableTls() {
-        if (![Protocols.VMESS, Protocols.VLESS, Protocols.TROJAN, Protocols.SHADOWSOCKS].includes(this.protocol)) return false;
-        return ["tcp", "ws", "http", "grpc", "httpupgrade", "xhttp"].includes(this.network);
-    }
-
-    //this is used for xtls-rprx-vision
-    canEnableTlsFlow() {
-        if (((this.stream.security === 'tls') || (this.stream.security === 'reality')) && (this.network === "tcp")) {
-            return this.protocol === Protocols.VLESS;
-        }
-        return false;
-    }
+    canEnableTls() {
+        if (![Protocols.VMESS, Protocols.VLESS, Protocols.TROJAN, Protocols.SHADOWSOCKS].includes(this.protocol)) return false;
+        return ["tcp", "ws", "http", "grpc", "httpupgrade", "xhttp"].includes(this.network);
+    }
+
+    hasVlessEncryption() {
+        if (this.protocol !== Protocols.VLESS) return false;
+        const isSet = (value) => value !== undefined && value !== null && value !== '' && value !== 'none';
+        return isSet(this.settings?.encryption) || isSet(this.settings?.decryption);
+    }
+
+    //this is used for xtls-rprx-vision
+    canEnableTlsFlow() {
+        if (this.protocol !== Protocols.VLESS) return false;
+        if (this.network === 'tcp' && (this.stream.security === 'tls' || this.stream.security === 'reality')) return true;
+        if (this.network === 'xhttp' && this.hasVlessEncryption()) return true;
+        return false;
+    }
 
     // Vision seed applies only when vision flow is selected
     canEnableVisionSeed() {
@@ -1573,11 +1579,17 @@ class Inbound extends XrayCommonClass {
             }
         }
 
-        else {
-            params.set("security", "none");
-        }
-
-        const link = `vless://${uuid}@${address}:${port}`;
+        else {
+            params.set("security", "none");
+        }
+
+        // XHTTP carries Vision through VLESS Encryption itself, independently
+        // of the transport security (none/TLS/REALITY) and XHTTP mode.
+        if (type === 'xhttp' && this.hasVlessEncryption() && !ObjectUtil.isEmpty(flow)) {
+            params.set("flow", flow);
+        }
+
+        const link = `vless://${uuid}@${address}:${port}`;
         const url = new URL(link);
         for (const [key, value] of params) {
             url.searchParams.set(key, value)
diff --git a/web/html/modals/inbound_modal.html b/web/html/modals/inbound_modal.html
index fb44ac0..ce1247b 100644
--- a/web/html/modals/inbound_modal.html
+++ b/web/html/modals/inbound_modal.html
@@ -15,10 +15,15 @@
         isEdit: false,
         confirm: null,
         inbound: new Inbound(),
-        dbInbound: new DBInbound(),
-        ok() {
-            ObjectUtil.execute(inModal.confirm, inModal.inbound, inModal.dbInbound);
-        },
+        dbInbound: new DBInbound(),
+        ok() {
+            if (inModal.inbound.protocol === Protocols.VLESS && !inModal.inbound.canEnableTlsFlow()) {
+                inModal.inbound.settings.vlesses.forEach(client => {
+                    client.flow = "";
+                });
+            }
+            ObjectUtil.execute(inModal.confirm, inModal.inbound, inModal.dbInbound);
+        },
         show({ title = '', okText = '{{ i18n "sure" }}', inbound = null, dbInbound = null, confirm = (inbound, dbInbound) => { }, isEdit = false }) {
             this.title = title;
             this.okText = okText;
@@ -130,7 +135,7 @@
                 }
             }
         },
-        watch: {
+        watch: {
             'inModal.inbound.stream.security'(newVal, oldVal) {
                 // Clear flow when security changes from reality/tls to none
                 if (inModal.inbound.protocol == Protocols.VLESS && !inModal.inbound.canEnableTlsFlow()) {
@@ -140,7 +145,7 @@
                 }
             },
             // Ensure testseed is always initialized when vision flow is enabled
-            'inModal.inbound.settings.vlesses': {
+            'inModal.inbound.settings.vlesses': {
                 handler() {
                     if (inModal.inbound.protocol === Protocols.VLESS && inModal.inbound.settings && inModal.inbound.settings.vlesses) {
                         const hasVisionFlow = inModal.inbound.settings.vlesses.some(c => c.flow === 'xtls-rprx-vision' || c.flow === 'xtls-rprx-vision-udp443');
@@ -149,11 +154,24 @@
                         }
                     }
                 },
-                deep: true
-            }
-        },
-        methods: {
-            streamNetworkChange() {
+                deep: true
+            },
+            'inModal.inbound.settings.encryption'() {
+                this.clearVlessFlowIfUnsupported();
+            },
+            'inModal.inbound.settings.decryption'() {
+                this.clearVlessFlowIfUnsupported();
+            }
+        },
+        methods: {
+            clearVlessFlowIfUnsupported() {
+                if (inModal.inbound.protocol === Protocols.VLESS && !inModal.inbound.canEnableTlsFlow()) {
+                    inModal.inbound.settings.vlesses.forEach(client => {
+                        client.flow = "";
+                    });
+                }
+            },
+            streamNetworkChange() {
                 if (!inModal.inbound.canEnableTls()) {
                     this.inModal.inbound.stream.security = 'none';
                 }
@@ -296,4 +314,4 @@
     });
 
 </script>
-{{end}}
\ No newline at end of file
+{{end}}
diff --git a/sub/subService.go b/sub/subService.go
index 047f43b..1801e0e 100644
--- a/sub/subService.go
+++ b/sub/subService.go
@@ -411,6 +411,31 @@ func buildXHTTPLinkParams(xhttp map[string]any) map[string]string {
 	return params
 }
 
+// vlessEncryptionEnabled reports whether the inbound has a real generated
+// VLESS Encryption profile. "vlessenc" is the Xray subcommand name, not a
+// stored value; empty and "none" are the disabled sentinels.
+func vlessEncryptionEnabled(settings map[string]any) bool {
+	for _, key := range []string{"encryption", "decryption"} {
+		if value, ok := settings[key].(string); ok && value != "" && value != "none" {
+			return true
+		}
+	}
+	return false
+}
+
+// vlessFlowAllowed mirrors the panel UI: classic Vision uses TCP with TLS or
+// REALITY, while every XHTTP mode may use Vision when VLESS Encryption is on.
+func vlessFlowAllowed(network, security string, settings map[string]any) bool {
+	switch network {
+	case "tcp":
+		return security == "tls" || security == "reality"
+	case "xhttp":
+		return vlessEncryptionEnabled(settings)
+	default:
+		return false
+	}
+}
+
 func (s *SubService) genVlessLink(inbound *model.Inbound, email string) string {
 	var address string
 	if inbound.Listen == "" || inbound.Listen == "0.0.0.0" || inbound.Listen == "::" || inbound.Listen == "::0" {
@@ -556,11 +581,14 @@ func (s *SubService) genVlessLink(inbound *model.Inbound, email string) string {
 		}
 	}
 
-	if security != "tls" && security != "reality" {
-		params["security"] = "none"
-	}
-
-	externalProxies, _ := stream["externalProxy"].([]any)
+	if security != "tls" && security != "reality" {
+		params["security"] = "none"
+	}
+	if len(clients[clientIndex].Flow) > 0 && vlessFlowAllowed(streamNetwork, security, settings) {
+		params["flow"] = clients[clientIndex].Flow
+	}
+
+	externalProxies, _ := stream["externalProxy"].([]any)
 
 	if len(externalProxies) > 0 {
 		links := make([]string, 0, len(externalProxies))
diff --git a/web/html/inbounds.html b/web/html/inbounds.html
index 4794752..f3f1879 100644
--- a/web/html/inbounds.html
+++ b/web/html/inbounds.html
@@ -595,7 +595,7 @@
 <script src="{{ .base_path }}assets/qrcode/qrious2.min.js?{{ .cur_ver }}"></script>
 <script src="{{ .base_path }}assets/uri/URI.min.js?{{ .cur_ver }}"></script>
 <script src="{{ .base_path }}assets/js/model/reality_targets.js?{{ .cur_ver }}"></script>
-<script src="{{ .base_path }}assets/js/model/inbound.js?{{ .cur_ver }}-xhttp-external-tls-v3"></script>
+<script src="{{ .base_path }}assets/js/model/inbound.js?{{ .cur_ver }}-xhttp-vlessenc-vision-v4"></script>
 <script src="{{ .base_path }}assets/js/model/dbinbound.js?{{ .cur_ver }}"></script>
 {{template "component/aSidebar" .}}
 {{template "component/aThemeSwitch" .}}
diff --git a/sub/vless_flow_test.go b/sub/vless_flow_test.go
new file mode 100644
index 0000000..a7801ed
--- /dev/null
+++ b/sub/vless_flow_test.go
@@ -0,0 +1,215 @@
+package sub
+
+import (
+	"encoding/json"
+	"net/url"
+	"testing"
+
+	"github.com/mhsanaei/3x-ui/v2/database/model"
+)
+
+func TestVlessEncryptionEnabled(t *testing.T) {
+	tests := []struct {
+		name     string
+		settings map[string]any
+		want     bool
+	}{
+		{name: "missing", settings: map[string]any{}, want: false},
+		{name: "none", settings: map[string]any{"encryption": "none", "decryption": "none"}, want: false},
+		{name: "empty", settings: map[string]any{"encryption": "", "decryption": ""}, want: false},
+		{name: "client profile", settings: map[string]any{"encryption": "mlkem768x25519plus.native.0rtt.client"}, want: true},
+		{name: "server profile", settings: map[string]any{"decryption": "mlkem768x25519plus.native.0rtt.server"}, want: true},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			if got := vlessEncryptionEnabled(tt.settings); got != tt.want {
+				t.Fatalf("vlessEncryptionEnabled() = %v, want %v", got, tt.want)
+			}
+		})
+	}
+}
+
+func TestVlessFlowAllowed(t *testing.T) {
+	enabled := map[string]any{
+		"encryption": "mlkem768x25519plus.native.0rtt.client",
+		"decryption": "mlkem768x25519plus.native.0rtt.server",
+	}
+	disabled := map[string]any{"encryption": "none", "decryption": "none"}
+	tests := []struct {
+		name, network, security string
+		settings                map[string]any
+		want                    bool
+	}{
+		{name: "classic tcp tls", network: "tcp", security: "tls", settings: disabled, want: true},
+		{name: "classic tcp reality", network: "tcp", security: "reality", settings: disabled, want: true},
+		{name: "plain tcp remains disabled", network: "tcp", security: "none", settings: enabled, want: false},
+		{name: "xhttp none with vlessenc", network: "xhttp", security: "none", settings: enabled, want: true},
+		{name: "xhttp tls with vlessenc", network: "xhttp", security: "tls", settings: enabled, want: true},
+		{name: "xhttp reality with vlessenc", network: "xhttp", security: "reality", settings: enabled, want: true},
+		{name: "xhttp without vlessenc", network: "xhttp", security: "none", settings: disabled, want: false},
+		{name: "other transport", network: "ws", security: "tls", settings: enabled, want: false},
+	}
+
+	for _, tt := range tests {
+		t.Run(tt.name, func(t *testing.T) {
+			if got := vlessFlowAllowed(tt.network, tt.security, tt.settings); got != tt.want {
+				t.Fatalf("vlessFlowAllowed(%q, %q) = %v, want %v", tt.network, tt.security, got, tt.want)
+			}
+		})
+	}
+}
+
+func TestGenVlessLinkXHTTPVlessEncVision(t *testing.T) {
+	for _, security := range []string{"none", "tls", "reality"} {
+		t.Run(security, func(t *testing.T) {
+			inbound := newXHTTPVisionInbound(t, security, true)
+			link := NewSubService(false, "-ie").genVlessLink(inbound, "vision@example.com")
+			query := parseVlessLinkQuery(t, link)
+
+			if got := query.Get("flow"); got != "xtls-rprx-vision" {
+				t.Fatalf("flow = %q, want xtls-rprx-vision; link: %s", got, link)
+			}
+			values, ok := query["encryption"]
+			if !ok || len(values) != 1 || values[0] != "mlkem768x25519plus.native.0rtt.client" {
+				t.Fatalf("encryption parameter = %#v, want generated VLESSENC client profile; link: %s", values, link)
+			}
+		})
+	}
+}
+
+func TestGenVlessLinkXHTTPVisionWithoutVlessEnc(t *testing.T) {
+	inbound := newXHTTPVisionInbound(t, "none", false)
+	link := NewSubService(false, "-ie").genVlessLink(inbound, "vision@example.com")
+	query := parseVlessLinkQuery(t, link)
+
+	if got := query.Get("flow"); got != "" {
+		t.Fatalf("flow = %q, want no flow without VLESSENC; link: %s", got, link)
+	}
+	if values, ok := query["encryption"]; ok {
+		t.Fatalf("unexpected encryption parameter without VLESSENC: %#v; link: %s", values, link)
+	}
+}
+
+func newXHTTPVisionInbound(t *testing.T, security string, withVlessEnc bool) *model.Inbound {
+	t.Helper()
+
+	settings := map[string]any{
+		"clients": []model.Client{{
+			ID:     "11111111-1111-4111-8111-111111111111",
+			Email:  "vision@example.com",
+			Flow:   "xtls-rprx-vision",
+			Enable: true,
+		}},
+	}
+	if withVlessEnc {
+		settings["encryption"] = "mlkem768x25519plus.native.0rtt.client"
+		settings["decryption"] = "mlkem768x25519plus.native.0rtt.server"
+	}
+
+	stream := map[string]any{
+		"network":  "xhttp",
+		"security": security,
+		"xhttpSettings": map[string]any{
+			"mode": "packet-up",
+			"path": "/vision-test",
+		},
+	}
+	switch security {
+	case "tls":
+		stream["tlsSettings"] = map[string]any{
+			"alpn":       []string{"h2"},
+			"serverName": "tls.example.com",
+			"settings":   map[string]any{"fingerprint": "chrome"},
+		}
+	case "reality":
+		stream["realitySettings"] = map[string]any{
+			"serverNames": []string{"reality.example.com"},
+			"shortIds":    []string{"0123456789abcdef"},
+			"settings": map[string]any{
+				"publicKey":   "test-public-key",
+				"fingerprint": "chrome",
+			},
+		}
+	}
+
+	settingsJSON, err := json.Marshal(settings)
+	if err != nil {
+		t.Fatalf("marshal inbound settings: %v", err)
+	}
+	streamJSON, err := json.Marshal(stream)
+	if err != nil {
+		t.Fatalf("marshal stream settings: %v", err)
+	}
+
+	return &model.Inbound{
+		Listen:         "203.0.113.10",
+		Port:           443,
+		Protocol:       model.VLESS,
+		Settings:       string(settingsJSON),
+		StreamSettings: string(streamJSON),
+		Remark:         "xhttp-vlessenc",
+	}
+}
+
+func parseVlessLinkQuery(t *testing.T, link string) url.Values {
+	t.Helper()
+	parsed, err := url.Parse(link)
+	if err != nil {
+		t.Fatalf("parse VLESS link %q: %v", link, err)
+	}
+	return parsed.Query()
+}
+
+func TestBuildXHTTPLinkParamsKeepsV3AdvancedFields(t *testing.T) {
+	xhttp := map[string]any{
+		"mode":                "packet-up",
+		"path":                "/xhttp",
+		"host":                "origin.example",
+		"sessionIDPlacement":  "header",
+		"sessionIDKey":        "X-Session-ID",
+		"sessionIDTable":      "Base62",
+		"sessionIDLength":     "24-32",
+		"uplinkChunkSize":     "2048-3072",
+		"xPaddingBytes":       "32-96",
+		"xPaddingObfsMode":    true,
+		"xPaddingPlacement":   "header",
+		"xPaddingKey":         "X-Request-ID",
+		"xPaddingMethod":      "tokenish",
+		"uplinkHTTPMethod":    "POST",
+		"uplinkDataPlacement": "header",
+		"uplinkDataKey":       "X-Payload",
+		"seqPlacement":        "header",
+		"seqKey":              "X-Sequence",
+		"scMaxEachPostBytes":  "1000000",
+		"headers":             map[string]any{"Host": "origin.example", "X-Custom": "kept"},
+	}
+
+	params := buildXHTTPLinkParams(xhttp)
+	for _, key := range []string{"path", "host", "mode", "extra"} {
+		if params[key] == "" {
+			t.Fatalf("missing %s in XHTTP share parameters: %#v", key, params)
+		}
+	}
+	for _, token := range []string{
+		`"sessionIDTable":"Base62"`,
+		`"sessionIDLength":"24-32"`,
+		`"sessionPlacement":"header"`,
+		`"sessionKey":"X-Session-ID"`,
+		`"uplinkChunkSize":"2048-3072"`,
+		`"X-Custom":"kept"`,
+	} {
+		if !contains(params["extra"], token) {
+			t.Fatalf("extra does not contain %s: %s", token, params["extra"])
+		}
+	}
+}
+
+func contains(haystack, needle string) bool {
+	for i := 0; i+len(needle) <= len(haystack); i++ {
+		if haystack[i:i+len(needle)] == needle {
+			return true
+		}
+	}
+	return false
+}
__VLESSENC_VISION_PATCH_END__
__XHTTP_PATCH_EOF__
