#!/bin/sh
set -eu
umask 077

say() { printf '%s\n' "$*" >&2; }
die() { say "$*"; exit 1; }

os_value() {
  awk -F= -v key="$1" '$1 == key {value=substr($0,index($0,"=")+1); gsub(/^"|"$/,"",value); print value; exit}' /etc/os-release
}

hidden_input() {
  [ -r /dev/tty ] && [ -w /dev/tty ] || die "Нет терминала для ввода. Задайте VPS_PLATFORM_TOKEN"
  (
    terminal_state=$(stty -g < /dev/tty) || die "Не удалось открыть скрытый ввод"
    trap 'stty "$terminal_state" < /dev/tty >/dev/null 2>&1 || :' 0 1 2 15
    printf '%s: ' "$1" > /dev/tty
    stty -echo < /dev/tty
    IFS= read -r hidden_value < /dev/tty || die "Ввод прерван"
    printf '\n' > /dev/tty
    printf '%s' "$hidden_value"
  )
}

registry_get() {
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' --max-time 300 --config "$auth_file" --header "Accept: $1" --output "$2" "https://$registry/v2/$repository/installer/$3"
}

layer_tar() {
  if [ "$layer_gzip" = yes ]; then tar -z "$@"; else tar "$@"; fi
}

verify_digest() {
  [ "sha256:$(sha256sum "$1" | awk '{print $1}')" = "$2" ] || die "Контрольная сумма загруженного выпуска не совпала"
}

authorize() {
  printf 'user = "%s:%s"\n' "$username" "$token" > "$work/basic.curl"
  : > "$work/anonymous.curl"
  challenge=$(curl --silent --show-error --proto '=https' --max-time 60 --output /dev/null --dump-header - "https://$registry/v2/$repository/installer/manifests/$version" | tr -d '\r' | awk 'tolower($1) == "www-authenticate:" {sub(/^[^:]*:[ \t]*/, ""); print; exit}')
  case "$challenge" in
    '') auth_file=$work/anonymous.curl ;;
    [Bb]asic*) auth_file=$work/basic.curl ;;
    [Bb]earer*)
      realm=$(printf '%s' "$challenge" | sed -n 's/.*realm="\([^"]*\)".*/\1/p')
      service=$(printf '%s' "$challenge" | sed -n 's/.*service="\([^"]*\)".*/\1/p')
      case "$realm" in https://*) ;; *) die "Реестр образов предложил небезопасный вход" ;; esac
      curl --fail --silent --show-error --proto '=https' --max-time 60 --config "$work/basic.curl" --get --data-urlencode "service=$service" --data-urlencode "scope=repository:$repository/installer:pull" "$realm" > "$work/token.json" || die "Реестр не принял токен. Нужен классический токен GitHub с правом read:packages"
      registry_token=$(jq -er '(.token // .access_token) | select(type == "string" and test("^[A-Za-z0-9._~+/=-]+$"))' "$work/token.json") || die "Реестр не выдал доступ на чтение"
      rm -f "$work/token.json"
      printf 'header = "Authorization: Bearer %s"\n' "$registry_token" > "$work/bearer.curl"
      unset registry_token
      auth_file=$work/bearer.curl
      ;;
    *) die "Реестр образов требует неизвестный способ входа" ;;
  esac
}

download() {
  registry_get 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json' "$work/index.json" "manifests/$version" || die "Выпуск $version не найден или токен не подходит"
  manifest_digest=$(jq -er --arg arch "$architecture" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $arch)] | if length == 1 then .[0].digest else error("platform") end' "$work/index.json") || die "В выпуске нет установщика для $architecture"
  case "$manifest_digest" in sha256:*) ;; *) die "Неправильная ссылка на установщик" ;; esac
  registry_get 'application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' "$work/manifest.json" "manifests/$manifest_digest" || die "Не удалось загрузить описание установщика"
  verify_digest "$work/manifest.json" "$manifest_digest"
  mkdir "$work/installer"
  jq -er '.layers | if type == "array" and length > 0 and length <= 32 then .[] | [.digest, .mediaType] | @tsv else error("layers") end' "$work/manifest.json" > "$work/layers" || die "Неправильное описание установщика"
  while IFS="$(printf '\t')" read -r layer_digest layer_type; do
    case "$layer_digest" in sha256:*) ;; *) die "Неправильная ссылка на слой установщика" ;; esac
    case "$layer_digest" in *[!a-z0-9:]*) die "Неправильная ссылка на слой установщика" ;; esac
    registry_get '*/*' "$work/layer" "blobs/$layer_digest" || die "Не удалось загрузить слой установщика"
    verify_digest "$work/layer" "$layer_digest"
    case "$layer_type" in
      *tar+gzip|*tar.gzip) layer_gzip=yes ;;
      *tar) layer_gzip=no ;;
      *) die "Неизвестный формат слоя установщика" ;;
    esac
    layer_tar -tvf "$work/layer" > "$work/members"
    awk 'substr($0,1,1) != "-" && substr($0,1,1) != "d" {exit 1}' "$work/members" || die "Установщик содержит ссылки или специальные файлы"
    layer_tar -tf "$work/layer" > "$work/names"
    if grep -Eq '(^/|(^|/)\.\.(/|$))' "$work/names"; then die "Установщик содержит недопустимые пути"; fi
    layer_tar -xf "$work/layer" -C "$work/installer" --no-same-owner
    rm -f "$work/layer"
  done < "$work/layers"
  for required in release.json SHA256SUMS install-panel.sh restore-panel.sh lib/common.sh lib/panel.sh; do
    [ -f "$work/installer/$required" ] && [ ! -L "$work/installer/$required" ] || die "В выпуске нет файла $required"
  done
  (cd "$work/installer" && sha256sum --quiet -c SHA256SUMS) || die "Файлы установщика повреждены"
  release_version=$(jq -er '.version | select(type == "string" and test("^v[0-9]+[.][0-9]+[.][0-9]+$"))' "$work/installer/release.json") || die "Выпуск не содержит номер версии"
}

