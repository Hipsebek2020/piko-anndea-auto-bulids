#!/usr/bin/env bash

# Use newer bash if available
if [ -x "/usr/local/bin/bash" ]; then
    exec /usr/local/bin/bash "$0" "$@"
fi

MODULE_TEMPLATE_DIR="module"
CWD=$(pwd)
TEMP_DIR="temp"
BIN_DIR="bin"
BUILD_DIR="build"
FAIL_SUMMARY_FILE="${TEMP_DIR}/failures.log"

if [ "${GITHUB_TOKEN-}" ]; then GH_HEADER="Authorization: token ${GITHUB_TOKEN}"; else GH_HEADER=; fi
NEXT_VER_CODE=${NEXT_VER_CODE:-$(date +'%Y%m%d')}
OS=$(uname -o)

toml_prep() {
	if [ ! -f "$1" ]; then return 1; fi
	if [ "${1##*.}" == toml ]; then
		__TOML__=$(yq -o json "$1")
	elif [ "${1##*.}" == json ]; then
		__TOML__=$(cat "$1")
	else abort "config extension not supported"; fi
}
toml_get_table_names() { jq -r -e 'to_entries[] | select(.value | type == "object") | .key' <<<"$__TOML__"; }
toml_get_table_main() { jq -r -e 'to_entries | map(select(.value | type != "object")) | from_entries' <<<"$__TOML__"; }
toml_get_table() { jq -r -e ".\"${1}\"" <<<"$__TOML__"; }
toml_get() {
	local op quote_placeholder=$'\001'
	op=$(jq -r ".\"${2}\" | if type == \"array\" then join(\" \") else values end" <<<"$1")
	if [ "$op" ]; then
		op="${op#"${op%%[![:space:]]*}"}"
		op="${op%"${op##*[![:space:]]}"}"
		op=${op//\\\'/$quote_placeholder}
		op=${op//"''"/$quote_placeholder}
		op=${op//"'"/'"'}
		op=${op//$quote_placeholder/$'\''}
		echo "$op"
	else return 1; fi
}

pr() { echo -e "\033[0;32m[+] ${1}\033[0m"; }
epr() {
	echo >&2 -e "\033[0;31m[-] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::error::utils.sh [-] ${1}\n"; fi
}
wpr() {
	echo >&2 -e "\033[0;33m[!] ${1}\033[0m"
	if [ "${GITHUB_REPOSITORY-}" ]; then echo >&2 -e "::warning::utils.sh [!] ${1}\n"; fi
}
abort() {
	epr "ABORT: ${1-}"
	exit 1
}
java() { 
    if [ -d "/usr/local/opt/openjdk@17" ]; then
        env -i JAVA_HOME="/usr/local/opt/openjdk@17" PATH="/usr/local/opt/openjdk@17/bin:$PATH" /usr/local/opt/openjdk@17/bin/java "$@"
    else
        env -i java "$@"
    fi
}

reset_fail_reasons() {
	[ -d "$TEMP_DIR" ] || mkdir -p "$TEMP_DIR"
	: >"$FAIL_SUMMARY_FILE"
}

add_fail_reason() {
	local table=$1 reason=$2
	[ -n "$table" ] || table="unknown"
	echo "[$table] $reason" >>"$FAIL_SUMMARY_FILE"
}

extract_asset_version() {
	local name=$1
	grep -oE '[0-9]+([.][0-9]+)+([-.][A-Za-z0-9]+([.][A-Za-z0-9]+)*)?' <<<"$name" | head -1 || :
}

pick_best_named_candidate() {
	local context=$1
	local count=0 parsed_count=0
	local first_line="" names_list="" ver_rows=""
	local name url ver
	while IFS=$'\t' read -r name url; do
		[ -n "${name:-}" ] || continue
		count=$((count + 1))
		if [ -z "$first_line" ]; then first_line="${name}"$'\t'"${url}"; fi
		if [ -n "$names_list" ]; then names_list+=", "; fi
		names_list+="$name"
		ver=$(extract_asset_version "$name")
		if [ -n "$ver" ]; then
			parsed_count=$((parsed_count + 1))
			ver_rows+="${ver}"$'\t'"${name}"$'\t'"${url}"$'\n'
		fi
	done

	if [ "$count" -eq 0 ]; then
		return 1
	fi

	if [ "$count" -gt 1 ]; then
		if [ "$parsed_count" -eq 0 ]; then
			wpr "More than 1 asset was found for ${context}; no parseable version found, falling back to the first one. Candidates: ${names_list}"
			echo "$first_line"
			return 0
		fi
		local best_ver selected
		best_ver=$(cut -f1 <<<"$ver_rows" | get_highest_ver)
		selected=$(awk -F'\t' -v bv="$best_ver" '$1 == bv { print $2 "\t" $3; exit }' <<<"$ver_rows")
		if [ -n "$selected" ]; then
			wpr "More than 1 asset was found for ${context}; selected highest version '${best_ver}'. Candidates: ${names_list}"
			echo "$selected"
			return 0
		fi
	fi

	echo "$first_line"
}

get_release_asset_candidates() {
	local resp=$1 tag=$2 ver=$3
	local candidates

	if [ "$tag" = "CLI" ]; then
		candidates=$(jq -r '.assets[]? | select(.name | endswith("asc") | not) | select(.name | test("-all\\.jar$")) | [.name, .url] | @tsv' <<<"$resp")
		if [ "$ver" = "latest" ] && [ -n "$candidates" ]; then
			local non_dev
			non_dev=$(grep -v -- '-dev' <<<"$candidates" || :)
			if [ -n "$non_dev" ]; then candidates=$non_dev; fi
		fi
	elif [ "$tag" = "Patches" ]; then
		candidates=$(jq -r '.assets[]? | select(.name | endswith(".rvp")) | [.name, .url] | @tsv' <<<"$resp")
	else
		abort "unknown prebuilt tag '$tag'"
	fi

	if [ -n "$candidates" ]; then
		echo "$candidates"
		return 0
	fi

	local all_assets
	all_assets=$(jq -r '.assets[]? | select(.name | endswith("asc") | not) | .name' <<<"$resp" | paste -sd ', ' -)
	if [ -z "$all_assets" ]; then all_assets="(none)"; fi
	abort "No matching ${tag} asset was found. Available assets: ${all_assets}"
}

get_prebuilts() {
	local cli_src=$1 cli_ver=$2 patches_src=$3 patches_ver=$4
	pr "Getting prebuilts (${patches_src%/*})" >&2
	local cl_dir=${patches_src%/*}
	cl_dir=$(echo "$cl_dir" | tr '[:upper:]' '[:lower:]')
	cl_dir="${TEMP_DIR}/${cl_dir}-rv"
	[ -d "$cl_dir" ] || mkdir "$cl_dir"

	for src_ver in "$cli_src CLI $cli_ver cli" "$patches_src Patches $patches_ver patches"; do
		set -- $src_ver
		local src=$1 tag=$2 ver=${3-} fprefix=$4

		if [ "$tag" = "CLI" ]; then
			local grab_cl=false
		elif [ "$tag" = "Patches" ]; then
			local grab_cl=true
		else abort unreachable; fi

		local dir=${src%/*}
		dir=$(echo "${dir}" | tr '[:upper:]' '[:lower:]')
		dir="${TEMP_DIR}/${dir}-rv"
		[ -d "$dir" ] || mkdir "$dir"

		local rv_rel="https://api.github.com/repos/${src}/releases" name_ver
		if [ "$ver" = "dev" ]; then
			local resp
			resp=$(gh_req "$rv_rel" -) || return 1
			ver=$(jq -e -r '.[] | .tag_name' <<<"$resp" | get_highest_ver) || return 1
		fi
		if [ "$ver" = "latest" ]; then
			rv_rel+="/latest"
			name_ver="*"
		else
			rv_rel+="/tags/${ver}"
			name_ver="$ver"
		fi

		local url file tag_name name
		file=$(find "$dir" -name "*${fprefix}-${name_ver#v}.*" -type f 2>/dev/null)
		if [ -z "$file" ]; then
			local resp candidates asset_line
			resp=$(gh_req "$rv_rel" -) || return 1
			tag_name=$(jq -r '.tag_name' <<<"$resp")
			candidates=$(get_release_asset_candidates "$resp" "$tag" "$ver")
			asset_line=$(pick_best_named_candidate "${src} (${tag} ${tag_name})" <<<"$candidates") || return 1
			name=$(cut -f1 <<<"$asset_line")
			url=$(cut -f2 <<<"$asset_line")
			file="${dir}/${name}"
			gh_dl "$file" "$url" >&2 || return 1
			echo "$tag: $(cut -d/ -f1 <<<"$src")/${name}  " >>"${cl_dir}/changelog.md"
		else
			grab_cl=false
			local for_err=$file
			if [ "$ver" = "latest" ]; then
				local non_dev_files
				non_dev_files=$(grep -v '/[^/]*dev[^/]*$' <<<"$file" || :)
				if [ -n "$non_dev_files" ]; then file=$non_dev_files; fi
			else file=$(grep "/[^/]*${ver#v}[^/]*\$" <<<"$file" | head -1); fi
			if [ -z "$file" ]; then abort "filter fail: '$for_err' with '$ver'"; fi
			local cached_candidates="" fpath fname
			while IFS= read -r fpath; do
				[ -n "$fpath" ] || continue
				fname=$(basename "$fpath")
				cached_candidates+="${fname}"$'\t'"${fpath}"$'\n'
			done <<<"$file"
			file=$(pick_best_named_candidate "${src} cached ${tag}" <<<"$cached_candidates" | cut -f2)
			name=$(basename "$file")
			tag_name=$(cut -d'-' -f3- <<<"$name")
			tag_name=v${tag_name%.*}
		fi

		if [ "$tag" = "Patches" ]; then
			if [ $grab_cl = true ]; then echo -e "[Changelog](https://github.com/${src}/releases/tag/${tag_name})\n" >>"${cl_dir}/changelog.md"; fi
			if [ "$REMOVE_RV_INTEGRATIONS_CHECKS" = true ]; then
				local shared_entry work_dir shared_file shared_patched extensions_ext tmp_file patch_op
				shared_entry=$(unzip -Z1 "${file}" "extensions/shared.*" 2>/dev/null | head -1 || :)
				if [ -z "$shared_entry" ]; then
					wpr "Patching revanced-integrations skipped for '${name}': no extensions/shared.* found"
				else
					work_dir="${file}-zip"
					rm -rf "$work_dir"
					if ! mkdir -p "$work_dir" || ! unzip -qo "${file}" -d "$work_dir"; then
						wpr "Patching revanced-integrations failed for '${name}': could not prepare temporary archive"
						rm -rf "$work_dir" || :
					else
						extensions_ext="${shared_entry##*.}"
						shared_file="${work_dir}/${shared_entry}"
						shared_patched="${work_dir}/extensions/shared-patched.${extensions_ext}"
						if ! patch_op=$(java -cp "${BIN_DIR}/paccer.jar:${BIN_DIR}/dexlib2.jar" com.jhc.Main "$shared_file" "$shared_patched" 2>&1); then
							patch_op=$(tail -n 1 <<<"$patch_op")
							[ -n "$patch_op" ] || patch_op="unknown error"
							wpr "Patching revanced-integrations failed for '${name}': ${patch_op}"
						elif [ ! -f "$shared_patched" ]; then
							wpr "Patching revanced-integrations failed for '${name}': patched shared file was not generated"
						elif ! mv -f "$shared_patched" "$shared_file"; then
							wpr "Patching revanced-integrations failed for '${name}': could not replace shared extension"
						else
							tmp_file="${file}.tmp"
							if (cd "$work_dir" && zip -0rq "${CWD}/${tmp_file}" .); then
								mv -f "$tmp_file" "$file"
							else
								rm -f "$tmp_file" || :
								wpr "Patching revanced-integrations failed for '${name}': could not re-pack archive"
							fi
						fi
						rm -rf "$work_dir" || :
					fi
				fi
			fi
		fi
		echo -n "$file "
	done
	echo
}

set_prebuilts() {
	APKSIGNER="${BIN_DIR}/apksigner.jar"
	local arch
	arch=$(uname -m)
	if [ "$arch" = aarch64 ]; then arch=arm64; elif [ "${arch:0:5}" = "armv7" ]; then arch=arm; fi
	local htmlq_bin="${BIN_DIR}/htmlq/htmlq-${arch}"
	if [ -x "$htmlq_bin" ]; then
		HTMLQ="$htmlq_bin"
	else
		HTMLQ="htmlq"
	fi
	AAPT2="${BIN_DIR}/aapt2/aapt2-${arch}"
	TOML="yq"
}

config_update() {
	if [ ! -f build.md ]; then abort "build.md not available"; fi
	declare -A sources
	: >"$TEMP_DIR"/skipped
	local upped=()
	local prcfg=false
	for table_name in $(toml_get_table_names); do
		if [ -z "$table_name" ]; then continue; fi
		t=$(toml_get_table "$table_name")
		enabled=$(toml_get "$t" enabled) || enabled=true
		if [ "$enabled" = "false" ]; then continue; fi
		PATCHES_SRC=$(toml_get "$t" patches-source) || PATCHES_SRC=$DEF_PATCHES_SRC
		PATCHES_VER=$(toml_get "$t" patches-version) || PATCHES_VER=$DEF_PATCHES_VER
		if [ -n "${sources["$PATCHES_SRC/$PATCHES_VER"]:-}" ]; then
			if [ "${sources["$PATCHES_SRC/$PATCHES_VER"]}" = 1 ]; then upped+=("$table_name"); fi
		else
			sources["$PATCHES_SRC/$PATCHES_VER"]=0
			local rv_rel="https://api.github.com/repos/${PATCHES_SRC}/releases"
			if [ "$PATCHES_VER" = "dev" ]; then
				last_patches=$(gh_req "$rv_rel" - | jq -e -r '.[0]')
			elif [ "$PATCHES_VER" = "latest" ]; then
				last_patches=$(gh_req "$rv_rel/latest" -)
			else
				last_patches=$(gh_req "$rv_rel/tags/${ver}" -)
			fi
			if ! last_patches=$(jq -e -r '.assets[] | select(.name | endswith("asc") | not) | .name' <<<"$last_patches"); then
				abort oops
			fi
			if [ "$last_patches" ]; then
				if ! OP=$(grep "^Patches: ${PATCHES_SRC%%/*}/" build.md | grep -m1 "$last_patches"); then
					sources["$PATCHES_SRC/$PATCHES_VER"]=1
					prcfg=true
					upped+=("$table_name")
				else
					echo "$OP" >>"$TEMP_DIR"/skipped
				fi
			fi
		fi
	done
	if [ "$prcfg" = true ]; then
		local query=""
		for table in "${upped[@]}"; do
			if [ -n "$query" ]; then query+=" or "; fi
			query+=".key == \"$table\""
		done
		jq "to_entries | map(select(${query} or (.value | type != \"object\"))) | from_entries" <<<"$__TOML__"
	fi
}

_req() {
	local ip="$1" op="$2"
	shift 2
	if [ "$op" = - ]; then
		if ! curl -L --compressed -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --retry 0 --fail -s -S "$@" "$ip"; then
			epr "Request failed: $ip"
			return 1
		fi
	else
		if [ -f "$op" ]; then return; fi
		local dlp
		dlp="$(dirname "$op")/tmp.$(basename "$op")"
		if [ -f "$dlp" ]; then
			while [ -f "$dlp" ]; do sleep 1; done
			return
		fi
		if ! curl -L --compressed -c "$TEMP_DIR/cookie.txt" -b "$TEMP_DIR/cookie.txt" --connect-timeout 5 --retry 0 --fail -s -S "$@" "$ip" -o "$dlp"; then
			epr "Request failed: $ip"
			return 1
		fi
		mv -f "$dlp" "$op"
	fi
}
req() { _req "$1" "$2" -H "User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8" -H "Accept-Language: en-US,en;q=0.5" -H "Accept-Encoding: gzip, deflate, br" -H "DNT: 1" -H "Connection: keep-alive" -H "Upgrade-Insecure-Requests: 1"; }
gh_req() { _req "$1" "$2" -H "$GH_HEADER"; }
gh_dl() {
	if [ ! -f "$1" ]; then
		pr "Getting '$1' from '$2'"
		_req "$2" "$1" -H "$GH_HEADER" -H "Accept: application/octet-stream"
	fi
}

log() { echo -e "$1  " >>"build.md"; }
get_highest_ver() {
	local vers m
	vers=$(tee)
	m=$(head -1 <<<"$vers")
	if ! semver_validate "$m"; then echo "$m"; else sort -rV <<<"$vers" | head -1; fi
}
semver_validate() {
	local a="${1%-*}"
	local a="${a#v}"
	local ac="${a//[.0-9]/}"
	[ ${#ac} = 0 ]
}
get_patch_last_supported_ver() {
	local list_patches=$1 pkg_name=$2 inc_sel=$3 _exc_sel=$4 _exclusive=$5 # TODO: resolve using all of these
	local op
	if [ "$inc_sel" ]; then
		if ! op=$(awk '{$1=$1}1' <<<"$list_patches"); then
			epr "list-patches: '$op'"
			return 1
		fi
		local ver vers="" NL=$'\n'
		while IFS= read -r line; do
			line="${line:1:${#line}-2}"
			ver=$(sed -n "/^Name: $line\$/,/^\$/p" <<<"$op" | sed -n "/^Compatible versions:\$/,/^\$/p" | tail -n +2)
			vers=${ver}${NL}
		done <<<"$(list_args "$inc_sel")"
		vers=$(awk '{$1=$1}1' <<<"$vers")
		if [ "$vers" ]; then
			get_highest_ver <<<"$vers"
			return
		fi
	fi
	op=$(java -jar "$cli_jar" list-versions "$patches_jar" -f "$pkg_name" 2>&1 | tail -n +3 | awk '{$1=$1}1')
	if [ "$op" = "Any" ]; then return; fi
	pcount=$(head -1 <<<"$op") pcount=${pcount#*(} pcount=${pcount% *}
	if [ -z "$pcount" ]; then
		av_apps=$(java -jar "$cli_jar" list-versions "$patches_jar" 2>&1 | awk '/Package name:/ { printf "%s\x27%s\x27", sep, $NF; sep=", " } END { print "" }')
		abort "No patch versions found for '$pkg_name' in this patches source!\nAvailable applications found: $av_apps"
	fi
	grep -F "($pcount patch" <<<"$op" | sed 's/ (.* patch.*//' | get_highest_ver || return 1
}

isoneof() {
	local i=$1 v
	shift
	for v; do [ "$v" = "$i" ] && return 0; done
	return 1
}

merge_splits() {
	local bundle=$1 output=$2
	pr "Merging splits"
	gh_dl "$TEMP_DIR/apkeditor.jar" "https://github.com/REAndroid/APKEditor/releases/download/V1.4.7/APKEditor-1.4.7.jar" >/dev/null || return 1
	if ! OP=$(java -jar "$TEMP_DIR/apkeditor.jar" merge -i "${bundle}" -o "${bundle}.mzip" -clean-meta -f 2>&1); then
		epr "Apkeditor ERROR: $OP"
		return 1
	fi
	# this is required because of apksig
	mkdir "${bundle}-zip"
	unzip -qo "${bundle}.mzip" -d "${bundle}-zip"
	(
		cd "${bundle}-zip" || abort
		zip -0rq "${CWD}/${bundle}.zip" .
	)
	# if building module, sign the merged apk properly
	if isoneof "module" "${build_mode_arr[@]}"; then
		patch_apk "${bundle}.zip" "${output}" "--exclusive" "${args[cli]}" "${args[ptjar]}"
		local ret=$?
	else
		cp "${bundle}.zip" "${output}"
		local ret=$?
	fi
	rm -r "${bundle}-zip" "${bundle}.zip" "${bundle}.mzip" || :
	return $ret
}

# -------------------- apkmirror --------------------
apkmirror_search() {
	local resp="$1" dpi="$2" arch="$3" apk_bundle="$4"
	local apparch dlurl="" node app_table emptyCheck
	if [ "$arch" = all ]; then
		apparch=(universal noarch 'arm64-v8a + armeabi-v7a')
	else apparch=("$arch" universal noarch 'arm64-v8a + armeabi-v7a'); fi
	for ((n = 1; n < 40; n++)); do
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child($n)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ -z "$node" ]; then break; fi
		emptyCheck=$($HTMLQ -t -w "div.table-cell:nth-child(1) > a:nth-child(1)" <<<"$node" | xargs)
		if [ "$emptyCheck" ]; then
			dlurl=$($HTMLQ --base https://www.apkmirror.com --attribute href "div:nth-child(1) > a:nth-child(1)" <<<"$node")
		else break; fi
		app_table=$($HTMLQ --text --ignore-whitespace <<<"$node")
		if [ "$(sed -n 3p <<<"$app_table")" = "$apk_bundle" ] &&
			[ "$(sed -n 6p <<<"$app_table")" = "$dpi" ] &&
			isoneof "$(sed -n 4p <<<"$app_table")" "${apparch[@]}"; then
			echo "$dlurl"
			return 0
		fi
	done
	if [ "$n" -eq 2 ] && [ "$dlurl" ]; then
		# only one apk exists, return it
		echo "$dlurl"
		return 0
	fi
	return 1
}
dl_apkmirror() {
	local url=$1 version=${2// /-} output=$3 arch=$4 dpi=$5 is_bundle=false
	if [ -f "${output}.apkm" ]; then
		is_bundle=true
	else
		if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
		local resp node app_table apkmname dlurl=""
		apkmname=$($HTMLQ "h1.marginZero" --text <<<"$__APKMIRROR_RESP__")
		apkmname="${apkmname,,}" apkmname="${apkmname// /-}" apkmname="${apkmname//[^a-z0-9-]/}"
		url="${url}/${apkmname}-${version//./-}-release/"
		resp=$(req "$url" -) || return 1
		node=$($HTMLQ "div.table-row.headerFont:nth-last-child(1)" -r "span:nth-child(n+3)" <<<"$resp")
		if [ "$node" ]; then
			for current_dpi in $dpi; do
				for type in APK BUNDLE; do
					if dlurl=$(apkmirror_search "$resp" "$current_dpi" "${arch}" "$type"); then
						[[ "$type" == "BUNDLE" ]] && is_bundle=true || is_bundle=false
						break 2
					fi
				done
			done
			[ -z "$dlurl" ] && return 1
			resp=$(req "$dlurl" -)
		fi
		url=$(echo "$resp" | $HTMLQ --base https://www.apkmirror.com --attribute href "a.btn") || return 1
		url=$(req "$url" - | $HTMLQ --base https://www.apkmirror.com --attribute href "span > a[rel = nofollow]") || return 1
	fi

	if [ "$is_bundle" = true ]; then
		req "$url" "${output}.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "$url" "${output}" || return 1
	fi
}
get_apkmirror_vers() {
	local vers apkm_resp
	apkm_resp=$(req "https://www.apkmirror.com/uploads/?appcategory=${__APKMIRROR_CAT__}" -)
	vers=$(sed -n 's;.*Version:</span><span class="infoSlide-value">\(.*\) </span>.*;\1;p' <<<"$apkm_resp" | awk '{$1=$1}1')
	if [ "$__AAV__" = false ]; then
		local IFS=$'\n'
		vers=$(grep -iv "\(beta\|alpha\)" <<<"$vers")
		local v r_vers=()
		for v in $vers; do
			grep -iq "${v} \(beta\|alpha\)" <<<"$apkm_resp" || r_vers+=("$v")
		done
		echo "${r_vers[*]}"
	else
		echo "$vers"
	fi
}
get_apkmirror_pkg_name() { sed -n 's;.*id=\(.*\)" class="accent_color.*;\1;p' <<<"$__APKMIRROR_RESP__"; }
get_apkmirror_resp() {
	__APKMIRROR_RESP__=$(req "${1}" -) || return 1
	__APKMIRROR_CAT__="${1##*/}"
}

# -------------------- uptodown --------------------
get_uptodown_resp() {
	__UPTODOWN_RESP__=$(req "${1}/versions" -) || return 1
	__UPTODOWN_RESP_PKG__=$(req "${1}/download" -) || return 1
}
get_uptodown_vers() { $HTMLQ --text ".version" <<<"$__UPTODOWN_RESP__"; }
dl_uptodown() {
	local uptodown_dlurl=$1 version=$2 output=$3 arch=$4 _dpi=$5
	local apparch
	if [ "$arch" = "arm-v7a" ]; then arch="armeabi-v7a"; fi
	if [ "$arch" = all ]; then
		apparch=('arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a')
	else apparch=("$arch" 'arm64-v8a, armeabi-v7a, x86_64' 'arm64-v8a, armeabi-v7a, x86, x86_64' 'arm64-v8a, armeabi-v7a'); fi

	local op resp data_code
	data_code=$($HTMLQ "#detail-app-name" --attribute data-code <<<"$__UPTODOWN_RESP__")
	local versionURL=""
	local is_bundle=false
	for i in {1..20}; do
		resp=$(req "${uptodown_dlurl}/apps/${data_code}/versions/${i}" -)
		if ! op=$(jq -e -r ".data | map(select(.version == \"${version}\")) | .[0]" <<<"$resp"); then
			continue
		fi
		if [ "$(jq -e -r ".kindFile" <<<"$op")" = "xapk" ]; then is_bundle=true; fi
		if versionURL=$(jq -e -r '.versionURL' <<<"$op"); then break; else return 1; fi
	done
	if [ -z "$versionURL" ]; then return 1; fi
	versionURL=$(jq -e -r '.url + "/" + .extraURL + "/" + (.versionID | tostring)' <<<"$versionURL")
	resp=$(req "$versionURL" -) || return 1

	local data_version files node_arch="" data_file_id node_class
	data_version=$($HTMLQ '.button.variants' --attribute data-version <<<"$resp") || return 1
	if [ "$data_version" ]; then
		files=$(req "${uptodown_dlurl%/*}/app/${data_code}/version/${data_version}/files" - | jq -e -r .content) || return 1
		for ((n = 1; n < 12; n += 1)); do
			node_class=$($HTMLQ -w -t ".content > :nth-child($n)" --attribute class <<<"$files") || return 1
			if [ "$node_class" != "variant" ]; then
				node_arch=$($HTMLQ -w -t ".content > :nth-child($n)" <<<"$files" | xargs) || return 1
				continue
			fi
			if [ -z "$node_arch" ]; then return 1; fi
			if ! isoneof "$node_arch" "${apparch[@]}"; then continue; fi

			file_type=$($HTMLQ -w -t ".content > :nth-child($n) > .v-file > span" <<<"$files") || return 1
			if [ "$file_type" = "xapk" ]; then is_bundle=true; else is_bundle=false; fi
			data_file_id=$($HTMLQ ".content > :nth-child($n) > .v-report" --attribute data-file-id <<<"$files") || return 1
			resp=$(req "${uptodown_dlurl}/download/${data_file_id}-x" -)
			break
		done
		if [ $n -eq 12 ]; then return 1; fi
	fi
	local data_url
	data_url=$($HTMLQ "#detail-download-button" --attribute data-url <<<"$resp") || return 1
	if [ $is_bundle = true ]; then
		req "https://dw.uptodown.com/dwn/${data_url}" "$output.apkm" || return 1
		merge_splits "${output}.apkm" "${output}"
	else
		req "https://dw.uptodown.com/dwn/${data_url}" "$output"
	fi
}
get_uptodown_pkg_name() { $HTMLQ --text "tr.full:nth-child(1) > td:nth-child(3)" <<<"$__UPTODOWN_RESP_PKG__"; }

# -------------------- archive --------------------
dl_archive() {
	local url=$1 version=$2 output=$3 arch=$4
	local path version=${version// /}
	version=${version#v}
	# First try to find architecture-specific APK
	path=$(grep "${version}-${arch// /}" <<<"$__ARCHIVE_RESP__")
	if [ -z "$path" ]; then
		# Fall back to universal APK if architecture-specific not found
		path=$(grep "${version}-all" <<<"$__ARCHIVE_RESP__") || return 1
	fi
	req "${url}/${path}" "$output"
}
get_archive_resp() {
	local r
	r=$(req "$1" -)
	if [ -z "$r" ]; then return 1; else __ARCHIVE_RESP__=$(sed -n 's;^<a href="\(.*\)"[^"]*;\1;p' <<<"$r"); fi
	__ARCHIVE_PKG_NAME__=$(awk -F/ '{print $NF}' <<<"$1")
}
get_archive_vers() { sed 's/^[^-]*-//;s/-\(all\|arm64-v8a\|arm-v7a\|x86\|x86_64\)\.apk//g' <<<"$__ARCHIVE_RESP__"; }
get_archive_pkg_name() { echo "$__ARCHIVE_PKG_NAME__"; }
# --------------------------------------------------

patch_apk() {
	local stock_input=$1 patched_apk=$2 patcher_args=$3 cli_jar=$4 patches_jar=$5
	local cmd="java -jar '$cli_jar' patch '$stock_input' --purge -o '$patched_apk' -p '$patches_jar' --keystore=ks.keystore \
--keystore-entry-password=123456789 --keystore-password=123456789 --signer=jhc --keystore-entry-alias=jhc $patcher_args"
	if [ "$OS" = Android ]; then cmd+=" --custom-aapt2-binary='${AAPT2}'"; fi
	pr "$cmd"
	if eval "$cmd"; then [ -f "$patched_apk" ]; else
		rm "$patched_apk" 2>/dev/null || :
		return 1
	fi
}

check_sig() {
	local file=$1 pkg_name=$2
	local sig
	if grep -q "$pkg_name" sig.txt; then
		sig=$(java -jar --enable-native-access=ALL-UNNAMED "$APKSIGNER" verify --print-certs "$file" | grep ^Signer | grep SHA-256 | tail -1 | awk '{print $NF}')
		echo "$pkg_name signature: ${sig}"
		grep -qFx "$sig $pkg_name" sig.txt
	fi
}

build_rv() {
	local args_string="$1"
	IFS='|' read -r cli_jar patches_jar rv_brand excluded_patches included_patches exclusive_patches version app_name patcher_args table build_mode uptodown_dlurl apkmirror_dlurl archive_dlurl dl_from arch include_stock dpi module_prop_name <<< "$args_string"
	local pkg_name=""
	local mode_arg=$build_mode version_mode=$version
	local app_name_l=$(echo "$app_name" | tr '[:upper:]' '[:lower:]')
	app_name_l=${app_name_l// /-}
	local arch_f="${arch// /}"

	local p_patcher_args=()
	if [ "$excluded_patches" ]; then p_patcher_args+=("$(join_args "$excluded_patches" -d)"); fi
	if [ "$included_patches" ]; then p_patcher_args+=("$(join_args "$included_patches" -e)"); fi
	[ "$exclusive_patches" = true ] && p_patcher_args+=("--exclusive")

	local tried_dl=()
	for dl_p in archive apkmirror uptodown; do
		local current_dlurl=""
		case $dl_p in
			archive) current_dlurl="$archive_dlurl" ;;
			apkmirror) current_dlurl="$apkmirror_dlurl" ;;
			uptodown) current_dlurl="$uptodown_dlurl" ;;
		esac
		if [ -z "$current_dlurl" ]; then continue; fi
		if ! get_${dl_p}_resp "$current_dlurl" || ! pkg_name=$(get_"${dl_p}"_pkg_name); then
			wpr "Could not find ${table} in ${dl_p}, trying next source..."
			continue
		fi
		tried_dl+=("$dl_p")
		dl_from=$dl_p
		break
	done
	if [ -z "$pkg_name" ]; then
		local tried_list="${tried_dl[*]:-none}"
		epr "ERROR: Could not find package name for ${table} from any source (tried: ${tried_list}). Check your download URLs."
		add_fail_reason "$table" "Could not resolve package name from download sources (tried: ${tried_list})"
		return 0
	fi
	local list_patches
	list_patches=$(java -jar "$cli_jar" list-patches "$patches_jar" -f "$pkg_name" -v -p 2>&1)

	local get_latest_ver=false
	if [ "$version_mode" = auto ]; then
		if ! version=$(get_patch_last_supported_ver "$list_patches" "$pkg_name" \
			"$included_patches" "$excluded_patches" "$exclusive_patches"); then
			exit 1
		elif [ -z "$version" ]; then get_latest_ver=true; fi
	elif isoneof "$version_mode" latest beta; then
		get_latest_ver=true
		p_patcher_args+=("-f")
	else
		version=$version_mode
		p_patcher_args+=("-f")
	fi
	if [ $get_latest_ver = true ]; then
		if [ "$version_mode" = beta ]; then __AAV__="true"; else __AAV__="false"; fi
		pkgvers=$(get_"${dl_from}"_vers)
		version=$(get_highest_ver <<<"$pkgvers") || version=$(head -1 <<<"$pkgvers")
	fi
	if [ -z "$version" ]; then
		epr "empty version, not building ${table}."
		add_fail_reason "$table" "Resolved version is empty after patches/source negotiation"
		return 0
	fi

	if [ "$mode_arg" = module ]; then
		build_mode_arr=(module)
	elif [ "$mode_arg" = apk ]; then
		build_mode_arr=(apk)
	elif [ "$mode_arg" = both ]; then
		build_mode_arr=(apk module)
	fi

	pr "Choosing version '${version}' for ${table}"
	local version_f=${version// /}
	version_f=${version_f#v}
	local stock_apk="${TEMP_DIR}/${pkg_name}-${version_f}-${arch_f}.apk"
	if [ ! -f "$stock_apk" ]; then
		for dl_p in archive apkmirror uptodown; do
			local current_dlurl=""
			case $dl_p in
				archive) current_dlurl="$archive_dlurl" ;;
				apkmirror) current_dlurl="$apkmirror_dlurl" ;;
				uptodown) current_dlurl="$uptodown_dlurl" ;;
			esac
			if [ -z "$current_dlurl" ]; then continue; fi
			pr "Downloading '${table}' from '${dl_p}'"
			if ! isoneof $dl_p "${tried_dl[@]}"; then
				if ! get_${dl_p}_resp "$current_dlurl"; then
					epr "ERROR: Could not get '${table}' from '${dl_p}'"
					continue
				fi
			fi
			if ! dl_${dl_p} "$current_dlurl" "$version" "$stock_apk" "$arch" "$dpi" "$get_latest_ver"; then
				epr "ERROR: Could not download '${table}' from '${dl_p}' with version '${version}', arch '${arch}', dpi '${dpi}'"
				continue
			fi
			break
		done
		if [ ! -f "$stock_apk" ]; then
			add_fail_reason "$table" "Could not download stock APK from configured sources for version '${version}', arch '${arch}', dpi '${dpi}'"
			return 0
		fi
	fi
	if [ ! -f "${stock_apk}.apkm" ] && ! OP=$(check_sig "$stock_apk" "$pkg_name" 2>&1) && ! grep -qFx "ERROR: Missing META-INF/MANIFEST.MF" <<<"$OP"; then
		epr "$pkg_name not building, apk signature mismatch '$stock_apk': $OP"
		add_fail_reason "$table" "APK signature mismatch for '${stock_apk}': $OP"
		return 0
	fi
	log "${table}: ${version}"

	local microg_patch
	microg_patch=$(grep "^Name: " <<<"$list_patches" | grep -i "gmscore\|microg" || :) microg_patch=${microg_patch#*: }
	local p_args_joined="${p_patcher_args[*]-}"
	if [ -n "$microg_patch" ] && [[ $p_args_joined =~ $microg_patch ]]; then
		epr "You cant include/exclude microg patch as that's done by rvmm builder automatically."
		p_patcher_args=("${p_patcher_args[@]//-[ei] ${microg_patch}/}")
	fi

	local patch_args=() patched_apk build_mode
	local rv_brand_f=$(echo "$rv_brand" | tr '[:upper:]' '[:lower:]')
	rv_brand_f=${rv_brand_f// /-}
	if [ "${patcher_args-}" ]; then p_patcher_args+=("$patcher_args"); fi
	for build_mode in "${build_mode_arr[@]}"; do
		patch_args=("${p_patcher_args[@]-}")
		pr "Building '${table}' in '$build_mode' mode"
		if [ -n "$microg_patch" ]; then
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}-${build_mode}.apk"
		else
			patched_apk="${TEMP_DIR}/${app_name_l}-${rv_brand_f}-${version_f}-${arch_f}.apk"
		fi
		if [ -n "$microg_patch" ]; then
			if [ "$build_mode" = apk ]; then
				patch_args+=("-e \"${microg_patch}\"")
			elif [ "$build_mode" = module ]; then
				patch_args+=("-d \"${microg_patch}\"")
			fi
		fi

		local stock_apk_to_patch="${stock_apk}.stripped.apk"
		cp -f "$stock_apk" "$stock_apk_to_patch"
		if [ "$build_mode" = module ]; then
			zip -d "$stock_apk_to_patch" "lib/*" >/dev/null 2>&1 || :
		else
			if [ "$arch" = "arm64-v8a" ]; then
				zip -d "$stock_apk_to_patch" "lib/armeabi-v7a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "arm-v7a" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/x86_64/*" "lib/armeabi-v7a/*" >/dev/null 2>&1 || :
			elif [ "$arch" = "x86_64" ]; then
				zip -d "$stock_apk_to_patch" "lib/arm64-v8a/*" "lib/armeabi-v7a/*" "lib/x86/*" >/dev/null 2>&1 || :
			else
				zip -d "$stock_apk_to_patch" "lib/x86_64/*" "lib/x86/*" >/dev/null 2>&1 || :
			fi
		fi
		if [ "${NORB:-}" != true ] || [ ! -f "$patched_apk" ]; then
			if ! patch_apk "$stock_apk_to_patch" "$patched_apk" "${patch_args[*]}" "$cli_jar" "$patches_jar"; then
				epr "Building '${table}' failed!"
				add_fail_reason "$table" "Patching/build step failed in mode '${build_mode}' for version '${version}'"
				return 0
			fi
		fi
		rm "$stock_apk_to_patch"
		if [ "$build_mode" = apk ]; then
			local apk_output="${BUILD_DIR}/${app_name_l}-${rv_brand_f}-v${version_f}-${arch_f}.apk"
			mkdir -p "$BUILD_DIR"
			if mv -f "$patched_apk" "$apk_output"; then
				pr "Built ${table} (non-root): '${apk_output}'"
			else
				epr "Failed to move APK to build directory: $patched_apk -> $apk_output"
				add_fail_reason "$table" "Failed to move APK to build directory"
			fi
			continue
		fi
		local base_template
		base_template=$(mktemp -d -p "$TEMP_DIR")
		cp -a $MODULE_TEMPLATE_DIR/. "$base_template"
		local upj="$(echo "$table" | tr '[:upper:]' '[:lower:]')-update.json"

		module_config "$base_template" "$pkg_name" "$version" "$arch"

		local patches_ver="${patches_jar##*-}"
		module_prop \
			"$module_prop_name" \
			"${app_name} ${rv_brand}" \
			"${version} (patches ${patches_ver})" \
			"${app_name} ${rv_brand} module" \
			"https://raw.githubusercontent.com/${GITHUB_REPOSITORY-}/update/${upj}" \
			"$base_template"

		local module_output="${app_name_l}-${rv_brand_f}-module-v${version_f}-${arch_f}.zip"
		pr "Packing module ${table}"
		cp -f "$patched_apk" "${base_template}/base.apk"
		if [ "$include_stock" = true ]; then cp -f "$stock_apk" "${base_template}/${pkg_name}.apk"; fi
		pushd >/dev/null "$base_template" || abort "Module template dir not found"
		mkdir -p "$BUILD_DIR"
		if zip -"$COMPRESSION_LEVEL" -FSqr "${CWD}/${BUILD_DIR}/${module_output}" .; then
			pr "Built ${table} (root): '${BUILD_DIR}/${module_output}'"
		else
			epr "Failed to create module: ${module_output}"
			add_fail_reason "$table" "Failed to create module zip"
		fi
		popd >/dev/null || :
	done
}

list_args() { tr -d '\t\r' <<<"$1" | tr -s ' ' | sed 's/" "/"\n"/g' | sed 's/\([^"]\)"\([^"]\)/\1'\''\2/g' | grep -v '^$' || :; }
join_args() { list_args "$1" | sed "s/^/${2} /" | paste -sd " " - || :; }

module_config() {
	local ma=""
	if [ "$4" = "arm64-v8a" ]; then
		ma="arm64"
	elif [ "$4" = "arm-v7a" ]; then
		ma="arm"
	fi
	echo "PKG_NAME=$2
PKG_VER=$3
MODULE_ARCH=$ma" >"$1/config"
}
module_prop() {
	echo "id=${1}
name=${2}
version=v${3}
versionCode=${NEXT_VER_CODE}
author=j-hc
description=${4}" >"${6}/module.prop"

	if [ "$ENABLE_MODULE_UPDATE" = true ]; then echo "updateJson=${5}" >>"${6}/module.prop"; fi
}
