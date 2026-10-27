    files="$(git ls-files '*.sh')"; [ -z "$files" ] || shellcheck --severity=warning $files
    files="$(git ls-files '*.sh')"; [ -z "$files" ] || shfmt -d -i 4 -ci $files
