#!/bin/sh
set -eu

# Resolve README.md beside this test, even when invoked from another directory.
case "$0" in
    */*) CDPATH= cd -P "${0%/*}" || exit 1 ;;
esac

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

exec 3<README.md || exit 1
IFS= read -r heading <&3 || fail 'README.md must retain its original heading.'
[ "$heading" = '# hexforgeTest' ] || fail 'README.md heading changed.'

# Accept the description with or without a terminating newline.
description=''
IFS= read -r description <&3 || [ -n "$description" ] || fail 'README.md must append one description line.'
[ "$description" = 'Package calc adds two integers.' ] || fail 'README.md must describe calc adding two integers.'

# Reject extra lines, including empty lines and unterminated trailing content.
extra=''
if IFS= read -r extra <&3 || [ -n "$extra" ]; then
    fail 'README.md must contain only the preserved heading and one appended line.'
fi
exec 3<&-
