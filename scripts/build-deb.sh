#!/usr/bin/env bash
set -euo pipefail

PACKAGE_NAME="broadcast-box"
MAINTAINER="Broadcast Box Maintainers <noreply@example.com>"
DESCRIPTION="WHIP/WHEP WebRTC broadcast server with bundled web UI"

usage() {
	cat <<'EOF'
Usage: ./scripts/build-deb.sh <version>

Builds a local Debian package:
  dist/broadcast-box_<version>_amd64.deb
Then uploads it to the matching GitHub release tag:
  v<version>

Environment overrides:
  DEB_ARCH      Debian architecture, default: amd64
  GOARCH        Go architecture override. Inferred from DEB_ARCH by default.
  SKIP_TESTS    Set to 1 to skip `go test ./...`.
  SKIP_WEB      Set to 1 to reuse the existing web/build directory.
  SKIP_RELEASE_UPLOAD
                Set to 1 to build the package without creating/updating a
                GitHub release.
  RELEASE_TAG   GitHub release tag override, default: v<version>.

Examples:
  ./scripts/build-deb.sh 0.1.0
  DEB_ARCH=arm64 ./scripts/build-deb.sh 0.1.0
  SKIP_RELEASE_UPLOAD=1 ./scripts/build-deb.sh 0.1.0
EOF
}

fail() {
	echo "error: $*" >&2
	exit 1
}

install_hint() {
	case "$1" in
		go)
			cat <<'EOF'
  go: sudo apt-get update && sudo apt-get install -y golang-go
      If that Go version is too old for go.mod, install current Go from https://go.dev/dl/.
EOF
			;;
		npm)
			cat <<'EOF'
  npm: sudo apt-get update && sudo apt-get install -y nodejs npm
      If the distro Node.js is too old, install the current LTS from https://nodejs.org/.
EOF
			;;
		dpkg-deb)
			echo "  dpkg-deb: sudo apt-get update && sudo apt-get install -y dpkg-dev"
			;;
		gh)
			echo "  gh: install GitHub CLI from https://cli.github.com/ and run 'gh auth login'"
			;;
		install|realpath)
			echo "  $1: sudo apt-get update && sudo apt-get install -y coreutils"
			;;
		*)
			echo "  $1: install the package that provides '$1' for your distribution"
			;;
	esac
}