main() {
  registry=${VPS_PLATFORM_REGISTRY:-ghcr.io}
  repository=${VPS_PLATFORM_REPOSITORY:-hexquark/vps-platform}
  version=${VPS_PLATFORM_VERSION:-latest}
  directory=${VPS_PLATFORM_DIRECTORY:-/var/lib/vps-platform-installer}
  mode=${1:-install}
  case "$mode" in install|restore) ;; *) die "Запуск: curl -fsSL https://raw.githubusercontent.com/hexquark/vps-platform-install/main/install.sh | sudo sh -s [install|restore]" ;; esac
  [ "$(id -u)" = 0 ] || die "Запустите команду через sudo"
  [ "$(os_value ID)" = ubuntu ] || die "Нужна актуальная стабильная Ubuntu Server"
  case "$(uname -m)" in x86_64) architecture=amd64 ;; aarch64|arm64) architecture=arm64 ;; *) die "Архитектура VPS не поддерживается" ;; esac
  case "$registry" in ''|*[!a-z0-9.:-]*) die "Неправильный адрес реестра" ;; esac
  case "$repository" in ''|*[!a-z0-9./_-]*) die "Неправильное имя репозитория" ;; esac
  case "$version" in ''|*[!A-Za-z0-9._-]*) die "Неправильная версия" ;; esac
  case "$directory" in /*) ;; *) die "Нужен полный путь каталога установщика" ;; esac
  for needed in curl jq tar sha256sum stty; do
    if ! command -v "$needed" >/dev/null 2>&1; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl jq tar coreutils
      break
    fi
  done
  [ ! -L "$directory" ] || die "Каталог установщика не должен быть ссылкой"
  mkdir -p "$directory"
  chmod 0700 "$directory"
  work=$(mktemp -d "$directory/.download.XXXXXXXX")
  trap 'rm -rf "$work"' 0
  trap 'exit 1' 1 2 15
  token=${VPS_PLATFORM_TOKEN:-}
  [ -n "$token" ] || token=$(hidden_input 'Классический токен GitHub с правом read:packages')
  case "$token" in ''|*[!A-Za-z0-9_]*) die "Токен должен состоять из латинских букв, цифр и подчёркивания" ;; esac
  username=${VPS_PLATFORM_USERNAME:-}
  if [ -z "$username" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$token" > "$work/github.curl"
    curl --fail --silent --show-error --proto '=https' --max-time 60 --config "$work/github.curl" "${VPS_PLATFORM_GITHUB_API:-https://api.github.com}/user" > "$work/user.json" || die "GitHub не принял токен"
    username=$(jq -er '.login | select(type == "string")' "$work/user.json") || die "GitHub не назвал владельца токена"
  fi
  case "$username" in ''|*[!A-Za-z0-9-]*) die "Неправильное имя пользователя GitHub" ;; esac
  say "Загружается установщик VPS Platform ($version) из $registry."
  authorize
  download
  release_directory=$directory/releases/$release_version
  [ ! -L "$directory/releases" ] || die "Каталог выпусков не должен быть ссылкой"
  mkdir -p "$directory/releases"
  rm -rf "$release_directory"
  mv "$work/installer" "$release_directory"
  jq -n --arg registry "$registry" --arg repository "$repository" --arg username "$username" --arg token "$token" '{registry:$registry,repository:$repository,username:$username,token:$token}' > "$work/registry.json"
  mv "$work/registry.json" "$directory/registry.json"
  unset token
  say "Выпуск $release_version проверен."
  set -- "$release_directory/$mode-panel.sh"
  if [ -n "${VPS_PLATFORM_ANSWERS:-}" ]; then set -- "$@" --answers "$VPS_PLATFORM_ANSWERS"; fi
  REGISTRY_ACCESS_FILE=$directory/registry.json sh "$@" < /dev/null
}

main "$@"
