#!/usr/bin/env bash

set -euo pipefail
shopt -s nullglob
trap "rm -rf temp/*tmp.* temp/*/*tmp.* temp/*-temporary-files; exit 130" INT

if [ "${1-}" = "clean" ]; then
	rm -rf temp build logs build.md
	exit 0
fi

source utils.sh

jq --version >/dev/null || abort "\`jq\` is not installed. install it with 'apt install jq' or equivalent"
if [ -d "/usr/local/opt/openjdk@17" ]; then
    export JAVA_HOME="/usr/local/opt/openjdk@17"
    export PATH="/usr/local/opt/openjdk@17/bin:$PATH"
fi
java --version >/dev/null || abort "\`openjdk 17\` is not installed. install it with 'apt install openjdk-17-jre' or 'brew install openjdk@17'"
zip --version >/dev/null || abort "\`zip\` is not installed. install it with 'apt install zip' or equivalent"

set_prebuilts

vtf() { if ! isoneof "${1}" "true" "false"; then abort "ERROR: '${1}' is not a valid option for '${2}': only true or false is allowed"; fi; }

# -- Main config --
toml_prep "${1:-config.toml}" || abort "could not find config file '${1:-config.toml}'\n\tUsage: $0 <config.toml>"
main_config_t=$(toml_get_table_main)
COMPRESSION_LEVEL=$(toml_get "$main_config_t" compression-level) || COMPRESSION_LEVEL="9"
if ! PARALLEL_JOBS=$(toml_get "$main_config_t" parallel-jobs); then
	if [ "$OS" = Android ]; then PARALLEL_JOBS=1; else PARALLEL_JOBS=$(nproc); fi
fi
REMOVE_RV_INTEGRATIONS_CHECKS=$(toml_get "$main_config_t" remove-rv-integrations-checks) || REMOVE_RV_INTEGRATIONS_CHECKS="true"
DEF_PATCHES_VER=$(toml_get "$main_config_t" patches-version) || DEF_PATCHES_VER="latest"
DEF_CLI_VER=$(toml_get "$main_config_t" cli-version) || DEF_CLI_VER="latest"
DEF_PATCHES_SRC=$(toml_get "$main_config_t" patches-source) || DEF_PATCHES_SRC="ReVanced/revanced-patches"
DEF_CLI_SRC=$(toml_get "$main_config_t" cli-source) || DEF_CLI_SRC="ReVanced/revanced-cli"
DEF_RV_BRAND=$(toml_get "$main_config_t" rv-brand) || DEF_RV_BRAND="ReVanced"
DEF_DPI_LIST=$(toml_get "$main_config_t" dpi) || DEF_DPI_LIST="nodpi anydpi"
mkdir -p "$TEMP_DIR" "$BUILD_DIR"
reset_fail_reasons

if [ "${2-}" = "--config-update" ]; then
	config_update
	exit 0
fi

: >build.md
ENABLE_MODULE_UPDATE=$(toml_get "$main_config_t" enable-module-update) || ENABLE_MODULE_UPDATE=true
if [ "$ENABLE_MODULE_UPDATE" = true ] && [ -z "${GITHUB_REPOSITORY-}" ]; then
	pr "You are building locally. Module updates will not be enabled."
	ENABLE_MODULE_UPDATE=false
fi
if ((COMPRESSION_LEVEL > 9)) || ((COMPRESSION_LEVEL < 0)); then abort "compression-level must be within 0-9"; fi

rm -rf module/bin/*/tmp.*
for file in "$TEMP_DIR"/*/changelog.md; do
	[ -f "$file" ] && : >"$file"
done

mkdir -p ${MODULE_TEMPLATE_DIR}/bin/arm64 ${MODULE_TEMPLATE_DIR}/bin/arm ${MODULE_TEMPLATE_DIR}/bin/x86 ${MODULE_TEMPLATE_DIR}/bin/x64
gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-arm64-v8a"
gh_dl "${MODULE_TEMPLATE_DIR}/bin/arm/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-armeabi-v7a"
gh_dl "${MODULE_TEMPLATE_DIR}/bin/x86/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86"
gh_dl "${MODULE_TEMPLATE_DIR}/bin/x64/cmpr" "https://github.com/j-hc/cmpr/releases/latest/download/cmpr-x86_64"