check_prerequisites() {
	local missing=()
	local cmd

	for cmd in "$@"; do
		if ! command -v "$cmd" >/dev/null 2>&1; then
			missing+=("$cmd")
		fi
	done

	if (( ${#missing[@]} == 0 )); then
		return 0
	fi

	echo "error: missing required build command(s): ${missing[*]}" >&2
	echo >&2
	echo "Install them with:" >&2
	for cmd in "${missing[@]}"; do
		install_hint "$cmd" >&2
	done
	exit 1
}

clean_dir() {
	local target resolved_dist resolved_target
	target="$1"
	resolved_dist="$(realpath -m "$DIST_DIR")"
	resolved_target="$(realpath -m "$target")"

	case "$resolved_target" in
		"$resolved_dist"/*)
			rm -rf "$resolved_target"
			;;
		*)
			fail "refusing to remove path outside dist: $resolved_target"
			;;
	esac
}

upload_release_asset() {
	local release_tag release_title target_commit
	release_tag="${RELEASE_TAG:-v$version}"
	release_title="$PACKAGE_NAME $version"

	if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
		fail "release upload must run inside a git repository"
	fi

	if ! git diff --quiet || ! git diff --cached --quiet; then
		echo "warning: working tree has uncommitted changes; release tag will point at HEAD" >&2
	fi

	target_commit="$(git rev-parse HEAD)"

	echo "==> Uploading $output_deb to GitHub release $release_tag"
	if gh release view "$release_tag" >/dev/null 2>&1; then
		gh release upload "$release_tag" "$output_deb" --clobber
	else
		gh release create "$release_tag" "$output_deb" \
			--target "$target_commit" \
			--title "$release_title" \
			--notes "Release $version"
	fi
}

version="${1:-}"
if [[ -z "$version" || "${version:-}" == "-h" || "${version:-}" == "--help" ]]; then
	usage
	if [[ -z "$version" ]]; then
		exit 1
	fi
	exit 0
fi

if [[ ! "$version" =~ ^[0-9][A-Za-z0-9.+:~_-]*$ ]]; then
	fail "invalid Debian version: $version"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST_DIR="$REPO_ROOT/dist"
BUILD_DIR="$DIST_DIR/build"
WORK_DIR="$DIST_DIR/deb-work"

deb_arch="${DEB_ARCH:-amd64}"
case "$deb_arch" in
	amd64)
		go_arch="${GOARCH:-amd64}"
		;;
	arm64)
		go_arch="${GOARCH:-arm64}"
		;;
	armhf)
		go_arch="${GOARCH:-arm}"
		;;
	*)
		go_arch="${GOARCH:-$deb_arch}"
		;;
esac

pkg_root="$WORK_DIR/${PACKAGE_NAME}_${version}_${deb_arch}"
output_deb="$DIST_DIR/${PACKAGE_NAME}_${version}_${deb_arch}.deb"

required_commands=(go npm dpkg-deb install realpath)
if [[ "${SKIP_RELEASE_UPLOAD:-0}" != "1" ]]; then
	required_commands+=(git gh)
fi
check_prerequisites "${required_commands[@]}"

cd "$REPO_ROOT"

if [[ ! -f go.mod ]]; then
	fail "must be run from the broadcast-box repository"
fi

mkdir -p "$DIST_DIR"
clean_dir "$BUILD_DIR"
clean_dir "$pkg_root"
rm -f "$output_deb"

mkdir -p "$BUILD_DIR" "$pkg_root/DEBIAN"

if [[ "${SKIP_WEB:-0}" != "1" ]]; then
	echo "==> Building frontend"
	(
		cd "$REPO_ROOT/web"
		npm ci
		npm run build
	)
elif [[ ! -d "$REPO_ROOT/web/build" ]]; then
	fail "SKIP_WEB=1 was set, but web/build does not exist"
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
	echo "==> Running Go tests"
	go test ./...
fi

echo "==> Building Go binary for linux/$go_arch"
CGO_ENABLED=0 GOOS=linux GOARCH="$go_arch" \
	go build -trimpath -ldflags "-s -w" -o "$BUILD_DIR/broadcast-box" .

echo "==> Assembling Debian filesystem"
install -Dm0755 "$BUILD_DIR/broadcast-box" "$pkg_root/usr/bin/broadcast-box"
install -Dm0755 "$REPO_ROOT/packaging/scripts/update-nat-ip.sh" "$pkg_root/usr/lib/broadcast-box/update-nat-ip.sh"

install -Dm0644 "$REPO_ROOT/packaging/etc/broadcast-box.env" "$pkg_root/etc/broadcast-box/broadcast-box.env"
install -Dm0644 "$REPO_ROOT/packaging/systemd/broadcast-box.service" "$pkg_root/lib/systemd/system/broadcast-box.service"
install -Dm0644 "$REPO_ROOT/packaging/systemd/broadcast-box-nat-refresh.service" "$pkg_root/lib/systemd/system/broadcast-box-nat-refresh.service"
install -Dm0644 "$REPO_ROOT/packaging/systemd/broadcast-box-nat-refresh.timer" "$pkg_root/lib/systemd/system/broadcast-box-nat-refresh.timer"

install -Dm0755 "$REPO_ROOT/packaging/debian/postinst" "$pkg_root/DEBIAN/postinst"
install -Dm0755 "$REPO_ROOT/packaging/debian/prerm" "$pkg_root/DEBIAN/prerm"
install -Dm0755 "$REPO_ROOT/packaging/debian/postrm" "$pkg_root/DEBIAN/postrm"

mkdir -p "$pkg_root/usr/lib/broadcast-box/web/build"
cp -a "$REPO_ROOT/web/build/." "$pkg_root/usr/lib/broadcast-box/web/build/"

install -d "$pkg_root/usr/share/doc/broadcast-box"
install -m0644 "$REPO_ROOT/README.md" "$pkg_root/usr/share/doc/broadcast-box/README.md"
install -m0644 "$REPO_ROOT/packaging/README.md" "$pkg_root/usr/share/doc/broadcast-box/README.Debian.md"
install -m0644 "$REPO_ROOT/LICENSE" "$pkg_root/usr/share/doc/broadcast-box/copyright"

cat > "$pkg_root/DEBIAN/conffiles" <<EOF
/etc/broadcast-box/broadcast-box.env
EOF

installed_size="$(du -sk "$pkg_root" | awk '{ print $1 }')"
cat > "$pkg_root/DEBIAN/control" <<EOF
Package: $PACKAGE_NAME
Version: $version
Section: web
Priority: optional
Architecture: $deb_arch
Maintainer: $MAINTAINER
Depends: adduser
Installed-Size: $installed_size
Homepage: https://github.com/glimesh/broadcast-box
Description: $DESCRIPTION
 Broadcast Box is a Go backend and React frontend for WHIP ingest and WHEP
 playback. This package installs the server, bundled web assets, systemd units,
 and a Dynamic DNS NAT refresh helper for single-port UDP deployments.
EOF

echo "==> Building Debian package"
dpkg-deb --root-owner-group --build "$pkg_root" "$output_deb"

echo "==> Built $output_deb"

if [[ "${SKIP_RELEASE_UPLOAD:-0}" != "1" ]]; then
	upload_release_asset
fi