idx=0
for table_name in $(toml_get_table_names); do
	if [ -z "$table_name" ]; then continue; fi
	t=$(toml_get_table "$table_name")
	if [ "$table_name" = "default" ]; then continue; fi
	enabled=$(toml_get "$t" enabled) || enabled=true
	vtf "$enabled" "enabled"
	if [ "$enabled" = false ]; then continue; fi
	if ((idx >= PARALLEL_JOBS)); then
		wait -n
		idx=$((idx - 1))
	fi

	declare app_args_cli=""
	declare app_args_ptjar=""
	declare app_args_rv_brand=""
	declare app_args_excluded_patches=""
	declare app_args_included_patches=""
	declare app_args_exclusive_patches=""
	declare app_args_version=""
	declare app_args_app_name=""
	declare app_args_patcher_args=""
	declare app_args_table=""
	declare app_args_build_mode=""
	declare app_args_uptodown_dlurl=""
	declare app_args_apkmirror_dlurl=""
	declare app_args_archive_dlurl=""
	declare app_args_dl_from=""
	declare app_args_arch=""
	declare app_args_include_stock=""
	declare app_args_dpi=""
	declare app_args_module_prop_name=""
	patches_src=$(toml_get "$t" patches-source) || patches_src=$DEF_PATCHES_SRC
	patches_ver=$(toml_get "$t" patches-version) || patches_ver=$DEF_PATCHES_VER
	cli_src=$(toml_get "$t" cli-source) || cli_src=$DEF_CLI_SRC
	cli_ver=$(toml_get "$t" cli-version) || cli_ver=$DEF_CLI_VER

	if ! PREBUILTS="$(get_prebuilts "$cli_src" "$cli_ver" "$patches_src" "$patches_ver")"; then
		abort "could not download rv prebuilts"
	fi
	read -r cli_jar patches_jar <<<"$PREBUILTS"
	app_args_cli=$cli_jar
	app_args_ptjar=$patches_jar
	app_args_rv_brand=$(toml_get "$t" rv-brand) || app_args_rv_brand=$DEF_RV_BRAND

	app_args_excluded_patches=$(toml_get "$t" excluded-patches) || app_args_excluded_patches=""
	if [ -n "$app_args_excluded_patches" ] && [[ $app_args_excluded_patches != *'"'* ]]; then abort "patch names inside excluded-patches must be quoted"; fi
	app_args_included_patches=$(toml_get "$t" included-patches) || app_args_included_patches=""
	if [ -n "$app_args_included_patches" ] && [[ $app_args_included_patches != *'"'* ]]; then abort "patch names inside included-patches must be quoted"; fi
	app_args_exclusive_patches=$(toml_get "$t" exclusive-patches) && vtf "$app_args_exclusive_patches" "exclusive-patches" || app_args_exclusive_patches=false
	app_args_version=$(toml_get "$t" version) || app_args_version="auto"
	app_args_app_name=$(toml_get "$t" app-name) || app_args_app_name=$table_name
	app_args_patcher_args=$(toml_get "$t" patcher-args) || app_args_patcher_args=""
	app_args_table=$table_name
	app_args_build_mode=$(toml_get "$t" build-mode) && {
		if ! isoneof "$app_args_build_mode" both apk module; then
			abort "ERROR: build-mode '$app_args_build_mode' is not a valid option for '$table_name': only 'both', 'apk' or 'module' is allowed"
		fi
	} || app_args_build_mode=apk
	app_args_uptodown_dlurl=$(toml_get "$t" uptodown-dlurl) && {
		app_args_uptodown_dlurl=${app_args_uptodown_dlurl%/}
		app_args_uptodown_dlurl=${app_args_uptodown_dlurl%download}
		app_args_uptodown_dlurl=${app_args_uptodown_dlurl%/}
		app_args_dl_from=uptodown
	} || app_args_uptodown_dlurl=""
	app_args_apkmirror_dlurl=$(toml_get "$t" apkmirror-dlurl) && {
		app_args_apkmirror_dlurl=${app_args_apkmirror_dlurl%/}
		app_args_dl_from=apkmirror
	} || app_args_apkmirror_dlurl=""
	app_args_archive_dlurl=$(toml_get "$t" archive-dlurl) && {
		app_args_archive_dlurl=${app_args_archive_dlurl%/}
		app_args_dl_from=archive
	} || app_args_archive_dlurl=""
	if [ -z "$app_args_dl_from" ]; then abort "ERROR: no 'apkmirror_dlurl', 'uptodown_dlurl' or 'archive_dlurl' option was set for '$table_name'."; fi
	app_args_arch=$(toml_get "$t" arch) || app_args_arch="all"
	if ! isoneof "$app_args_arch" "both" "all" "arm64-v8a" "arm-v7a" "x86_64" "x86"; then
		abort "wrong arch '$app_args_arch' for '$table_name'"
	fi

	app_args_include_stock=$(toml_get "$t" include-stock) || app_args_include_stock=true && vtf "$app_args_include_stock" "include-stock"
	app_args_dpi=$(toml_get "$t" dpi) || app_args_dpi="$DEF_DPI_LIST"
	table_name_f=$(echo "$table_name" | tr '[:upper:]' '[:lower:]')
	table_name_f=${table_name_f// /-}
	app_args_module_prop_name=$(toml_get "$t" module-prop-name) || app_args_module_prop_name="${table_name_f}-jhc"

	if [ "$app_args_arch" = both ]; then
		app_args_table="$table_name (arm64-v8a)"
		app_args_arch="arm64-v8a"
		module_prop_name_b=$app_args_module_prop_name
		app_args_module_prop_name="${module_prop_name_b}-arm64"
		idx=$((idx + 1))
		build_rv "$app_args_cli|$app_args_ptjar|$app_args_rv_brand|$app_args_excluded_patches|$app_args_included_patches|$app_args_exclusive_patches|$app_args_version|$app_args_app_name|$app_args_patcher_args|$app_args_table|$app_args_build_mode|$app_args_uptodown_dlurl|$app_args_apkmirror_dlurl|$app_args_archive_dlurl|$app_args_dl_from|$app_args_arch|$app_args_include_stock|$app_args_dpi|$app_args_module_prop_name" &
		app_args_table="$table_name (arm-v7a)"
		app_args_arch="arm-v7a"
		app_args_module_prop_name="${module_prop_name_b}-arm"
		if ((idx >= PARALLEL_JOBS)); then
			wait -n
			idx=$((idx - 1))
		fi
		idx=$((idx + 1))
		build_rv "$app_args_cli|$app_args_ptjar|$app_args_rv_brand|$app_args_excluded_patches|$app_args_included_patches|$app_args_exclusive_patches|$app_args_version|$app_args_app_name|$app_args_patcher_args|$app_args_table|$app_args_build_mode|$app_args_uptodown_dlurl|$app_args_apkmirror_dlurl|$app_args_archive_dlurl|$app_args_dl_from|$app_args_arch|$app_args_include_stock|$app_args_dpi|$app_args_module_prop_name" &
	else
		if [ "$app_args_arch" = "arm64-v8a" ]; then
			app_args_module_prop_name="${app_args_module_prop_name}-arm64"
		elif [ "$app_args_arch" = "arm-v7a" ]; then
			app_args_module_prop_name="${app_args_module_prop_name}-arm"
		fi
		idx=$((idx + 1))
		build_rv "$app_args_cli|$app_args_ptjar|$app_args_rv_brand|$app_args_excluded_patches|$app_args_included_patches|$app_args_exclusive_patches|$app_args_version|$app_args_app_name|$app_args_patcher_args|$app_args_table|$app_args_build_mode|$app_args_uptodown_dlurl|$app_args_apkmirror_dlurl|$app_args_archive_dlurl|$app_args_dl_from|$app_args_arch|$app_args_include_stock|$app_args_dpi|$app_args_module_prop_name" &
	fi
done
wait
rm -rf temp/tmp.*
if [ -z "$(ls -A1 "${BUILD_DIR}")" ]; then
	if [ -s "$FAIL_SUMMARY_FILE" ]; then
		epr "Build failure summary:"
		while IFS= read -r failure_line; do
			[ -n "$failure_line" ] || continue
			epr "  ${failure_line}"
		done <"$FAIL_SUMMARY_FILE"
	fi
	abort "All builds failed."
fi

log "\nInstall [Microg](https://github.com/ReVanced/GmsCore/releases) for non-root YouTube and YT Music APKs"
log "Use [zygisk-detach](https://github.com/j-hc/zygisk-detach) to detach YouTube and YT Music modules from Play Store"
log "\n[revanced-magisk-module](https://github.com/j-hc/revanced-magisk-module)\n"
log "$(cat "$TEMP_DIR"/*/changelog.md)"

SKIPPED=$(cat "$TEMP_DIR"/skipped 2>/dev/null || :)
if [ -n "$SKIPPED" ]; then
	log "\nSkipped:"
	log "$SKIPPED"
fi

pr "Done"
